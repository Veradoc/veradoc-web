#Requires -Version 5.1
# VeraDoc Install — downloads deploy.ps1 and runs it.

$deployUrl  = 'https://veradoc.ai/scripts/deploy.ps1'
$deployPath = Join-Path $PWD.Path 'deploy.ps1'

Write-Host 'Downloading latest deploy.ps1...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $deployUrl -OutFile $deployPath -ErrorAction Stop
Write-Host '[OK] deploy.ps1 ready.' -ForegroundColor Green

# --- CAMBIO AQUÍ: Detección de ejecutable ---
# Intentamos usar 'pwsh' (Core), si falla usamos 'powershell' (Windows PS)
$exe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }

Write-Host "Ejecutando con: $exe" -ForegroundColor Gray

& $exe -ExecutionPolicy Bypass -File $deployPath

Write-Host "🚀 Veradoc is running at http://${env:HOST_IP}:4200" -ForegroundColor Gray
Write-Host "🔒 Use these credentials to login by default:" -ForegroundColor Gray
Write-Host "email: admin@veradoc.ai" -ForegroundColor Gray
Write-Host "password: password " -ForegroundColor Gray