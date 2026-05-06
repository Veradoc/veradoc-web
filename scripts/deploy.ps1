# Define the URLs for your compose files
$baseUrl = "https://veradoc.ai/scripts"
$files = @("docker-compose.yml", "docker-compose.gpu.yml")

Write-Host "--- VeraDoc Initializing ---" -ForegroundColor Cyan

# Loop through and download missing files
foreach ($file in $files) {
    if (-not (Test-Path $file)) {
        Write-Host "Downloading $file..."
        Invoke-WebRequest -Uri "$baseUrl/$file" -OutFile $file
    }
}

# Now that files exist, run the deployment logic
# You can either call your .bat file or just run the docker commands directly here
Write-Host "Starting Docker containers..."
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d

Write-Host "--- Services Started ---" -ForegroundColor Green
Write-Host "UI: http://localhost:4200"