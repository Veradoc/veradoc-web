#Requires -Version 5.1
<#
.SYNOPSIS
    VeraDoc Deployment Orchestrator for Windows (WSL + Docker Compose).

.DESCRIPTION
    Downloads the required Compose files and installer scripts from veradoc.ai
    if missing, detects NVIDIA GPU availability, and brings the stack up or down.
    When an NVIDIA GPU is detected the NVIDIA Container Toolkit is installed
    automatically — this is mandatory for Docker to use the GPU inside containers.

.PARAMETER Down
    Tear down the stack and remove local images and volumes.

.PARAMETER WSLDistro
    WSL distribution to target. Defaults to the system default.

.PARAMETER NvidiaRuntime
    Container runtime to configure for GPU access.
    Valid values: docker (default), containerd, crio.

.EXAMPLE
    # Standard deploy (auto-detects GPU)
    .\deploy.ps1

.EXAMPLE
    # Tear down stack
    .\deploy.ps1 -Down
#>

[CmdletBinding()]
param(
    [switch]$Down,
    [string]$WSLDistro = '',
    [ValidateSet('docker', 'containerd', 'crio')]
    [string]$NvidiaRuntime = 'docker'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────────────────────────

$ComposeUrl  = 'https://veradoc.ai/compose'
$ScriptsUrl  = 'https://veradoc.ai/scripts'
$BaseCompose = 'docker-base.yml'
$LlmCompose  = 'docker-llm.yml'
$LlmGpuCompose  = 'docker-llm-gpu.yml'
$NvidiaFile  = 'Install-NvidiaContainerToolkit.ps1'
$ProjectName = 'veradoc-web'

$ScriptDir    = $PWD.Path
$NvidiaScript = Join-Path $ScriptDir $NvidiaFile

# Sidecar container names — these are init containers that run once and stop.
# They are removed before each deploy so docker compose can recreate them
# with the same name, but kept alive (stopped) between deploys for log access.
$Sidecars = @(
    'ollama-sidecar',
    'minio-sidecar-buckets',
    'minio-sidecar-events'
)

# All long-lived service containers (never force-removed, only via compose down)
$Services = @(
    'ollama',
    'minio',
    'veradoc-back',
    'veradoc-ui',
    'nginx',
    'postgres',
    'redis'
)

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

function Write-Step    { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan    }
function Write-Success { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green  }
function Write-Warn    { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail    { param([string]$m) Write-Host "`n[ERROR] $m" -ForegroundColor Red    }
function Write-Info    { param([string]$m) Write-Host "    $m" -ForegroundColor Gray }

function Invoke-Wsl {
    param([string[]]$Command, [string]$ErrorMessage = 'WSL command failed')
    if ($WSLDistro -ne '') {
        wsl -d $WSLDistro -- @Command
    } else {
        wsl -- @Command
    }
    if ($LASTEXITCODE -ne 0) { throw "$ErrorMessage (exit $LASTEXITCODE)" }
}

function ConvertTo-WslPath {
    param([string]$WinPath)
    $p = $WinPath -replace "\\", "/"
    $p = $p -replace "^([A-Za-z]):/", "/mnt/`$1/"
    return $p.ToLower().Trim()
}

function Invoke-DownloadFile {
    param([string]$File, [string]$BaseUri)
    $dest = Join-Path $ScriptDir $File

    Write-Info "Downloading $File ..."
    try {
        Invoke-WebRequest -Uri "$BaseUri/$File" -OutFile $dest -ErrorAction Stop
        Write-Success "$File downloaded."
    } catch {
        throw "Failed to download $File from $BaseUri. Check your internet connection.`n$($_.Exception.Message)"
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Helper: remove a single container by exact name (only if it exists)
# Returns $true if removed, $false if not found.
# ──────────────────────────────────────────────────────────────────────────────

function Remove-ContainerByName {
    param([string]$Name)

    # -aq returns the ID only when the container exists (running or stopped)
    $id = (Invoke-Wsl @('docker', 'ps', '-aq', '--filter', "name=^${Name}$") -ErrorMessage "docker ps failed for $Name")
    $id = ($id -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) -join ''

    if ($id -eq '') {
        return $false
    }

    # Double-check the exact name to avoid prefix collisions
    $actualName = (Invoke-Wsl @('docker', 'inspect', '--format', '{{.Name}}', $id) -ErrorMessage "docker inspect failed for $id")
    $actualName = $actualName.Trim().TrimStart('/')

    if ($actualName -ne $Name) {
        return $false
    }

    Invoke-Wsl @('docker', 'rm', '-f', $id) -ErrorMessage "Failed to remove container $Name" | Out-Null
    return $true
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. Self-bootstrap
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Bootstrap {
    Write-Step 'Checking required files'
    foreach ($file in @($BaseCompose, $LlmCompose, $LlmGpuCompose)) {
        Invoke-DownloadFile -File $file -BaseUri $ComposeUrl
    }
    Invoke-DownloadFile -File $NvidiaFile -BaseUri $ScriptsUrl
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Preflight {
    Write-Step 'Pre-flight checks'

    if (-not (Get-Command wsl -ErrorAction SilentlyContinue)) {
        throw 'WSL is not installed or not on PATH. Enable WSL2: https://aka.ms/wsl2'
    }
    Write-Success 'WSL found.'

    if ($WSLDistro -ne '') {
        $distros = wsl --list --quiet 2>$null
        if ($distros -notcontains $WSLDistro) {
            throw "WSL distro '$WSLDistro' not found. Run 'wsl --list' to see available distros."
        }
        Write-Success "WSL distro '$WSLDistro' found."
    }

    try {
        Invoke-Wsl @('docker', 'info', '--format', '{{.ServerVersion}}') `
            -ErrorMessage 'Docker unreachable' | Out-Null
        Write-Success 'Docker daemon is running inside WSL.'
    } catch {
        throw 'Docker daemon is not reachable inside WSL. Start Docker Desktop or the Docker service.'
    }

    Write-Success 'Pre-flight checks passed.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. GPU detection
# ──────────────────────────────────────────────────────────────────────────────

function Get-GpuAvailable {
    Write-Step 'Detecting NVIDIA GPU'

    if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
        nvidia-smi -L 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) {
            $gpu = (nvidia-smi --query-gpu=name --format=csv,noheader 2>$null | Select-Object -First 1)
            Write-Success "GPU detected (host): $gpu"
            return $true
        }
    }

    try {
        Invoke-Wsl @('nvidia-smi', '-L') -ErrorMessage 'no gpu in wsl' | Out-Null
        Write-Success 'GPU detected (via WSL).'
        return $true
    } catch {
        Write-Warn 'No NVIDIA GPU detected — deploying in CPU-only mode.'
        return $false
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Build docker compose argument list
# ──────────────────────────────────────────────────────────────────────────────

function Get-ComposeArgs {
    param([bool]$WithGpu)
    $basePath = ConvertTo-WslPath (Join-Path $ScriptDir $BaseCompose)
    $llmPath  = ConvertTo-WslPath (Join-Path $ScriptDir $LlmCompose)
    $a        = @('docker', 'compose', '-p', $ProjectName, '-f', $basePath, '-f', $llmPath)
    if ($WithGpu) {
        $gpuPath = ConvertTo-WslPath (Join-Path $ScriptDir $LlmGpuCompose)
        $a      += @('-f', $gpuPath)
    }
    return $a
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Tear down
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Down {
    Write-Step 'Stopping VeraDoc and cleaning volumes'
    $ca = Get-ComposeArgs -WithGpu $false   # GPU override not needed for down
    Invoke-Wsl (@($ca) + @('down', '-v', '--rmi', 'local')) `
        -ErrorMessage 'docker compose down failed'
    Write-Success 'Stack stopped, volumes and local images removed.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Remove previous sidecar containers
#    Sidecars are init containers: they run once, then stay stopped.
#    We remove them before each deploy so Docker can recreate them with
#    the same container_name. The stopped container is available for log
#    inspection right up until the next deploy runs this function.
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-RemoveSidecars {
    Write-Step 'Removing previous sidecar containers'
    $anyFound = $false

    foreach ($sidecar in $Sidecars) {
        $removed = Remove-ContainerByName -Name $sidecar
        if ($removed) {
            $anyFound = $true
            Write-Success "Removed stopped sidecar: $sidecar"
        } else {
            Write-Info "Sidecar not found (first run?): $sidecar"
        }
    }

    if (-not $anyFound) {
        Write-Info 'No previous sidecars to remove.'
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Remove conflicting long-lived service containers from previous deploys
#    (different project name / working directory)
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-CleanConflicts {
    Write-Step 'Checking for conflicting service containers'
    $foundAny = $false

    foreach ($svc in $Services) {
        $removed = Remove-ContainerByName -Name $svc
        if ($removed) {
            $foundAny = $true
            Write-Warn "Conflicting container removed: $svc"
        }
    }

    if (-not $foundAny) {
        Write-Success 'No conflicting containers found.'
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Deploy
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Deploy {
    param([bool]$HasGpu)

    $ca   = Get-ComposeArgs -WithGpu $HasGpu   # ← was -WithLlm $HasGpu
    $mode = if ($HasGpu) { 'GPU mode' } else { 'CPU-only mode' }

    Write-Step 'Pulling latest images'
    Invoke-Wsl (@($ca) + @('pull')) -ErrorMessage 'docker compose pull failed'
    Write-Success 'Images up to date.'

    Write-Step "Starting VeraDoc stack ($mode)"
    Invoke-Wsl (@($ca) + @('up', '-d', '--remove-orphans')) `
        -ErrorMessage 'docker compose up failed'
    Write-Success 'Stack is up.'

    Write-Step 'Running services'
    Invoke-Wsl (@($ca) + @('ps'))
}

# ──────────────────────────────────────────────────────────────────────────────
# 9. Optional: install NVIDIA Container Toolkit (post-deploy)
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-NvidiaInstall {
    Write-Step 'Installing NVIDIA Container Toolkit (post-deploy)'

    $nvArgs = @('-ExecutionPolicy', 'Bypass', '-File', $NvidiaScript, '-ContainerRuntime', $NvidiaRuntime)
    if ($WSLDistro -ne '') { $nvArgs += @('-WSLDistro', $WSLDistro) }

    Write-Info "Running: $NvidiaFile -ContainerRuntime $NvidiaRuntime"
    $currentExe = (Get-Process -Id $PID).Path
    $proc = Start-Process $currentExe -ArgumentList $nvArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "NVIDIA toolkit installer failed (exit $($proc.ExitCode))."
    }
    Write-Success 'NVIDIA Container Toolkit installed.'
}

# ──────────────────────────────────────────────────────────────────────────────
# 10. Detect local IP to configure frontend
# ──────────────────────────────────────────────────────────────────────────────
function Get-HostIP {
    # Try to get the first non-loopback, non-virtual IPv4
    $ip = Get-NetIPAddress -AddressFamily IPv4 `
        | Where-Object {
            $_.IPAddress -notmatch "^127\." -and
            $_.IPAddress -notmatch "^169\.254\." -and   # link-local
            $_.PrefixOrigin -ne "WellKnown"
        } `
        | Sort-Object InterfaceMetric `
        | Select-Object -First 1 -ExpandProperty IPAddress

    if (-not $ip) {
        Write-Warning "Could not detect IP, falling back to 127.0.0.1"
        return "127.0.0.1"
    }

    return $ip
}

function Get-Host-Ip-Env-Variables {
    Write-Step 'Define Host IP environment variables.'
    
    # 1. Assign the detected IP directly into the environment scope
    $env:HOST_IP = Get-HostIP
    Write-Success "Detected host IP : $($env:HOST_IP)"
            
    # 2. Set env vars for docker compose using the proper scope prefix
    $env:API_URL = "http://$($env:HOST_IP):8808"
    $env:WS_URL  = "ws://$($env:HOST_IP):8808"
    
    Write-Success "API URL          : $($env:API_URL)"
    Write-Success "WS  URL          : $($env:WS_URL)"
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point — self-save when piped via irm | iex
# ──────────────────────────────────────────────────────────────────────────────

$selfPath = Join-Path $PWD.Path 'deploy.ps1'
$isPiped  = -not ($MyInvocation.MyCommand.Path)

if ($isPiped) {
    $MyInvocation.MyCommand.ScriptContents | Set-Content -Path $selfPath -Encoding UTF8
    $relaunchArgs = @('-ExecutionPolicy', 'Bypass', '-File', $selfPath)
    if ($Down)                        { $relaunchArgs += '-Down' }
    if ($WSLDistro -ne '')            { $relaunchArgs += @('-WSLDistro', $WSLDistro) }
    if ($NvidiaRuntime -ne 'docker')  { $relaunchArgs += @('-NvidiaRuntime', $NvidiaRuntime) }
    & pwsh @relaunchArgs
}

# ──────────────────────────────────────────────────────────────────────────────
# Main — defined and called last so PS 5.1 has parsed all functions above
# ──────────────────────────────────────────────────────────────────────────────

function Main {
    $action = if ($Down) { 'Teardown' } else { 'Deploy' }

    Write-Host "`nVeraDoc $action" -ForegroundColor Magenta
    Write-Host '================================' -ForegroundColor Magenta
    Write-Host "  WSL distro    : $(if ($WSLDistro) { $WSLDistro } else { '(default)' })"
    Write-Host "  NVIDIA toolkit: $(if (-not $Down) { 'mandatory when GPU detected' } else { 'n/a' })"
    Write-Host ''

    try {
        Invoke-Bootstrap
        Invoke-Preflight
        Get-Host-Ip-Env-Variables

        if ($Down) {
            Invoke-Down
        } else {
            $hasGpu = Get-GpuAvailable

            # Remove old sidecars first so compose can recreate them by name,
            # then clean any leftover service containers from prior deploys.
            Invoke-RemoveSidecars
            Invoke-CleanConflicts

            Invoke-Deploy -HasGpu $hasGpu

            if ($hasGpu) {
                Invoke-NvidiaInstall
            }
        }

        Write-Host "`n================================" -ForegroundColor Magenta
        Write-Host "VeraDoc $action complete!`n" -ForegroundColor Green

    } catch {
        Write-Fail $_.Exception.Message
        exit 1
    }
}

Main
