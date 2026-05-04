$hasNvidia = docker info 2>$null | Select-String "nvidia"

if ($hasNvidia) {
    Write-Host "NVIDIA GPU detected, starting with GPU support..." -ForegroundColor Green
    docker compose -f docker-base.yaml -f docker-gpu.yaml up -d
} else {
    Write-Host "No GPU detected, starting without GPU..." -ForegroundColor Yellow
    docker compose -f docker-base.yaml up -d
}

Write-Host "Services started" -ForegroundColor Green
docker compose -f docker-base.yaml ps