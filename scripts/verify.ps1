$ErrorActionPreference = "Stop"

Write-Host "=== TaskFlow Verification ==="

$root = Split-Path -Parent $PSScriptRoot

Write-Host ""
Write-Host "=== Backend ==="

Set-Location "$root\backend\taskflow-api"

npm ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm test
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== Frontend ==="

Set-Location "$root\frontend\taskflow-web"

npm ci
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

npm run build
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== Git ==="

Set-Location $root

git status --short

if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ""
Write-Host "=== Verification Passed ==="