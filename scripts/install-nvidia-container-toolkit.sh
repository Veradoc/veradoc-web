#!/usr/bin/env bash
# =============================================================================
# install-nvidia-container-toolkit.sh
#
# Installs the NVIDIA Container Toolkit on Debian/Ubuntu or RHEL/CentOS/Fedora.
#
# Usage:
#   chmod +x install-nvidia-container-toolkit.sh
#   ./install-nvidia-container-toolkit.sh [OPTIONS]
#
# Options:
#   -r, --runtime <runtime>   Container runtime to configure: docker (default),
#                             containerd, crio
#   -s, --skip-config         Install only, skip runtime configuration
#   -h, --help                Show this help message
#
# Examples:
#   ./install-nvidia-container-toolkit.sh
#   ./install-nvidia-container-toolkit.sh --runtime containerd
#   ./install-nvidia-container-toolkit.sh --runtime docker --skip-config
#
# Prerequisites:
#   - Supported NVIDIA GPU with host driver installed
#   - Docker / containerd / CRI-O already installed
#   - curl, sudo, and internet access
#
# Docs: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/latest/install-guide.html
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────

RUNTIME="docker"
SKIP_CONFIG=false

# ──────────────────────────────────────────────────────────────────────────────
# Colours
# ──────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_CYAN="\033[0;36m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[0;31m"
    C_MAGENTA="\033[0;35m"
    C_RESET="\033[0m"
else
    C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA="" C_RESET=""
fi

step()    { echo -e "\n${C_CYAN}==> $*${C_RESET}"; }
success() { echo -e "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn()    { echo -e "    ${C_YELLOW}[WARN]${C_RESET} $*"; }
fail()    { echo -e "\n${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

# ──────────────────────────────────────────────────────────────────────────────
# Argument parsing
# ──────────────────────────────────────────────────────────────────────────────

usage() {
    grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--runtime)
            RUNTIME="${2:-}"
            [[ "$RUNTIME" =~ ^(docker|containerd|crio)$ ]] || \
                fail "Invalid runtime '$RUNTIME'. Choose: docker, containerd, crio."
            shift 2
            ;;
        -s|--skip-config)
            SKIP_CONFIG=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            fail "Unknown option: $1  (use --help for usage)"
            ;;
    esac
done

# ──────────────────────────────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────────────────────────────

require_root() {
    if [[ $EUID -ne 0 ]]; then
        # Re-exec with sudo, passing all original args
        exec sudo bash "$0" "$@"
    fi
}

detect_distro_family() {
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        source /etc/os-release
        local id_like="${ID_LIKE:-} ${ID:-}"
        if echo "$id_like" | grep -qiE 'debian|ubuntu'; then
            echo "debian"
        elif echo "$id_like" | grep -qiE 'rhel|centos|fedora|sles|opensuse'; then
            echo "rhel"
        else
            fail "Unsupported distribution: ${PRETTY_NAME:-unknown}. Only Debian/Ubuntu and RHEL/CentOS/Fedora are supported."
        fi
    else
        fail "/etc/os-release not found. Cannot detect distribution."
    fi
}

detect_pkg_manager() {
    for pm in dnf yum; do
        if command -v "$pm" &>/dev/null; then
            echo "$pm"
            return
        fi
    done
    fail "No supported package manager found (dnf/yum)."
}

# ──────────────────────────────────────────────────────────────────────────────
# Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    step "Running pre-flight checks"

    # NVIDIA GPU / driver
    if command -v nvidia-smi &>/dev/null; then
        local gpu
        gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
        [[ -n "$gpu" ]] && success "GPU detected: $gpu" || warn "nvidia-smi found but no GPU reported."
    else
        warn "nvidia-smi not found. Ensure the NVIDIA driver is installed on the host."
    fi

    # Container runtime
    if command -v "$RUNTIME" &>/dev/null; then
        success "Container runtime '$RUNTIME' found."
    else
        warn "'$RUNTIME' not found on PATH. Install it before using the toolkit."
    fi

    # curl
    command -v curl &>/dev/null || fail "curl is required but not installed."

    success "Pre-flight checks done."
}

# ──────────────────────────────────────────────────────────────────────────────
# Install — Debian / Ubuntu
# ──────────────────────────────────────────────────────────────────────────────

install_debian() {
    step "Detected Debian/Ubuntu — using apt"

    step "Updating package index and installing prerequisites"
    apt-get update -y
    apt-get install -y curl gnupg ca-certificates
    success "Prerequisites installed."

    step "Adding NVIDIA GPG key"
    curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
    success "GPG key saved to /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg"

    step "Adding NVIDIA apt repository"
    curl -sL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
        | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
        | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list > /dev/null
    success "Repository written to /etc/apt/sources.list.d/nvidia-container-toolkit.list"

    step "Installing nvidia-container-toolkit"
    apt-get update -y
    apt-get install -y nvidia-container-toolkit
    success "nvidia-container-toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Install — RHEL / CentOS / Fedora
# ──────────────────────────────────────────────────────────────────────────────

install_rhel() {
    step "Detected RHEL/CentOS/Fedora — using $(detect_pkg_manager)"
    local pm
    pm=$(detect_pkg_manager)

    step "Adding NVIDIA dnf/yum repository"
    curl -sL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
        | tee /etc/yum.repos.d/nvidia-container-toolkit.repo > /dev/null
    success "Repository written to /etc/yum.repos.d/nvidia-container-toolkit.repo"

    step "Installing nvidia-container-toolkit"
    "$pm" install -y nvidia-container-toolkit
    success "nvidia-container-toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Runtime configuration
# ──────────────────────────────────────────────────────────────────────────────

configure_runtime() {
    step "Configuring runtime: $RUNTIME"
    nvidia-ctk runtime configure --runtime="$RUNTIME"
    success "Runtime configuration written."

    step "Restarting $RUNTIME"
    if command -v systemctl &>/dev/null && systemctl is-active --quiet "$RUNTIME" 2>/dev/null; then
        systemctl restart "$RUNTIME"
        success "$RUNTIME restarted via systemctl."
    else
        warn "systemctl not available or '$RUNTIME' service not active. Restart it manually."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# Verification
# ──────────────────────────────────────────────────────────────────────────────

verify_install() {
    step "Verifying installation"

    if command -v nvidia-ctk &>/dev/null; then
        local ver
        ver=$(nvidia-ctk --version 2>&1 | head -1)
        success "nvidia-ctk: $ver"
    else
        warn "nvidia-ctk not on PATH. You may need to open a new shell."
    fi

    echo ""
    echo -e "${C_MAGENTA}Quick smoke-test (requires a running Docker daemon):${C_RESET}"
    echo "  docker run --rm --gpus all nvidia/cuda:12.3.0-base-ubuntu22.04 nvidia-smi"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

main() {
    require_root "$@"

    echo -e "\n${C_MAGENTA}NVIDIA Container Toolkit Installer${C_RESET}"
    echo -e "${C_MAGENTA}====================================${C_RESET}"
    echo "  Runtime      : $RUNTIME"
    echo "  Skip config  : $SKIP_CONFIG"
    echo ""

    preflight_checks

    local family
    family=$(detect_distro_family)

    case "$family" in
        debian) install_debian ;;
        rhel)   install_rhel   ;;
    esac

    if [[ "$SKIP_CONFIG" == false ]]; then
        configure_runtime
    else
        warn "Skipping runtime configuration (--skip-config was set)."
    fi

    verify_install

    echo -e "\n${C_MAGENTA}====================================${C_RESET}"
    echo -e "${C_GREEN}Installation complete!${C_RESET}"
    echo -e "NVIDIA Container Toolkit is ready for GPU-accelerated containers.\n"
}

main "$@"
