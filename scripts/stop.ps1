# --- VeraDoc Stop (PowerShell) ---

$ErrorActionPreference = 'Stop'

$baseCompose = "docker-base.yml"
$llmCompose = "docker-llm.yml"

Write-Host "Stopping VeraDoc and cleaning volumes..." -ForegroundColor Yellow
docker compose -f $baseCompose -f $llmCompose down -v --rmi local
Write-Host "Done." -ForegroundColor Green
