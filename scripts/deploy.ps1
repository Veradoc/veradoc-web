# Define the URLs for your compose files
$baseUrl = "https://veradoc.ai/compose"
$files = @("docker-base.yml", "docker-llm.yml")

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
docker compose -f docker-base.yml -f docker-llm.yml up -d

Write-Host "--- Services Started ---" -ForegroundColor Green
Write-Host "UI: http://localhost:4200"