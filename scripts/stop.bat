@echo off

echo Stopping services...

docker info 2>nul | findstr /i "nvidia" >nul
if %errorlevel% == 0 (
    docker compose -f docker-base.yaml -f docker-gpu.yaml down
) else (
    docker compose -f docker-base.yaml down
)

echo Services stopped
pause