#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the NVIDIA Container Toolkit on a Linux host (or WSL2 on Windows).

.DESCRIPTION
    This script automates the installation of the NVIDIA Container Toolkit,
    which enables GPU-accelerated containers with Docker/containerd.

    On Windows it targets WSL2 (Ubuntu/Debian). On Linux it runs natively.
    Supports Ubuntu/Debian (apt) and RHEL/CentOS/Fedora (dnf/yum).

.PARAMETER ContainerRuntime
    The container runtime to configure after installation.
    Valid values: docker, containerd, crio
    Default: docker

.PARAMETER WSLDistro
    (Windows only) Name of the WSL distribution to target.
    If omitted, uses the default WSL distribution.

.PARAMETER SkipRuntimeConfig
    Skip the post-install runtime configuration step.

.EXAMPLE
    # Install and configure for Docker (default)
    .\Install-NvidiaContainerToolkit.ps1

.EXAMPLE
    # Install and configure for containerd inside a named WSL distro
    .\Install-NvidiaContainerToolkit.ps1 -ContainerRuntime containerd -WSLDistro Ubuntu-22.04

.EXAMPLE
    # Install only, skip runtime configuration
    .\Install-NvidiaContainerToolkit.ps1 -SkipRuntimeConfig

.NOTES
    Prerequisites
    -------------
    - A supported NVIDIA GPU with an up-to-date driver installed on the host.
    - Docker / containerd / CRI-O must already be installed.
    - On Windows: WSL2 must be enabled with a Debian/Ubuntu or RHEL-based distro.
    - Internet access to reach packages.nvidia.com and the distro package repos.

    Official docs: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
#>

[CmdletBinding()]
param(
    [ValidateSet('docker', 'containerd', 'crio')]
    [string]$ContainerRuntime = 'docker',

    [string]$WSLDistro = '',

    [switch]$SkipRuntimeConfig
)

$ErrorActionPreference = 'Stop'

# ──────────────────────────────────────────────────────────────────────────────
# Platform detection (PS 5.1 only runs on Windows — $env:OS is reliable)
# ──────────────────────────────────────────────────────────────────────────────

$script:IsWindowsHost = ($env:OS -eq 'Windows_NT')

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-Success {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "`n[ERROR] $Message" -ForegroundColor Red
}

# Run a shell command and throw on non-zero exit.
function Invoke-Shell {
    param(
        [string[]]$Command,
        [string]$ErrorMessage = 'Command failed'
    )

    if ($script:IsWindowsHost) {
        if ($WSLDistro -ne '') {
            $result = & wsl -d $WSLDistro -- @Command
        } else {
            $result = & wsl -- @Command
        }
    } else {
        $result = & bash -c ($Command -join ' ')
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage (exit code $LASTEXITCODE)"
    }
    return $result
}

# Run a shell command prefixed with sudo.
function Invoke-Sudo {
    param(
        [string[]]$Command,
        [string]$ErrorMessage = 'Sudo command failed'
    )
    Invoke-Shell -Command (@('sudo') + $Command) -ErrorMessage $ErrorMessage
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-PreflightChecks {
    Write-Step "Running pre-flight checks"

    if ($script:IsWindowsHost) {
        $wslExe = Get-Command wsl -ErrorAction SilentlyContinue
        if (-not $wslExe) {
            throw "WSL is not installed or not on PATH. Enable WSL2 first: https://aka.ms/wsl2"
        }
        Write-Success "WSL found: $($wslExe.Source)"

        if ($WSLDistro -ne '') {
            # PS 5.1: wsl --list --quiet returns null-padded UTF-16 strings; clean them up
            $rawDistros = & wsl --list --quiet 2>$null
            $distros = $rawDistros | ForEach-Object { ($_ -replace '\x00', '').Trim() } | Where-Object { $_ -ne '' }
            if ($distros -notcontains $WSLDistro) {
                throw "WSL distribution '$WSLDistro' not found. Available: $($distros -join ', ')"
            }
        }
    }

    # Check NVIDIA driver is visible inside the shell environment
    try {
        $nvidiaSmi = Invoke-Shell -Command @('nvidia-smi', '--query-gpu=name', '--format=csv,noheader') `
                                  -ErrorMessage 'nvidia-smi check'
        Write-Success "NVIDIA GPU detected: $($nvidiaSmi -join ', ')"
    } catch {
        Write-Warn "nvidia-smi not found or no GPU detected — ensure the NVIDIA driver is installed on the host."
    }

    # Check the selected container runtime exists
    try {
        Invoke-Shell -Command @('which', $ContainerRuntime) -ErrorMessage 'which check' | Out-Null
        Write-Success "Container runtime '$ContainerRuntime' is installed."
    } catch {
        Write-Warn "'$ContainerRuntime' binary not found. Install it before running this script."
    }

    Write-Success "Pre-flight checks complete."
}

# ──────────────────────────────────────────────────────────────────────────────
# Installation — Debian / Ubuntu
# ──────────────────────────────────────────────────────────────────────────────

function Install-DebianBased {
    Write-Step "Detected Debian/Ubuntu — using apt"

    Write-Step "Installing prerequisites (curl, gnupg, ca-certificates)"
    Invoke-Sudo @('apt-get', 'update', '-y')
    Invoke-Sudo @('apt-get', 'install', '-y', 'curl', 'gnupg', 'ca-certificates')
    Write-Success "Prerequisites installed."

    Write-Step "Adding NVIDIA GPG key"
    Invoke-Sudo -Command @(
        'bash', '-c',
        'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
    ) -ErrorMessage "Failed to add NVIDIA GPG key"
    Write-Success "GPG key added."

    Write-Step "Adding NVIDIA apt repository"
    Invoke-Sudo -Command @(
        'bash', '-c',
        'curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed "s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g" | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list'
    ) -ErrorMessage "Failed to add apt repository"
    Write-Success "Repository added."

    Write-Step "Installing nvidia-container-toolkit"
    Invoke-Sudo @('apt-get', 'update', '-y')
    Invoke-Sudo @('apt-get', 'install', '-y', 'nvidia-container-toolkit')
    Write-Success "nvidia-container-toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Installation — RHEL / CentOS / Fedora
# ──────────────────────────────────────────────────────────────────────────────

function Install-RhelBased {
    Write-Step "Detected RHEL/CentOS/Fedora — using dnf/yum"

    # Prefer dnf if available, fall back to yum
    $pkgMgr = 'yum'
    try { Invoke-Shell -Command @('which', 'dnf') -ErrorMessage 'dnf check' | Out-Null; $pkgMgr = 'dnf' } catch {}

    Write-Step "Adding NVIDIA dnf/yum repository"
    Invoke-Sudo -Command @(
        'bash', '-c',
        'curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | tee /etc/yum.repos.d/nvidia-container-toolkit.repo'
    ) -ErrorMessage "Failed to add yum/dnf repository"
    Write-Success "Repository added."

    Write-Step "Installing nvidia-container-toolkit"
    Invoke-Sudo @($pkgMgr, 'install', '-y', 'nvidia-container-toolkit')
    Write-Success "nvidia-container-toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Post-install runtime configuration
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-RuntimeConfig {
    Write-Step "Configuring runtime: $ContainerRuntime"
    Invoke-Sudo @('nvidia-ctk', 'runtime', 'configure', "--runtime=$ContainerRuntime")
    Write-Success "nvidia-ctk runtime configured."

    try {
        Invoke-Sudo @('systemctl', 'restart', $ContainerRuntime)
        Write-Success "$ContainerRuntime restarted successfully."
    } catch {
        Write-Warn "Could not restart $ContainerRuntime automatically — a manual restart may be required."
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Verification {
    Write-Step "Verifying installation"

    try {
        $version = Invoke-Shell -Command @('nvidia-ctk', '--version') -ErrorMessage 'nvidia-ctk version'
        Write-Success "nvidia-ctk version: $($version -join ' ')"
    } catch {
        Write-Warn "nvidia-ctk not found on PATH after install — PATH may need updating."
    }

    if (-not $SkipRuntimeConfig) {
        Write-Host "`nTo run a quick GPU smoke-test:" -ForegroundColor White
        Write-Host "  docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi" `
            -ForegroundColor DarkGray
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Main  (defined last so all functions above are already parsed by PS 5.1)
# ──────────────────────────────────────────────────────────────────────────────

function Main {
    Write-Host "`nNVIDIA Container Toolkit Installer" -ForegroundColor Magenta
    Write-Host "====================================" -ForegroundColor Magenta

    try {
        Invoke-PreflightChecks

        # Detect distro family from /etc/os-release
        $osRelease = Invoke-Shell -Command @('cat', '/etc/os-release') `
                                  -ErrorMessage 'Cannot read /etc/os-release'
        $osReleaseText = $osRelease -join "`n"

        if ($osReleaseText -match '(debian|ubuntu)') {
            Install-DebianBased
        } elseif ($osReleaseText -match '(rhel|centos|fedora|sles|opensuse)') {
            Install-RhelBased
        } else {
            throw "Unsupported Linux distribution. Only Debian/Ubuntu and RHEL/CentOS/Fedora are supported."
        }

        if (-not $SkipRuntimeConfig) {
            Invoke-RuntimeConfig
        }

        Invoke-Verification

        Write-Host "`nInstallation complete!" -ForegroundColor Green
    } catch {
        Write-Fail $_.Exception.Message
        exit 1
    }
}

# Entry point — must be the last statement in the file
Main
