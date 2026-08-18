<#
.SYNOPSIS
    Builds the container image, pinning IPv4 addresses for the hosts the build needs.

.DESCRIPTION
    The district DNS resolver intermittently answers AAAA-only for these hosts, and
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

# Only hosts contacted from RUN steps need this. Base-image and COPY --from pulls are
# done by the daemon, which does not read the build container's /etc/hosts.
$PinnedHosts = @("pypi.org", "files.pythonhosted.org")

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
        Write-Host "`n  build failed (likely DNS) -- retrying in 5s`n" -ForegroundColor Yellow
        Start-Sleep -Seconds 5
    }
}

Write-Error "docker build failed after $Retries attempts. DNS on this network is intermittent; try again, or set the Docker Desktop DNS to 10.200.0.241 (Settings > Resources > Network) for a permanent fix."
