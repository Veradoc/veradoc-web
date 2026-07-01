#!/usr/bin/env bash
# =============================================================================
# deploy.sh — VeraDoc Deployment Orchestrator (Linux + macOS)
#
# Downloads required Compose files and installer scripts from veradoc.ai if
# missing, detects platform and GPU availability, and brings the stack up or down.
# Optionally installs the NVIDIA Container Toolkit after a successful deploy.
#
# Usage:
#   chmod +x deploy.sh
#   ./deploy.sh [OPTIONS]
#
# Options:
#   -d, --down                Tear down the stack (removes volumes + local images)
#   -n, --nvidia              Install NVIDIA Container Toolkit after deploy (Linux only)
#   -r, --runtime <runtime>   Runtime to configure with NVIDIA toolkit:
#                             docker (default), containerd, crio
#   -h, --help                Show this help message
#
# Examples:
#   ./deploy.sh                          # Standard deploy (auto-detects GPU)
#   ./deploy.sh --nvidia                 # Deploy + install NVIDIA toolkit (Linux only)
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
LLM_GPU_COMPOSE="docker-llm-gpu.yml"
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
# Platform detection (set once, used everywhere)
# ──────────────────────────────────────────────────────────────────────────────

OS="$(uname -s)"    # Darwin | Linux
ARCH="$(uname -m)"  # arm64 | x86_64 | aarch64

IS_MAC=false
IS_LINUX=false
IS_MAC_SILICON=false

case "$OS" in
    Darwin)
        IS_MAC=true
        [[ "$ARCH" == "arm64" ]] && IS_MAC_SILICON=true
        ;;
    Linux)
        IS_LINUX=true
        ;;
    *)
        echo "Unsupported OS: $OS" >&2
        exit 1
        ;;
esac

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
            # Guard: NVIDIA toolkit is Linux-only
            if [[ "$IS_MAC" == "true" ]]; then
                fail "--nvidia is not supported on macOS. Apple Silicon uses Metal GPU natively via Ollama."
            fi
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

download_file() {
    local file="$1"
    local base_uri="$2"
    local dest="$SCRIPT_DIR/$file"

    info "Downloading $file ..."
    curl -fsSL "$base_uri/$file" -o "$dest" \
        || fail "Failed to download $file from $base_uri. Check your internet connection."
    success "$file downloaded."
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. Self-bootstrap: download all required files if missing
#    On macOS the NVIDIA script is skipped — it will never be needed
# ──────────────────────────────────────────────────────────────────────────────

bootstrap() {
    step "Checking required files"

    download_file "$BASE_COMPOSE" "$COMPOSE_URL"
    download_file "$LLM_COMPOSE"  "$COMPOSE_URL"

    if [[ "$IS_LINUX" == "true" ]]; then
        download_file "$LLM_GPU_COMPOSE"  "$COMPOSE_URL"    
        download_file "$NVIDIA_SCRIPT" "$SCRIPTS_URL"
        chmod +x "$SCRIPT_DIR/$NVIDIA_SCRIPT"
    else
        info "Skipping NVIDIA script download (not needed on macOS)."
        info "Skipping LLM NVIDIA deployment download (not needed on macOS)."
    fi
}

# ──────────────────────────────────────────────────────────────────────────────
# 2. Pre-flight checks
# ──────────────────────────────────────────────────────────────────────────────

preflight_checks() {
    step "Pre-flight checks"

    command -v docker &>/dev/null || fail "docker is not installed or not on PATH."
    success "Docker found."

    docker info &>/dev/null       || fail "Docker daemon is not running. Start Docker Desktop and try again."
    success "Docker daemon is running."

    command -v curl &>/dev/null   || fail "curl is required but not installed."
    success "curl found."

    # On Mac Silicon warn if images may need Rosetta emulation
    if [[ "$IS_MAC_SILICON" == "true" ]]; then
        warn "Apple Silicon (${ARCH}) detected."
        warn "Some Docker images may run under Rosetta 2 emulation (amd64)."
        warn "For best performance, ensure arm64 images are available in your Compose files."
    fi

    success "Pre-flight checks passed."
}

# ──────────────────────────────────────────────────────────────────────────────
# 3. GPU detection
#    - Linux:       checks nvidia-smi
#    - Mac Silicon: Apple Metal GPU is available but NOT via NVIDIA/Docker
#    - Mac Intel:   no GPU acceleration available
# ──────────────────────────────────────────────────────────────────────────────

detect_gpu() {
    step "Detecting GPU"

    if [[ "$IS_MAC_SILICON" == "true" ]]; then
        warn "Apple Silicon GPU (Metal) detected."
        warn "GPU acceleration for Docker containers is not available on Apple Silicon."
        warn "Ollama running OUTSIDE Docker can use Metal — consider native Ollama install:"
        info "  brew install ollama && ollama serve"
        return 1
    fi

    if [[ "$IS_MAC" == "true" ]]; then
        warn "Mac Intel detected — no GPU acceleration available. Deploying CPU-only."
        return 1
    fi

    # Linux: check for NVIDIA GPU via nvidia-smi
    if command -v nvidia-smi &>/dev/null; then
        local gpu
        gpu=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
        if [[ -n "$gpu" ]]; then
            success "NVIDIA GPU detected: $gpu"
            return 0
        fi
    fi

    warn "No NVIDIA GPU detected — deploying in CPU-only mode."
    return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 3b. NVIDIA Container Toolkit detection
# ──────────────────────────────────────────────────────────────────────────────

nvidia_toolkit_installed() {
    # nvidia-ctk present AND Docker runtime configured
    if ! command -v nvidia-ctk &>/dev/null; then
        return 1
    fi
    if ! docker info 2>/dev/null | grep -q "nvidia"; then
        return 1
    fi
    return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# 4. Build docker compose argument list
#    On Mac Silicon we inject --platform linux/arm64 via DOCKER_DEFAULT_PLATFORM
# ──────────────────────────────────────────────────────────────────────────────

compose_args() {
    local with_gpu="$1"
    local args=("docker" "compose"
        "-f" "$SCRIPT_DIR/$BASE_COMPOSE"
        "-f" "$SCRIPT_DIR/$LLM_COMPOSE")
    [[ "$with_gpu" == "true" ]] && args+=("-f" "$SCRIPT_DIR/$LLM_GPU_COMPOSE")
    echo "${args[@]}"
}

set_platform_env() {
    if [[ "$IS_MAC_SILICON" == "true" ]]; then
        # Prefer native arm64 images; Docker falls back to amd64+Rosetta if unavailable
        export DOCKER_DEFAULT_PLATFORM="linux/arm64"
        info "DOCKER_DEFAULT_PLATFORM set to linux/arm64"
    fi
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
    local has_gpu="$1"
    local mode
    mode=$(if [[ "$has_gpu" == "true" ]]; then echo "GPU mode"; else echo "CPU-only mode"; fi)

    # shellcheck disable=SC2046
    local ca; ca=$(compose_args "$has_gpu")

    set_platform_env

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
# 7. Install NVIDIA Container Toolkit (Linux only)
# ──────────────────────────────────────────────────────────────────────────────

install_nvidia_toolkit() {
    step "Installing NVIDIA Container Toolkit"
    info "Running: $NVIDIA_SCRIPT --runtime $NVIDIA_RUNTIME"
    bash "$SCRIPT_DIR/$NVIDIA_SCRIPT" --runtime "$NVIDIA_RUNTIME" \
        || fail "NVIDIA toolkit installer failed."
    success "NVIDIA Container Toolkit installed."
    info "Restarting Docker daemon to apply runtime changes..."
    sudo systemctl restart docker \
        || fail "Failed to restart Docker. Please run: sudo systemctl restart docker"
    success "Docker daemon restarted."
}

# ──────────────────────────────────────────────────────────────────────────────
# 8. Detect local IP to configure frontend
# ──────────────────────────────────────────────────────────────────────────────
detect_host_ip() {
  local IP=""

  # Linux: hostname -I
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -n "$IP" ] && echo "$IP" && return

  # Linux: ip route
  IP=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')
  [ -n "$IP" ] && echo "$IP" && return

  # macOS
  IP=$(ipconfig getifaddr en0 2>/dev/null)
  [ -n "$IP" ] && echo "$IP" && return

  # macOS fallback (Wi-Fi)
  IP=$(ipconfig getifaddr en1 2>/dev/null)
  [ -n "$IP" ] && echo "$IP" && return

  # Last resort
  echo "127.0.0.1"
}

host_ip_env_variables() {
    # get local host IP
    step "Define Host IP environment variables."    
    export HOST_IP=$(detect_host_ip)
    success "Detected host IP : $HOST_IP"

    # export for docker compose
    export API_URL="http://${HOST_IP}:8808"
    export WS_URL="ws://${HOST_IP}:8808"    
    success "API URL : http://${HOST_IP}:8808"
    success "WS  URL : ws://${HOST_IP}:8808"
}

send_telemetry() {
    local has_gpu="$1"
    local event="$2"

    local version="1.0.0"
    local gpu="none"
    if [ "$has_gpu" = "true" ]; then
        gpu="true"
    fi

    curl -s --max-time 5 \
        -X POST "https://veradoc-telemetry.veradocai.workers.dev" \
        -H "Content-Type: application/json" \
        -d "{\"event\":\"${event}\",\"version\":\"${version}\",\"os\":\"linux\",\"gpu\":\"${gpu}\"}" \
        > /dev/null 2>&1 || true
}

# ──────────────────────────────────────────────────────────────────────────────
# Main
# ──────────────────────────────────────────────────────────────────────────────

main() {
    local action
    action=$(if [[ "$DO_DOWN" == "true" ]]; then echo "Teardown"; else echo "Deploy"; fi)

    # Resolve platform label for display
    local platform_label
    if [[ "$IS_MAC_SILICON" == "true" ]]; then
        platform_label="macOS Apple Silicon (${ARCH})"
    elif [[ "$IS_MAC" == "true" ]]; then
        platform_label="macOS Intel (${ARCH})"
    else
        platform_label="Linux (${ARCH})"
    fi

    echo -e "\n${C_MAGENTA}VeraDoc $action${C_RESET}"
    echo -e "${C_MAGENTA}================================${C_RESET}"
    echo "  Platform: $platform_label"
    local nvidia_label
    nvidia_label=$(if [[ "$INSTALL_NVIDIA" == "true" && "$DO_DOWN" == "false" ]]; then echo "yes ($NVIDIA_RUNTIME)"; else echo "no"; fi)
    echo "  NVIDIA toolkit: $nvidia_label"
    echo ""

    bootstrap
    preflight_checks
    host_ip_env_variables

    if [[ "$DO_DOWN" == "true" ]]; then
        do_down
    else
        local has_gpu="false"
        detect_gpu && has_gpu="true" || true

        # ── Auto-install NVIDIA Container Toolkit if GPU present but toolkit missing ──
        if [[ "$has_gpu" == "true" && "$IS_LINUX" == "true" ]]; then
            if nvidia_toolkit_installed; then
                success "NVIDIA Container Toolkit already installed."
            else
                warn "NVIDIA GPU detected but Container Toolkit is not installed."
                warn "Without it, Docker cannot access the GPU (you will get a device driver error)."
                echo ""
                echo -en "  ${C_YELLOW}Install NVIDIA Container Toolkit now? [Y/n]:${C_RESET} "
                local answer
                read -r answer </dev/tty
                answer="${answer:-Y}"
                if [[ "$answer" =~ ^[Yy]$ ]]; then
                    install_nvidia_toolkit
                else
                    warn "Skipping toolkit install. Falling back to CPU-only mode."
                    has_gpu="false"
                fi
            fi
        fi

        # get deployment installation
        local veradoc_event="install"
        if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "veradoc"; then
            veradoc_event="update"
        fi

        do_deploy "$has_gpu"

        # send telemetry status
        send_telemetry "$has_gpu" "$veradoc_event"

        # Mac Silicon tip: suggest native Ollama for best GPU performance
        if [[ "$IS_MAC_SILICON" == "true" ]]; then
            echo ""
            echo -e "  ${C_YELLOW}💡 Tip for Apple Silicon:${C_RESET}"
            echo -e "  ${C_GRAY}For GPU-accelerated inference, run Ollama natively:${C_RESET}"
            echo -e "  ${C_WHITE}  brew install ollama && ollama serve${C_RESET}"
        fi
    fi

    echo -e "\n${C_MAGENTA}================================${C_RESET}"
    echo -e "${C_GREEN}VeraDoc $action complete!${C_RESET}\n"
}

main "$@"
