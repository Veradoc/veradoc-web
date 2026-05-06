# --- VeraDoc Deployment Orchestrator (PowerShell) ---

$baseUrl = "https://veradoc.ai/compose"
$baseCompose = "docker-base.yml"
$llmCompose = "docker-llm.yml"

# 1. Self-Bootstrap: Download files if they are missing
$requiredFiles = @($baseCompose, $llmCompose)
foreach ($file in $requiredFiles) {
    if (-not (Test-Path $file)) {
        Write-Host "Fetching $file from server..." -ForegroundColor Cyan
        try {
            Invoke-WebRequest -Uri "$baseUrl/$file" -OutFile $file -ErrorAction Stop
        } catch {
            Write-Error "Failed to download $file. Check your internet connection."
            exit
        }
    }
}

# 2. Check for "down" argument
if ($args[0] -eq "down") {
    Write-Host "Stopping VeraDoc and cleaning volumes..." -ForegroundColor Yellow
    docker compose -f $baseCompose -f $llmCompose down -v --rmi local
    Write-Host "Done." -ForegroundColor Green
    exit
}

# 3. Hardware Detection (NVIDIA)
$hasGpu = $false
# Check if nvidia-smi exists in the system path
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    # Run it and check exit code
    nvidia-smi -L > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $hasGpu = $true
        Write-Host "NVIDIA GPU detected. Activating hardware acceleration..." -ForegroundColor Cyan
    }
}

if (-not $hasGpu) {
    Write-Host "No NVIDIA GPU detected. Deploying in CPU-only mode..." -ForegroundColor Yellow
}

# 4. Deploy Services
Write-Host "--- Deploying Services ---" -ForegroundColor Gray

if ($hasGpu) {
    # Start with GPU override
    docker compose -f $baseCompose -f $llmCompose up -d
} else {
    # Start CPU only
    docker compose -f $baseCompose up -d
}

Write-Host "--- Services Started ---" -ForegroundColor Green
Write-Host "UI:      http://localhost:4200"