<#
.SYNOPSIS
    Builds the container image, installing the district's enterprise root CAs and pinning
    IPv4 addresses for the hosts the build needs.

.DESCRIPTION
    Two district-network problems have to be worked around to build here.

    TLS interception: the firewall sometimes terminates HTTPS and re-signs it with a
    self-signed root (CN=FBISD_PA_Trust). Windows trusts that root, the build container does
    not, so pip and uv fail with "CERTIFICATE_VERIFY_FAILED: self-signed certificate in
    certificate chain". Before building, the roots the district deploys by group policy are
    exported to certs\, which the Dockerfile installs into the image's trust store.

    Note that interception is intermittent -- pypi.org is served by the genuine public chain
    some of the time and re-signed by the firewall at others. That is why the roots come from
    the group-policy store rather than from whatever a live handshake happens to present: a
    build during an un-intercepted window would otherwise record a public root and leave the
    next intercepted build to fail exactly as before.

    DNS: the district resolver intermittently answers AAAA-only for these hosts, and
    Docker Desktop's WSL2 network has no IPv6 default route -- so the build container
    resolves a name to addresses it cannot reach and uv fails with
    "dns error: ... Name has no usable address".

    Addresses are resolved fresh on every run (they are Fastly anycast IPs and rotate)
    and passed as --add-host, which writes them into the build container's /etc/hosts.

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Tag myk8s:v2
    .\build.ps1 --no-cache
#>
[CmdletBinding()]
param(
    [string]$Tag = "myk8s:dev",
    [int]$Retries = 3,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$DockerArgs
)

$ErrorActionPreference = "Stop"

# Only hosts contacted from RUN steps need either workaround. Base-image and COPY --from
# pulls are done by the daemon, which reads neither the build container's /etc/hosts nor
# the trust store we install into the image.
$PinnedHosts = @("pypi.org", "files.pythonhosted.org")

$CertDir = Join-Path $PSScriptRoot "certs"

# Where group policy lands the district's root CAs. Reading this hive rather than filtering
# the Root store by name keeps the script from hardcoding a thumbprint or an "FBISD" string:
# a reissued or replaced interception CA is picked up as soon as policy pushes it. Publicly
# trusted roots never appear here, so nothing the image already trusts gets re-added.
$PolicyRootHive = "HKLM:\SOFTWARE\Policies\Microsoft\SystemCertificates\Root\Certificates"

function Get-PolicyRoots {
    if (-not (Test-Path $PolicyRootHive)) { return @() }

    $store = Get-ChildItem Cert:\LocalMachine\Root
    $found = @()
    foreach ($thumb in (Get-ChildItem $PolicyRootHive).PSChildName) {
        # One thumbprint can surface several times (policy, machine and user copies of the
        # same certificate); they are identical, so keep the first.
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
    # LF and no BOM: update-ca-certificates reads this inside the image.
    [IO.File]::WriteAllText($Path, ($lines -join "`n") + "`n")
}

function Get-CertFileName {
    param($Cert)

    $cn = if ($Cert.Subject -match 'CN=([^,]+)') { $Matches[1].Trim() } else { "root" }
    # Thumbprint suffix so two roots sharing a common name cannot overwrite each other.
    return ("{0}-{1}.crt" -f ($cn -replace '[^A-Za-z0-9._-]', '_'), $Cert.Thumbprint.Substring(0, 8).ToLower())
}

if (-not (Test-Path $CertDir)) { New-Item -ItemType Directory -Path $CertDir | Out-Null }

$roots = Get-PolicyRoots
if ($roots.Count -eq 0) {
    # Off the district network there is nothing to install and the public chain verifies on
    # its own, so this is not an error -- but do not wipe a previous run's work either.
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

# The resolver fails on a different host from one minute to the next, so retry the whole
# build. Registry pulls (FROM, COPY --from) are daemon-side and cannot be pinned at all --
# retrying is the only lever for those.
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

    $argv = @("build") + $addHost + @("-t", $Tag) + $DockerArgs + @(".")
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
