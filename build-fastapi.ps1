<#
.SYNOPSIS
    Builds the FastAPI container image, installing the district's enterprise root CAs and
    pinning IPv4 addresses for the hosts the build needs.

.DESCRIPTION
    Identical to build.ps1 but targets Dockerfile.fastapi (uvicorn + FastAPI) instead of the
    Flask/gunicorn Dockerfile.

.EXAMPLE
    .\build-fastapi.ps1
    .\build-fastapi.ps1 -Tag myk8s-fastapi:v2
    .\build-fastapi.ps1 --no-cache
#>
[CmdletBinding()]
param(
    [string]$Tag = "myk8s-fastapi:dev",
    [int]$Retries = 3,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DockerArgs
)

$ErrorActionPreference = "Stop"

$PinnedHosts = @("pypi.org", "files.pythonhosted.org")

$CertDir = Join-Path $PSScriptRoot "certs"

$PolicyRootHive = "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates"

function Get-PolicyRoots {
    if (-not (Test-Path $PolicyRootHive)) { return @() }

    $store = Get-ChildItem Cert:\LocalMachine\Root
    $found = @()
    foreach ($thumb in (Get-ChildItem $PolicyRootHive).PSChildName) {
        $cert = $store | Where-Object { $_.Thumbprint -eq $thumb } | Select-Object -First 1
        if ($cert) {
            $found += $cert
        } else {
            Write-Host "  policy root $thumb is not in the Root store -- skipping" -ForegroundColor Yellow
        }
    }
    return $found
}

function Save-CertPem {
    param($Cert, [string]$Path)

    $b64 = [Convert]::ToBase64String($Cert.RawData)
    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("-----BEGIN CERTIFICATE-----")
    for ($i = 0; $i -lt $b64.Length; $i += 64) {
        $lines.Add($b64.Substring($i, [Math]::Min(64, $b64.Length - $i)))
    }
    $lines.Add("-----END CERTIFICATE-----")
    [IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n")
}

function Get-CertFileName {
    param($Cert)

    $cn = if ($Cert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { "root" }
    return ("{0}-{1}.crt" -f ($cn -replace '[^A-Za-z0-9._-]', '_'), $Cert.Thumbprint.Substring(0, 8).ToLower())
}

if (-not (Test-Path $CertDir)) { New-Item -ItemType Directory -Path $CertDir | Out-Null }

$roots = Get-PolicyRoots
if ($roots.Count -eq 0) {
    Write-Host "  no group-policy roots found; leaving certs\ as-is" -ForegroundColor Yellow
} else {
    Get-ChildItem -Path $CertDir -Filter *.crt -ErrorAction SilentlyContinue | Remove-Item -Force
    foreach ($root in $roots) {
        $file = Get-CertFileName -Cert $root
        Save-CertPem -Cert $root -Path (Join-Path $CertDir $file)
        Write-Host "  trust $($root.Subject) -> certs\$file (expires $($root.NotAfter.ToString('yyyy-MM-dd')))"
    }
}

function Get-Ipv4 {
    param([string]$Name, [int]$Attempts = 3)
    for ($i = 1; $i -le $Attempts; $i++) {
        $ip = (Resolve-DnsName $Name -Type A -DnsOnly -ErrorAction SilentlyContinue |
               Where-Object { $_.QueryType -eq "A" } |
               Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
        if ($i -lt $Attempts) { Start-Sleep -Seconds 2 }
    }
    return $null
}

for ($attempt = 1; $attempt -le $Retries; $attempt++) {
    $addHost = @()
    foreach ($h in $PinnedHosts) {
        $ip = Get-Ipv4 -Name $h
        if (-not $ip) {
            Write-Host "  no A record for $h yet" -ForegroundColor Yellow
            continue
        }
        Write-Host "  pin $h -> $ip"
        $addHost += "--add-host=${h}:$ip"
    }

    $argv = @("build") + $addHost + @("-f", "Dockerfile.fastapi", "-t", $Tag) + $DockerArgs + @(".")
    Write-Host "  attempt $attempt/${Retries}: docker $($argv -join ' ')`n"

    & docker @argv
    if ($LASTEXITCODE -eq 0) {
        Write-Host "`nbuilt $Tag" -ForegroundColor Green
        exit 0
    }

    if ($attempt -lt $Retries) {
        Write-Host "`n  build failed -- retrying in 5s`n" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

Write-Error "docker build failed after $Retries attempts. Check the error above: TLS trust problems ('certificate verify failed') mean the certs\ export did not cover the intercepting root, while 'no usable address' or 'dns error' means the district resolver is flaking and a retry may succeed."
