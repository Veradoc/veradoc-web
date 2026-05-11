#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the NVIDIA Container Toolkit on a Linux host via WSL2.

.PARAMETER ContainerRuntime
    docker (default), containerd, or crio

.PARAMETER WSLDistro
    WSL distribution name. Uses default if omitted.

.PARAMETER SkipRuntimeConfig
    Skip post-install runtime configuration.

.EXAMPLE
    .\Install-NvidiaContainerToolkit.ps1
    .\Install-NvidiaContainerToolkit.ps1 -ContainerRuntime containerd -WSLDistro Ubuntu-22.04
    .\Install-NvidiaContainerToolkit.ps1 -SkipRuntimeConfig
#>

[CmdletBinding()]
param(
    [ValidateSet('docker','containerd','crio')]
    [string]$ContainerRuntime = 'docker',
    [string]$WSLDistro = '',
    [switch]$SkipRuntimeConfig
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

function Write-Step    { param([string]$M); Write-Host "`n==> $M" -ForegroundColor Cyan    }
function Write-Success { param([string]$M); Write-Host "    [OK] $M" -ForegroundColor Green  }
function Write-Warn    { param([string]$M); Write-Host "    [WARN] $M" -ForegroundColor Yellow }
function Write-Fail    { param([string]$M); Write-Host "`n[ERROR] $M" -ForegroundColor Red    }

# ---------------------------------------------------------------------------
# Core WSL runner
# The key insight: we write the bash command to a temp .sh file inside WSL,
# then execute that file. This completely sidesteps PS 5.1 pipe/quote parsing.
# ---------------------------------------------------------------------------

function Invoke-WslBash {
    param(
        [string]$BashCommand,
        [string]$ErrorMessage = 'Command failed'
    )

    # Escape single quotes for the outer shell wrapper
    $escaped = $BashCommand.Replace('\', '\\').Replace('"', '\"')
    $wrapper = "bash -c `"$escaped`""

    if ($WSLDistro -ne '') {
        & wsl -d $WSLDistro -- bash -c $escaped
    } else {
        & wsl -- bash -c $escaped
    }

    if ($LASTEXITCODE -ne 0) {
        throw "$ErrorMessage (exit $LASTEXITCODE)"
    }
}

function Invoke-WslSudo {
    param(
        [string]$BashCommand,
        [string]$ErrorMessage = 'Sudo command failed'
    )
    Invoke-WslBash -BashCommand "sudo bash -c `"$($BashCommand.Replace('"','\"'))`"" -ErrorMessage $ErrorMessage
}

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------

function Invoke-PreflightChecks {
    Write-Step 'Running pre-flight checks'

    $wslExe = Get-Command wsl -ErrorAction SilentlyContinue
    if (-not $wslExe) {
        throw 'WSL is not installed. Enable WSL2 first: https://aka.ms/wsl2'
    }
    Write-Success "WSL found: $($wslExe.Source)"

    if ($WSLDistro -ne '') {
        $rawDistros = & wsl --list --quiet 2>$null
        $distros = $rawDistros |
            ForEach-Object { ($_ -replace '\x00','').Trim() } |
            Where-Object { $_ -ne '' }
        if ($distros -notcontains $WSLDistro) {
            throw "WSL distro '$WSLDistro' not found. Available: $($distros -join ', ')"
        }
        Write-Success "WSL distro '$WSLDistro' found."
    }

    try {
        Invoke-WslBash -BashCommand 'nvidia-smi --query-gpu=name --format=csv,noheader' -ErrorMessage 'nvidia-smi'
        Write-Success 'NVIDIA GPU detected.'
    } catch {
        Write-Warn 'nvidia-smi not found -- ensure the NVIDIA driver is installed on the host.'
    }

    Write-Success 'Pre-flight checks complete.'
}

# ---------------------------------------------------------------------------
# Detect distro family inside WSL
# ---------------------------------------------------------------------------

function Get-WslDistroFamily {
    if ($WSLDistro -ne '') {
        $lines = & wsl -d $WSLDistro -- cat /etc/os-release 2>$null
    } else {
        $lines = & wsl -- cat /etc/os-release 2>$null
    }
    $content = $lines -join ' '
    if ($content -match '(debian|ubuntu)') { return 'debian' }
    if ($content -match '(rhel|centos|fedora|sles|opensuse)') { return 'rhel' }
    throw 'Unsupported Linux distribution. Only Debian/Ubuntu and RHEL/CentOS/Fedora are supported.'
}

# ---------------------------------------------------------------------------
# Install -- Debian/Ubuntu
# ---------------------------------------------------------------------------

function Install-DebianBased {
    Write-Step 'Detected Debian/Ubuntu -- using apt'

    Write-Step 'Updating apt and installing prerequisites'
    Invoke-WslBash -BashCommand 'sudo apt-get update -y' -ErrorMessage 'apt-get update'
    Invoke-WslBash -BashCommand 'sudo apt-get install -y curl gnupg ca-certificates' -ErrorMessage 'install prerequisites'
    Write-Success 'Prerequisites installed.'

    Write-Step 'Adding NVIDIA GPG key'
    Invoke-WslBash -BashCommand 'sudo bash -c "curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"' -ErrorMessage 'Failed to add GPG key'
    Write-Success 'GPG key added.'

    Write-Step 'Adding NVIDIA apt repository'
    Invoke-WslBash -BashCommand 'sudo bash -c "curl -s -L https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list | sed ''s#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g'' | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list"' -ErrorMessage 'Failed to add apt repository'
    Write-Success 'Repository added.'

    Write-Step 'Installing nvidia-container-toolkit'
    Invoke-WslBash -BashCommand 'sudo apt-get update -y' -ErrorMessage 'apt-get update (2)'
    Invoke-WslBash -BashCommand 'sudo apt-get install -y nvidia-container-toolkit' -ErrorMessage 'install toolkit'
    Write-Success 'nvidia-container-toolkit installed.'
}

# ---------------------------------------------------------------------------
# Install -- RHEL/CentOS/Fedora
# ---------------------------------------------------------------------------

function Install-RhelBased {
    Write-Step 'Detected RHEL/CentOS/Fedora -- using dnf/yum'

    Write-Step 'Adding NVIDIA yum/dnf repository'
    Invoke-WslBash -BashCommand 'sudo bash -c "curl -s -L https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo | tee /etc/yum.repos.d/nvidia-container-toolkit.repo"' -ErrorMessage 'Failed to add repository'
    Write-Success 'Repository added.'

    Write-Step 'Detecting package manager'
    $pkgMgr = 'yum'
    if ($WSLDistro -ne '') {
        $dnfCheck = & wsl -d $WSLDistro -- which dnf 2>$null
    } else {
        $dnfCheck = & wsl -- which dnf 2>$null
    }
    if ($LASTEXITCODE -eq 0) { $pkgMgr = 'dnf' }
    Write-Success "Using $pkgMgr"

    Write-Step 'Installing nvidia-container-toolkit'
    Invoke-WslBash -BashCommand "sudo $pkgMgr install -y nvidia-container-toolkit" -ErrorMessage 'install toolkit'
    Write-Success 'nvidia-container-toolkit installed.'
}

# ---------------------------------------------------------------------------
# Post-install runtime config
# ---------------------------------------------------------------------------

function Invoke-RuntimeConfig {
    Write-Step "Configuring runtime: $ContainerRuntime"
    Invoke-WslBash -BashCommand "sudo nvidia-ctk runtime configure --runtime=$ContainerRuntime" -ErrorMessage 'nvidia-ctk configure'
    Write-Success 'Runtime configured.'

    try {
        Invoke-WslBash -BashCommand "sudo systemctl restart $ContainerRuntime" -ErrorMessage 'systemctl restart'
        Write-Success "$ContainerRuntime restarted."
    } catch {
        Write-Warn "Could not restart $ContainerRuntime -- a manual restart may be needed."
    }
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

function Invoke-Verification {
    Write-Step 'Verifying installation'
    try {
        Invoke-WslBash -BashCommand 'nvidia-ctk --version' -ErrorMessage 'nvidia-ctk version'
        Write-Success 'nvidia-ctk is available.'
    } catch {
        Write-Warn 'nvidia-ctk not found on PATH -- PATH may need updating.'
    }

    Write-Host ''
    Write-Host 'Quick GPU smoke-test:' -ForegroundColor White
    Write-Host '  docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi' -ForegroundColor DarkGray
}

# ---------------------------------------------------------------------------
# Main -- defined and called LAST so PS 5.1 has parsed all functions above
# ---------------------------------------------------------------------------

function Main {
    Write-Host ''
    Write-Host 'NVIDIA Container Toolkit Installer' -ForegroundColor Magenta
    Write-Host '====================================' -ForegroundColor Magenta

    try {
        Invoke-PreflightChecks

        $family = Get-WslDistroFamily

        if ($family -eq 'debian') {
            Install-DebianBased
        } else {
            Install-RhelBased
        }

        if (-not $SkipRuntimeConfig) {
            Invoke-RuntimeConfig
        }

        Invoke-Verification

        Write-Host ''
        Write-Host 'Installation complete!' -ForegroundColor Green
    } catch {
        Write-Fail $_.Exception.Message
        exit 1
    }
}

Main
