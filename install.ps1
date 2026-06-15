#Requires -Version 5.1
# VeraDoc Install — downloads deploy.ps1 and runs it.

$deployUrl  = 'https://veradoc.ai/scripts/deploy.ps1'
$deployPath = Join-Path $PWD.Path 'deploy.ps1'

Write-Host 'Downloading latest deploy.ps1...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $deployUrl -OutFile $deployPath -ErrorAction Stop
Write-Host '[OK] deploy.ps1 ready.' -ForegroundColor Green

Write-Host "Ejecutando con: Contexto Local (Dot-Sourcing)" -ForegroundColor Gray

# --- EXECUTION ---
# Using Dot-Sourcing (.) instead of (& -File) keeps variables like 
# $env:HOST_IP alive in this script's scope after deploy.ps1 finishes.
. $deployPath

# --- POST-DEPLOYMENT INFO ---
# Checked against strict mode using an explicit fallback if not defined
$displayIp = if ($env:HOST_IP) { $env:HOST_IP } else { "127.0.0.1" }

Write-Host "`n🚀 Veradoc is running at http://${displayIp}:4200" -ForegroundColor Gray
Write-Host "🔒 Use these credentials to login by default:" -ForegroundColor Gray
Write-Host "email: admin@veradoc.ai" -ForegroundColor Gray
Write-Host "password: password " -ForegroundColor Gray