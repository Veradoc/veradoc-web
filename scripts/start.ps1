# --- VeraDoc Start (PowerShell) ---

$ErrorActionPreference = 'Stop'

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
            exit 1
        }
    }
}

# 2. Hardware Detection (NVIDIA)
$hasGpu = $false
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    nvidia-smi -L > $null 2>&1
    if ($LASTEXITCODE -eq 0) {
        $hasGpu = $true
        Write-Host "NVIDIA GPU detected. Activating hardware acceleration..." -ForegroundColor Cyan
    }
}

if (-not $hasGpu) {
    Write-Host "No NVIDIA GPU detected. Deploying in CPU-only mode..." -ForegroundColor Yellow
}

# 3. Deploy Services
Write-Host "--- Starting Services ---" -ForegroundColor Gray

if ($hasGpu) {
    docker compose -f $baseCompose -f $llmCompose up -d
} else {
    docker compose -f $baseCompose up -d
}

Write-Host "--- Services Started ---" -ForegroundColor Green
