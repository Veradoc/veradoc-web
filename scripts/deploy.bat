@echo off
set BASE_COMPOSE=docker-compose.yml
set GPU_COMPOSE=docker-compose.gpu.yml

echo --- DocSphere Deployment Script (Windows) ---

:: Check for "down" argument
if "%1"=="down" (
    echo Stopping DocSphere and removing volumes...
    docker compose -f %BASE_COMPOSE% -f %GPU_COMPOSE% down -v
    pause
    exit /b
)

:: Check for GPU file
if exist %GPU_COMPOSE% (
    echo GPU override detected. Starting with WSL2 NVIDIA support...
    docker compose -f %BASE_COMPOSE% -f %GPU_COMPOSE% up -d
) else (
    echo GPU override not found. Starting in CPU-only mode...
    docker compose -f %BASE_COMPOSE% up -d
)

echo --- Services Started ---
echo UI:      http://localhost:4200
pause