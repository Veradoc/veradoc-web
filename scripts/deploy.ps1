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

$ComposeUrl   = 'https://veradoc.ai/compose'
$ScriptsUrl   = 'https://veradoc.ai/scripts'
$BaseCompose  = 'docker-base.yml'
$LlmCompose   = 'docker-llm.yml'
$NvidiaFile   = 'Install-NvidiaContainerToolkit.ps1'
$ProjectName  = 'veradoc-web'   # Must match the name used when the stack was first created
$UiPort       = 4200

# All files are downloaded into the current working directory by Invoke-Bootstrap.
# Using $PWD works correctly both when run from disk and when piped via irm | iex.
$ScriptDir    = $PWD.Path
$NvidiaScript = Join-Path $ScriptDir $NvidiaFile

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

function Write-Step    { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-Success { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn    { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail    { param([string]$m) Write-Host "`n[ERROR] $m" -ForegroundColor Red }
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
    # Pure PowerShell conversion — avoids wslpath escaping issues entirely.
    # C:\foo\bar  ->  /mnt/c/foo/bar
    $p = $WinPath -replace "\\", "/"          # backslashes -> forward slashes
    $p = $p -replace "^([A-Za-z]):/", "/mnt/`$1/"  # drive letter -> /mnt/x/
    return $p.ToLower().Trim()
}

function Invoke-DownloadIfMissing {
    param([string]$File, [string]$BaseUri)
    $dest = Join-Path $ScriptDir $File
    if (Test-Path $dest) {
        Write-Success "$File already present."
        return
    }
    Write-Info "Downloading $File ..."
    try {
        Invoke-WebRequest -Uri "$BaseUri/$File" -OutFile $dest -ErrorAction Stop
        Write-Success "$File downloaded."
    } catch {
        throw "Failed to download $File from $BaseUri. Check your internet connection.`n$($_.Exception.Message)"
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. Self-bootstrap: download all required files if missing
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Bootstrap {
    Write-Step 'Checking required files'

    # Compose files
    foreach ($file in @($BaseCompose, $LlmCompose)) {
        Invoke-DownloadIfMissing -File $file -BaseUri $ComposeUrl
    }

    # Installer scripts
    Invoke-DownloadIfMissing -File $NvidiaFile -BaseUri $ScriptsUrl
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
# 3. GPU detection (native nvidia-smi first, then WSL fallback)
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
    param([bool]$WithLlm)
    $basePath = ConvertTo-WslPath (Join-Path $ScriptDir $BaseCompose)
    $a        = @('docker', 'compose', '-p', $ProjectName, '-f', $basePath)
    if ($WithLlm) {
        $llmPath = ConvertTo-WslPath (Join-Path $ScriptDir $LlmCompose)
        $a      += @('-f', $llmPath)
    }
    return $a
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Tear down
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Down {
    Write-Step 'Stopping VeraDoc and cleaning volumes'
    $ca = Get-ComposeArgs -WithLlm $true
    Invoke-Wsl (@($ca) + @('down', '-v', '--rmi', 'local')) `
        -ErrorMessage 'docker compose down failed'
    Write-Success 'Stack stopped, volumes and local images removed.'
}

function Invoke-CleanConflicts {
    # Docker derives the project name from the working directory when -p is not
    # set inside the compose file itself. Running from different folders produces
    # different project names (e.g. "deploy", "administrador", "veradoc-web"),
    # which leaves orphaned containers that block the next `compose up`.
    #
    # Instead of relying on project-label filters (which depend on the name being
    # consistent), we simply force-remove any container whose *exact* name matches
    # a known VeraDoc service. Docker ps --filter uses a regex; wrapping the name
    # in  word-boundary anchors avoids partial matches.
    Write-Step 'Checking for conflicting containers from previous deploys'

    $veradocServices = @('ollama', 'minio', 'veradoc-back', 'veradoc-ui',
                         'ollama-sidecar', 'minio-sidecar-buckets', 'minio-sidecar-events',
                         'nginx', 'postgres', 'redis')
    $foundAny = $false

    foreach ($svc in $veradocServices) {
        # --filter name= is a substring match in Docker, so we grep the exact name
        # from the full container list to avoid false positives
        $id = Invoke-Wsl @('docker', 'ps', '-aq', '--filter', "name=$svc") `
                  -ErrorMessage "docker ps failed while checking $svc"
        $id = ($id -split "`n" | Where-Object { $_.Trim() -ne '' }) -join ' '

        if ($id -ne '') {
            # Verify it is an exact name match, not a substring (e.g. "veradoc-back" vs "veradoc-back-2")
            $name = Invoke-Wsl @('docker', 'inspect', '--format', '{{.Name}}', $id.Trim()) `
                        -ErrorMessage "docker inspect failed for $id"
            $name = $name.Trim().TrimStart('/')

            if ($name -eq $svc) {
                $foundAny = $true
                Write-Warn "Conflicting container found: $svc — removing..."
                Invoke-Wsl @('docker', 'rm', '-f', $id.Trim()) `
                    -ErrorMessage "Failed to remove container $svc"
                Write-Success "Removed: $svc"
            }
        }
    }

    if (-not $foundAny) {
        Write-Success 'No conflicting containers found.'
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Deploy
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Deploy {
    param([bool]$HasGpu)

    $ca   = Get-ComposeArgs -WithLlm $HasGpu
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
# 7. Optional: install NVIDIA Container Toolkit (post-deploy)
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-NvidiaInstall {
    Write-Step 'Installing NVIDIA Container Toolkit (post-deploy)'

    # File is guaranteed to exist — Invoke-Bootstrap downloaded it
    $nvArgs = @('-ExecutionPolicy', 'Bypass', '-File', $NvidiaScript, '-ContainerRuntime', $NvidiaRuntime)
    if ($WSLDistro -ne '') { $nvArgs += @('-WSLDistro', $WSLDistro) }

    Write-Info "Running: $NvidiaFile -ContainerRuntime $NvidiaRuntime"
    $proc = Start-Process pwsh -ArgumentList $nvArgs -Wait -PassThru -NoNewWindow
    if ($proc.ExitCode -ne 0) {
        throw "NVIDIA toolkit installer failed (exit $($proc.ExitCode))."
    }
    Write-Success 'NVIDIA Container Toolkit installed.'
}

# ──────────────────────────────────────────────────────────────────────────────
# # ──────────────────────────────────────────────────────────────────────────────
# Entry point — self-save when piped via irm | iex so parameters work normally
# ──────────────────────────────────────────────────────────────────────────────

$selfPath = Join-Path $PWD.Path 'deploy.ps1'
$isPiped  = -not ($MyInvocation.MyCommand.Path)

if ($isPiped) {
    # Running via irm | iex — save ourselves to disk then re-execute as a real file
    $MyInvocation.MyCommand.ScriptContents | Set-Content -Path $selfPath -Encoding UTF8
    $relaunchArgs = @('-ExecutionPolicy', 'Bypass', '-File', $selfPath)
    if ($Down)                        { $relaunchArgs += '-Down' }
    if ($WSLDistro -ne '')            { $relaunchArgs += @('-WSLDistro', $WSLDistro) }
    if ($NvidiaRuntime -ne 'docker')  { $relaunchArgs += @('-NvidiaRuntime', $NvidiaRuntime) }
    & pwsh @relaunchArgs
} else {
}
# ──────────────────────────────────────────────────────────────────────────────

function Main {
    $action = if ($Down) { 'Teardown' } else { 'Deploy' }

    Write-Host "`nVeraDoc $action" -ForegroundColor Magenta
    Write-Host '================================' -ForegroundColor Magenta
    Write-Host "  WSL distro    : $(if ($WSLDistro) { $WSLDistro } else { '(default)' })"
    Write-Host "  NVIDIA toolkit: $(if (-not $Down) { "mandatory when GPU detected" } else { 'n/a' })"
    Write-Host ''

    try {
        Invoke-Bootstrap
        Invoke-Preflight

        if ($Down) {
            Invoke-Down
        } else {
            $hasGpu = Get-GpuAvailable
            Invoke-CleanConflicts
            Invoke-Deploy -HasGpu $hasGpu

            # Toolkit is mandatory when a GPU is present —
            # without it Docker cannot access the GPU inside containers
            if ($hasGpu) {
                Invoke-NvidiaInstall
            }

            Write-Host ''
            Write-Host '  UI:  ' -NoNewline -ForegroundColor Gray
            Write-Host "http://localhost:$UiPort" -ForegroundColor White
        }

        Write-Host "`n================================" -ForegroundColor Magenta
        Write-Host "VeraDoc $action complete!`n" -ForegroundColor Green

    } catch {
        Write-Fail $_.Exception.Message
        exit 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Entry point — self-save when piped via irm | iex so parameters work normally
# ──────────────────────────────────────────────────────────────────────────────

$selfPath = Join-Path $PWD.Path 'deploy.ps1'
$isPiped  = -not ($MyInvocation.MyCommand.Path)

if ($isPiped) {
    # Running via irm | iex — save ourselves to disk then re-execute as a real file
    $MyInvocation.MyCommand.ScriptContents | Set-Content -Path $selfPath -Encoding UTF8
    $relaunchArgs = @('-ExecutionPolicy', 'Bypass', '-File', $selfPath)
    if ($Down)                       { $relaunchArgs += '-Down' }
    if ($WSLDistro -ne '')           { $relaunchArgs += @('-WSLDistro', $WSLDistro) }
    if ($NvidiaRuntime -ne 'docker') { $relaunchArgs += @('-NvidiaRuntime', $NvidiaRuntime) }
    & pwsh @relaunchArgs
} else {
    Main
}
