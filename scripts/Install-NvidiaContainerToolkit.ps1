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

.PARAMETER Verbose
    Print extra diagnostic output.

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

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        # Run inside WSL
        if ($WSLDistro -ne '') {
            $result = wsl -d $WSLDistro -- @Command
        } else {
            $result = wsl -- @Command
        }
    } else {
        # Native Linux — use bash
        $result = bash -c ($Command -join ' ')
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage (exit code $LASTEXITCODE)"
    }
    return $result
}

# Run a shell command with sudo.
function Invoke-Sudo {
    param(
        [string[]]$Command,
        [string]$ErrorMessage = 'Sudo command failed'
    )
    Invoke-Shell -Command (@('sudo') + $Command) -ErrorMessage $ErrorMessage
}

# ──────────────────────────────────────────────────────────────────────────────
# Platform detection
# ──────────────────────────────────────────────────────────────────────────────

function Get-LinuxDistroFamily {
    $osRelease = Invoke-Shell -Command @('cat', '/etc/os-release') `
                              -ErrorMessage 'Cannot read /etc/os-release'
    $idLine = ($osRelease | Select-String '^ID_LIKE=|^ID=') | Select-Object -First 1
    if ($idLine -match '(debian|ubuntu)') { return 'debian' }
    if ($idLine -match '(rhel|centos|fedora|sles|opensuse)') { return 'rhel' }
    throw "Unsupported Linux distribution. Only Debian/Ubuntu and RHEL/CentOS/Fedora are supported."
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-PreflightChecks {
    Write-Step "Running pre-flight checks"

    # On Windows, verify WSL is available
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $wslExe = Get-Command wsl -ErrorAction SilentlyContinue
        if (-not $wslExe) {
            throw "WSL is not installed or not on PATH. Enable WSL2 first: https://aka.ms/wsl2"
        }
        Write-Success "WSL found: $($wslExe.Source)"

        # Check the target distro is running
        $distros = wsl --list --quiet 2>$null
        if ($WSLDistro -ne '' -and ($distros -notcontains $WSLDistro)) {
            throw "WSL distribution '$WSLDistro' not found. Available: $($distros -join ', ')"
        }
    }

    # Check NVIDIA driver is visible inside the shell environment
    try {
        $nvidiaSmi = Invoke-Shell -Command @('nvidia-smi', '--query-gpu=name', '--format=csv,noheader')
        Write-Success "NVIDIA GPU detected: $($nvidiaSmi -join ', ')"
    } catch {
        Write-Warn "nvidia-smi not found or no GPU detected. Continuing anyway — ensure the NVIDIA driver is installed."
    }

    # Check the selected container runtime exists
    try {
        Invoke-Shell -Command @('which', $ContainerRuntime) | Out-Null
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

    # 1. Install prerequisites
    Write-Verbose "Installing curl and gnupg..."
    Invoke-Sudo @('apt-get', 'update', '-y')
    Invoke-Sudo @('apt-get', 'install', '-y', 'curl', 'gnupg', 'ca-certificates')

    # 2. Add NVIDIA GPG key
    Write-Step "Adding NVIDIA GPG key"
    $keyCmd = @(
        'bash', '-c',
        'curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | ' +
        'gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg'
    )
    Invoke-Sudo $keyCmd -ErrorMessage "Failed to add NVIDIA GPG key"
    Write-Success "GPG key added."

    # 3. Add apt repository
    Write-Step "Adding NVIDIA apt repository"
    $repoCmd = @(
        'bash', '-c',
        'curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | ' +
        "sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' | " +
        'tee /etc/apt/sources.list.d/nvidia-container-toolkit.list'
    )
    Invoke-Sudo $repoCmd -ErrorMessage "Failed to add apt repository"
    Write-Success "Repository added."

    # 4. Install toolkit
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

    # Detect package manager
    $pkgMgr = 'yum'
    try { Invoke-Shell @('which', 'dnf') | Out-Null; $pkgMgr = 'dnf' } catch {}

    # 1. Add NVIDIA repository
    Write-Step "Adding NVIDIA dnf/yum repository"
    $repoCmd = @(
        'bash', '-c',
        'curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | ' +
        'tee /etc/yum.repos.d/nvidia-container-toolkit.repo'
    )
    Invoke-Sudo $repoCmd -ErrorMessage "Failed to add yum/dnf repository"
    Write-Success "Repository added."

    # 2. Install toolkit
    Write-Step "Installing nvidia-container-toolkit"
    Invoke-Sudo @($pkgMgr, 'install', '-y', 'nvidia-container-toolkit')
    Write-Success "nvidia-container-toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Post-install runtime configuration
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-RuntimeConfig {
    Write-Step "Configuring runtime: $ContainerRuntime"

    switch ($ContainerRuntime) {
        'docker' {
            Invoke-Sudo @('nvidia-ctk', 'runtime', 'configure', '--runtime=docker')
            Write-Success "Docker runtime configured."

            Write-Step "Restarting Docker daemon"
            Invoke-Sudo @('systemctl', 'restart', 'docker') -ErrorMessage `
                "Failed to restart Docker. If running in WSL without systemd, restart Docker manually."
            Write-Success "Docker restarted."
        }
        'containerd' {
            Invoke-Sudo @('nvidia-ctk', 'runtime', 'configure', '--runtime=containerd')
            Write-Success "containerd runtime configured."

            Write-Step "Restarting containerd"
            Invoke-Sudo @('systemctl', 'restart', 'containerd')
            Write-Success "containerd restarted."
        }
        'crio' {
            Invoke-Sudo @('nvidia-ctk', 'runtime', 'configure', '--runtime=crio')
            Write-Success "CRI-O runtime configured."

            Write-Step "Restarting CRI-O"
            Invoke-Sudo @('systemctl', 'restart', 'crio')
            Write-Success "CRI-O restarted."
        }
    }
}

# ──────────────────────────────────────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────────────────────────────────────

function Invoke-Verification {
    Write-Step "Verifying installation"

    try {
        $version = Invoke-Shell @('nvidia-ctk', '--version')
        Write-Success "nvidia-ctk version: $version"
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
# Main
# ──────────────────────────────────────────────────────────────────────────────

function Main {
    Write-Host "`nNVIDIA Container Toolkit Installer" -ForegroundColor Magenta
    Write-Host "====================================" -ForegroundColor Magenta
    Write-Host "  Runtime  : $ContainerRuntime"
    if ($IsWindows -or $env:OS -eq 'Windows_NT') {
        $distroLabel = if ($WSLDistro) { $WSLDistro } else { '(default)' }
        Write-Host "  WSL Distro: $distroLabel"
    }
    Write-Host ""

    try {
        Invoke-PreflightChecks

        $family = Get-LinuxDistroFamily
        switch ($family) {
            'debian' { Install-DebianBased }
            'rhel'   { Install-RhelBased   }
        }

        if (-not $SkipRuntimeConfig) {
            Invoke-RuntimeConfig
        } else {
            Write-Warn "Skipping runtime configuration (-SkipRuntimeConfig was set)."
        }

        Invoke-Verification

        Write-Host "`n====================================`n" -ForegroundColor Magenta
        Write-Host "Installation complete!" -ForegroundColor Green
        Write-Host "NVIDIA Container Toolkit is ready for GPU-accelerated containers.`n" `
            -ForegroundColor Green

    } catch {
        Write-Fail $_.Exception.Message
        Write-Host "`nInstallation failed. See the error above for details." -ForegroundColor Red
        exit 1
    }
}

Main
