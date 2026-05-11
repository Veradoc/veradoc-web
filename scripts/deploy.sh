#!/usr/bin/env bash
# =============================================================================
# deploy.sh — VeraDoc Deployment Orchestrator (Linux)
#
# Downloads required Compose files and installer scripts from veradoc.ai if
# missing, detects NVIDIA GPU availability, and brings the stack up or down.
# Optionally installs the NVIDIA Container Toolkit after a successful deploy.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [OPTIONS]
#
# Options:
#   -d, --down                Tear down the stack (removes volumes + local images)
#   -n, --nvidia              Install NVIDIA Container Toolkit after deploy
#   -r, --runtime <runtime>   Runtime to configure with NVIDIA toolkit:
#                             docker (default), containerd, crio
#   -h, --help                Show this help message
#
# Examples:
#   ./deploy.sh                          # Standard deploy (auto-detects GPU)
#   ./deploy.sh --nvidia                 # Deploy + install NVIDIA toolkit
#   ./deploy.sh --nvidia --runtime containerd
#   ./deploy.sh --down                   # Tear down the stack
#
# Prerequisites:
#   - Docker and Docker Compose installed
#   - curl and internet access
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Config
# ──────────────────────────────────────────────────────────────────────────────

COMPOSE_URL="https://veradoc.ai/compose"
SCRIPTS_URL="https://veradoc.ai/scripts"
BASE_COMPOSE="docker-base.yml"
LLM_COMPOSE="docker-llm.yml"
NVIDIA_SCRIPT="install-nvidia-container-toolkit.sh"
UI_PORT=4200

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────────────────────────────────────
# Defaults
# ──────────────────────────────────────────────────────────────────────────────

DO_DOWN=false
INSTALL_NVIDIA=false
NVIDIA_RUNTIME="docker"

# ──────────────────────────────────────────────────────────────────────────────
# Colours
# ──────────────────────────────────────────────────────────────────────────────

if [[ -t 1 ]]; then
    C_CYAN="\033[0;36m"
    C_GREEN="\033[0;32m"
    C_YELLOW="\033[1;33m"
    C_RED="\033[0;31m"
    C_MAGENTA="\033[0;35m"
    C_GRAY="\033[0;90m"
    C_WHITE="\033[0;97m"
    C_RESET="\033[0m"
else
    C_CYAN="" C_GREEN="" C_YELLOW="" C_RED="" C_MAGENTA="" C_GRAY="" C_WHITE="" C_RESET=""
fi

step()    { echo -e "\n${C_CYAN}==> $*${C_RESET}"; }
success() { echo -e "    ${C_GREEN}[OK]${C_RESET} $*"; }
warn()    { echo -e "    ${C_YELLOW}[WARN]${C_RESET} $*"; }
info()    { echo -e "    ${C_GRAY}$*${C_RESET}"; }
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
        -d|--down)
            DO_DOWN=true
            shift
            ;;
        -n|--nvidia)
            INSTALL_NVIDIA=true
            shift
            ;;
        -r|--runtime)
            NVIDIA_RUNTIME="${2:-}"
            [[ "$NVIDIA_RUNTIME" =~ ^(docker|containerd|crio)$ ]] || \
                fail "Invalid runtime '$NVIDIA_RUNTIME'. Choose: docker, containerd, crio."
            shift 2
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
# Helper: download a file if it is not already present
# ──────────────────────────────────────────────────────────────────────────────

download_if_missing() {
    local file="$1"
    local base_uri="$2"
    local dest="$SCRIPT_DIR/$file"

    if [[ -f "$dest" ]]; then
        success "$file already present."
        return
    fi

    info "Downloading $file ..."
    curl -fsSL "$base_uri/$file" -o "$dest" \
        || fail "Failed to download $file from $base_uri. Check your internet connection."
    success "$file downloaded."
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. Self-bootstrap: download all required files if missing
# ──────────────────────────────────────────────────────────────────────────────

bootstrap() {
    step "Checking required files"

    # Compose files
    download_if_missing "$BASE_COMPOSE" "$COMPOSE_URL"
    download_if_missing "$LLM_COMPOSE"  "$COMPOSE_URL"

    # Installer scripts
    download_if_missing "$NVIDIA_SCRIPT" "$SCRIPTS_URL"
    chmod +x "$SCRIPT_DIR/$NVIDIA_SCRIPT"
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    step "Pre-flight checks"

    command -v docker &>/dev/null   || fail "docker is not installed or not on PATH."
    success "Docker found."

    docker info &>/dev/null         || fail "Docker daemon is not running. Start it and try again."
    success "Docker daemon is running."

    command -v curl &>/dev/null     || fail "curl is required but not installed."
    success "curl found."

    success "Pre-flight checks passed."
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. GPU detection
# ──────────────────────────────────────────────────────────────────────────────

detect_gpu() {
    step "Detecting NVIDIA GPU"

    if command -v nvidia-smi &>/dev/null; then
        local gpu
        gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
        if [[ -n "$gpu" ]]; then
            success "GPU detected: $gpu"
            return 0
        fi
    fi

    warn "No NVIDIA GPU detected — deploying in CPU-only mode."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Build docker compose argument list
# ──────────────────────────────────────────────────────────────────────────────

compose_args() {
    local with_llm="$1"   # "true" or "false"
    local args=("docker" "compose" "-f" "$SCRIPT_DIR/$BASE_COMPOSE")
    [[ "$with_llm" == "true" ]] && args+=("-f" "$SCRIPT_DIR/$LLM_COMPOSE")
    echo "${args[@]}"
}

# ──────────────────────────────────────────────────────────────────────────────
# 5. Tear down
# ──────────────────────────────────────────────────────────────────────────────

do_down() {
    step "Stopping VeraDoc and cleaning volumes"
    # shellcheck disable=SC2046
    $(compose_args "true") down -v --rmi local \
        || fail "docker compose down failed."
    success "Stack stopped, volumes and local images removed."
}

# ──────────────────────────────────────────────────────────────────────────────
# 6. Deploy
# ──────────────────────────────────────────────────────────────────────────────

do_deploy() {
    local has_gpu="$1"   # "true" or "false"
    local mode
    mode=$(if [[ "$has_gpu" == "true" ]]; then echo "GPU mode"; else echo "CPU-only mode"; fi)

    # shellcheck disable=SC2046
    local ca; ca=$(compose_args "$has_gpu")

    step "Pulling latest images"
    $ca pull || fail "docker compose pull failed."
    success "Images up to date."

    step "Starting VeraDoc stack ($mode)"
    $ca up -d --remove-orphans || fail "docker compose up failed."
    success "Stack is up."

    step "Running services"
    $ca ps
}

# ──────────────────────────────────────────────────────────────────────────────
# 7. Optional: install NVIDIA Container Toolkit (post-deploy)
# ──────────────────────────────────────────────────────────────────────────────

install_nvidia_toolkit() {
    step "Installing NVIDIA Container Toolkit (post-deploy)"

    # At this point the file is guaranteed to exist — bootstrap downloaded it
    info "Running: $NVIDIA_SCRIPT --runtime $NVIDIA_RUNTIME"
    bash "$SCRIPT_DIR/$NVIDIA_SCRIPT" --runtime "$NVIDIA_RUNTIME" \
        || fail "NVIDIA toolkit installer failed."
    success "NVIDIA Container Toolkit installed."
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

main() {
    local action
    action=$(if [[ "$DO_DOWN" == "true" ]]; then echo "Teardown"; else echo "Deploy"; fi)

    echo -e "\n${C_MAGENTA}VeraDoc $action${C_RESET}"
    echo -e "${C_MAGENTA}================================${C_RESET}"
    local nvidia_label
    nvidia_label=$(if [[ "$INSTALL_NVIDIA" == "true" && "$DO_DOWN" == "false" ]]; then echo "yes ($NVIDIA_RUNTIME)"; else echo "no"; fi)
    echo "  NVIDIA toolkit: $nvidia_label"
    echo ""

    bootstrap
    preflight_checks

    if [[ "$DO_DOWN" == "true" ]]; then
        do_down
    else
        local has_gpu="false"
        detect_gpu && has_gpu="true" || true

        do_deploy "$has_gpu"

        if [[ "$INSTALL_NVIDIA" == "true" ]]; then
            install_nvidia_toolkit
        fi

        echo ""
        echo -e "  ${C_GRAY}UI:${C_RESET}  ${C_WHITE}http://localhost:${UI_PORT}${C_RESET}"
    fi

    echo -e "\n${C_MAGENTA}================================${C_RESET}"
    echo -e "${C_GREEN}VeraDoc $action complete!${C_RESET}\n"
}

main "$@"
