$hasNvidia = docker info 2>$null | Select-String "nvidia"

Write-Host "Stopping services..." -ForegroundColor Yellow

if ($hasNvidia) {
    docker compose -f docker-base.yaml -f docker-gpu.yaml down
} else {
    docker compose -f docker-base.yaml down
}

Write-Host "Services stopped" -ForegroundColor Green