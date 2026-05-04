@echo off

docker info 2>nul | findstr /i "nvidia" >nul
if %errorlevel% == 0 (
    echo NVIDIA GPU detected, starting with GPU support...
    docker compose -f docker-base.yaml -f docker-gpu.yaml up -d
) else (
    echo No GPU detected, starting without GPU...
    docker compose -f docker-base.yaml up -d
)

echo Services started
docker compose -f docker-base.yaml ps
pause