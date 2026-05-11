#Requires -Version 5.1
# VeraDoc Install — downloads deploy.ps1 and runs it.
# Usage: irm https://veradoc.ai/install | powershell

$deployUrl  = 'https://veradoc.ai/scripts/deploy.ps1'
$deployPath = Join-Path $PWD.Path 'deploy.ps1'

Write-Host 'Downloading latest deploy.ps1...' -ForegroundColor Cyan
Invoke-WebRequest -Uri $deployUrl -OutFile $deployPath -ErrorAction Stop
Write-Host '[OK] deploy.ps1 ready.' -ForegroundColor Green

& pwsh -ExecutionPolicy Bypass -File $deployPath
