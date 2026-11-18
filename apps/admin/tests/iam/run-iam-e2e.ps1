<#
Runs the real IAM browser E2E (tests/iam) against a throwaway stack built from the separate backend repository:
PostgreSQL 17 (backend role provisioning) -> seed owner -> API in Production -> Caddy TLS -> Playwright.
Everything runs in Docker on its own network; the dev database and dev Caddy are not touched.

Prerequisites: Docker Desktop, `corepack pnpm install` done, Admin Next.js reachable from Docker at
-AdminUpstream (default: host port 3001, e.g. the Admin dev server or the FE compose service).

Usage (from anywhere):
  powershell -File apps/admin/tests/iam/run-iam-e2e.ps1 -BackendRepo D:\path\to\backend-repo
#>
param(
    [Parameter(Mandatory = $true)][string]$BackendRepo,
    [int]$Port = 9443,
    [string]$AdminUpstream = "host.docker.internal:3001",
    [switch]$KeepEnvironment
)
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$BackendRepo = (Resolve-Path $BackendRepo).Path
foreach ($required in @('backend\src\TeaPremium.Infrastructure\TeaPremium.Infrastructure.csproj', 'infra\Dockerfile.api', 'infra\postgres\init-roles.sh')) {
    if (-not (Test-Path -LiteralPath (Join-Path $BackendRepo $required))) { throw "Backend repo is missing $required" }
}

$prefix = 'tp-iam-e2e'
$network = "$prefix-net"; $pg = "$prefix-pg"; $api = "$prefix-api"; $caddy = "$prefix-caddy"
$image = 'teapremium-iam-e2e-api'
$pgIp = '172.31.250.20'; $caddyIp = '172.31.250.10'
$work = Join-Path $repo 'artifacts\iam-e2e'          # git-ignored; holds secrets only while running
$fixtureDir = Join-Path $work 'artifacts\p0-12-local' # seed writes here relative to its working directory
$utf8 = New-Object System.Text.UTF8Encoding($false)

function Invoke-Docker {
    & docker @args
    if ($LASTEXITCODE -ne 0) { throw "docker $($args[0]) failed with exit code $LASTEXITCODE" }
}
function New-Secret {
    $bytes = New-Object byte[] 48
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return (([Convert]::ToBase64String($bytes)) -replace '[^A-Za-z0-9]', '').Substring(0, 32)
}
function Write-Secret([string]$path, [string]$content) { [System.IO.File]::WriteAllText($path, $content, $utf8) }
function Remove-Environment {
    # Windows PowerShell turns redirected native stderr into errors; missing containers are expected here.
    $ErrorActionPreference = 'Continue'
    foreach ($name in @($caddy, $api, $pg)) { & docker rm -f $name 2>$null | Out-Null }
    & docker network rm $network 2>$null | Out-Null
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
}
function Wait-Until([scriptblock]$condition, [string]$what, [int]$seconds = 120) {
    $ErrorActionPreference = 'Continue'   # probes fail (with stderr) until ready
    $deadline = (Get-Date).AddSeconds($seconds)
    while (-not (& $condition)) {
        if ((Get-Date) -gt $deadline) { throw "Timed out waiting for $what" }
        Start-Sleep -Seconds 2
    }
}

$exitCode = 1
Remove-Environment
try {
    New-Item -ItemType Directory -Force -Path $fixtureDir, (Join-Path $work 'seed') | Out-Null

    Write-Host '== Build backend API image'
    Invoke-Docker build -q -t $image -f (Join-Path $BackendRepo 'infra\Dockerfile.api') $BackendRepo | Out-Null
    Invoke-Docker network create --subnet 172.31.250.0/24 $network | Out-Null

    Write-Host '== PostgreSQL 17 with backend role provisioning'
    $ownerPassword = New-Secret; $appPassword = New-Secret
    Write-Secret (Join-Path $work 'pg.env.secret') (@(
        'POSTGRES_USER=postgres', "POSTGRES_PASSWORD=$(New-Secret)", 'POSTGRES_DB=postgres', 'TP_DATABASE=admin_shell_test',
        "TP_OWNER_PASSWORD=$ownerPassword", "TP_APP_PASSWORD=$appPassword", "TP_READONLY_PASSWORD=$(New-Secret)") -join "`n")
    Invoke-Docker run -d --name $pg --network $network --ip $pgIp --env-file (Join-Path $work 'pg.env.secret') `
        -v "$(Join-Path $BackendRepo 'infra\postgres\init-roles.sh'):/docker-entrypoint-initdb.d/10-roles.sh:ro" `
        -v "$(Join-Path $BackendRepo 'infra\postgres'):/opt/teapremium:ro" postgres:17 | Out-Null
    # The init phase only listens on a socket, so TCP readiness means provisioning finished.
    Wait-Until { & docker exec $pg pg_isready -q -h 127.0.0.1 -U postgres 2>$null; $LASTEXITCODE -eq 0 } 'PostgreSQL'

    Write-Host '== Seed: migrate as tp_owner and bootstrap a random owner'
    Write-Secret (Join-Path $fixtureDir 'connection.secret') "Host=127.0.0.1;Port=5432;Database=admin_shell_test;Username=tp_owner;Password=$ownerPassword"
    Copy-Item (Join-Path $PSScriptRoot 'seed\Program.cs'), (Join-Path $PSScriptRoot 'seed\Seed.csproj') (Join-Path $work 'seed')
    Invoke-Docker run --rm --network "container:$pg" -v "${work}:/work" -w /work $image `
        dotnet run --project /work/seed/Seed.csproj -warnaserror -p:BackendRoot=/workspace/backend
    $fixture = Get-Content -Raw (Join-Path $fixtureDir 'fixture.secret') | ConvertFrom-Json

    Write-Host '== API (Production) as tp_app'
    Write-Secret (Join-Path $work 'api.env.secret') (@(
        'ASPNETCORE_ENVIRONMENT=Production',
        "ConnectionStrings__Default=Host=127.0.0.1;Port=5432;Database=admin_shell_test;Username=tp_app;Password=$appPassword",
        "Iam__KeyCertificatePath=$($fixture.keyPath)", "Iam__KeyCertificatePassword=$($fixture.keyPassword)",
        'Iam__AdminHost=admin.localhost', "Iam__TrustedProxies__0=$caddyIp") -join "`n")
    Invoke-Docker run -d --name $api --network "container:$pg" --env-file (Join-Path $work 'api.env.secret') `
        -v "${work}:/work:ro" -w /workspace/backend/src/TeaPremium.Api $image `
        dotnet bin/Debug/net10.0/TeaPremium.Api.dll --urls http://0.0.0.0:5080 | Out-Null
    Wait-Until { (& docker logs $api 2>&1 | Out-String) -match 'Now listening' } 'API'

    Write-Host "== Caddy TLS on https://admin.localhost:$Port"
    Write-Secret (Join-Path $work 'Caddyfile') @"
{
	admin off
	auto_https disable_redirects
}
https://admin.localhost:$Port {
	tls internal
	header Cache-Control "private, no-store, max-age=0"
	handle /api/* {
		reverse_proxy ${pgIp}:5080
	}
	handle {
		reverse_proxy $AdminUpstream
	}
}
"@
    Invoke-Docker run -d --name $caddy --network $network --ip $caddyIp --add-host host.docker.internal:host-gateway `
        -p "127.0.0.1:${Port}:${Port}" -v "$(Join-Path $work 'Caddyfile'):/etc/caddy/Caddyfile:ro" caddy:2 | Out-Null
    $leaf = '/data/caddy/certificates/local/admin.localhost/admin.localhost.crt'
    Wait-Until { & docker exec $caddy test -f $leaf 2>$null; $LASTEXITCODE -eq 0 } 'Caddy certificate'
    Invoke-Docker cp "${caddy}:$leaf" (Join-Path $work 'leaf.crt')
    # Pin only this run's leaf key for the test Chromium; nothing is installed into the OS trust store.
    $spki = & node -e "const fs=require('fs'),c=require('crypto');const k=new c.X509Certificate(fs.readFileSync(process.argv[1])).publicKey.export({type:'spki',format:'der'});process.stdout.write(c.createHash('sha256').update(k).digest('base64'))" (Join-Path $work 'leaf.crt')

    Write-Host '== Playwright IAM E2E'
    $env:ADMIN_IAM_FIXTURE = Join-Path $fixtureDir 'fixture.secret'
    $env:ADMIN_LOCAL_CA_SPKI = $spki
    $env:ADMIN_IAM_BASE_URL = "https://admin.localhost:$Port"
    Push-Location $repo
    try { & corepack pnpm --filter '@teapremium/admin' test:iam; $exitCode = $LASTEXITCODE } finally { Pop-Location }
} finally {
    Remove-Item Env:ADMIN_IAM_FIXTURE, Env:ADMIN_LOCAL_CA_SPKI, Env:ADMIN_IAM_BASE_URL -ErrorAction SilentlyContinue
    if ($KeepEnvironment) { Write-Host "Kept containers and $work (contains secrets; delete when done)." }
    else { Remove-Environment }
}
exit $exitCode
