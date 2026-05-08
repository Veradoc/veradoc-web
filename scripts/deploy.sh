#!/usr/bin/env bash
# --- VeraDoc Start (Bash) ---

set -euo pipefail

BASE_URL="https://veradoc.ai/compose"
BASE_COMPOSE="docker-base.yml"
LLM_COMPOSE="docker-llm.yml"

CYAN='\033[0;36m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
GRAY='\033[0;37m'
RED='\033[0;31m'
NC='\033[0m'

OLLAMA_HOST="${OLLAMA_HOST:-http://localhost:11434}"
USE_NATIVE_OLLAMA=false

DEFAULT_MODELS=(
    "phi3:3.8b-mini-128k-instruct-q8_0"
    "nomic-embed-text:v1.5"
)

# 1. Self-Bootstrap: Download files if they are missing
for file in "$BASE_COMPOSE" "$LLM_COMPOSE"; do
    if [ ! -f "$file" ]; then
        echo -e "${CYAN}Fetching $file from server...${NC}"
        if ! curl -fsSL "$BASE_URL/$file" -o "$file"; then
            echo -e "${RED}Error: Failed to download $file. Check your internet connection.${NC}" >&2
            exit 1
        fi
    fi
done

# 2. OS + Hardware Detection
OS="$(uname -s)"
ARCH="$(uname -m)"
HAS_GPU=false

case "$OS" in
    Linux)
        if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
            HAS_GPU=true
            echo -e "${CYAN}NVIDIA GPU detected. Activating hardware acceleration...${NC}"
        else
            echo -e "${YELLOW}No NVIDIA GPU detected. Deploying in CPU-only mode...${NC}"
        fi
        ;;
    Darwin)
        if [ "$ARCH" = "arm64" ]; then
            echo -e "${CYAN}Apple Silicon detected. Using native Ollama with Metal GPU acceleration.${NC}"
            USE_NATIVE_OLLAMA=true
        else
            echo -e "${YELLOW}macOS Intel detected (GPU not accessible inside Docker). Deploying in CPU-only mode...${NC}"
        fi
        ;;
    *)
        echo -e "${YELLOW}Unknown OS ($OS). Deploying in CPU-only mode...${NC}"
        ;;
esac

# ---------------------------------------------------------------------------
# Helpers (native Ollama path only)
# ---------------------------------------------------------------------------

ollama_wait_ready() {
    echo -e "${CYAN}Waiting for Ollama API...${NC}"
    for i in $(seq 1 15); do
        if curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
            echo -e "${GREEN}Ollama is ready.${NC}"
            return 0
        fi
        sleep 1
    done
    echo -e "${RED}Error: Ollama did not become ready in time. Check /tmp/ollama.log${NC}" >&2
    exit 1
}

ollama_model_exists() {
    local model="$1"
    curl -sf "${OLLAMA_HOST}/api/tags" \
        | grep -q "\"${model}\""
}

ollama_pull() {
    local model="$1"
    echo -e "${CYAN}Pulling ${model}...${NC}"
    # /api/pull streams NDJSON — forward it so the user sees progress
    curl -sf -X POST "${OLLAMA_HOST}/api/pull" \
        -d "{\"name\": \"${model}\"}" \
        --no-buffer \
        | while IFS= read -r line; do
            status=$(echo "$line" | grep -o '"status":"[^"]*"' | cut -d'"' -f4 || true)
            [ -n "$status" ] && echo -e "${GRAY}  ${model}: ${status}${NC}"
        done
    echo -e "${GREEN}  ${model}: pull complete.${NC}"
}

ollama_warmup() {
    local model="$1"
    echo -e "${CYAN}Warming up ${model}...${NC}"

    case "$model" in
        nomic-embed-text*)
            curl -sf -X POST "${OLLAMA_HOST}/api/embeddings" \
                -d "{\"model\": \"${model}\", \"keep_alive\": -1}" &>/dev/null
            ;;
        *)
            curl -sf -X POST "${OLLAMA_HOST}/api/generate" \
                -d "{\"model\": \"${model}\", \"prompt\": \"hello\", \"keep_alive\": -1}" &>/dev/null
            ;;
    esac

    echo -e "${GREEN}  ${model}: warm-up done.${NC}"
}

ollama_verify() {
    echo -e "${CYAN}Verifying loaded models...${NC}"
    curl -sf "${OLLAMA_HOST}/api/ps" | grep -o '"name":"[^"]*"' \
        | while IFS= read -r entry; do
            name=$(echo "$entry" | cut -d'"' -f4)
            echo -e "${GREEN}  ✓ ${name}${NC}"
        done
}

# ---------------------------------------------------------------------------
# 3. Native Ollama setup (Apple Silicon only)
# ---------------------------------------------------------------------------

if [ "$USE_NATIVE_OLLAMA" = true ]; then

    # --- Install if missing ---
    if ! command -v ollama &>/dev/null; then
        echo -e "${YELLOW}Ollama not found. Installing via Homebrew...${NC}"
        if ! command -v brew &>/dev/null; then
            echo -e "${RED}Error: Homebrew is required. Install it from https://brew.sh${NC}" >&2
            exit 1
        fi
        brew install ollama
    fi

    # --- Start service if not already running ---
    if ! curl -sf "${OLLAMA_HOST}/api/tags" &>/dev/null; then
        echo -e "${CYAN}Starting Ollama service...${NC}"
        ollama serve &>/tmp/ollama.log &
        ollama_wait_ready
    else
        echo -e "${GREEN}Ollama is already running at ${OLLAMA_HOST}.${NC}"
    fi

    # --- Pull + warm up each default model ---
    for model in "${DEFAULT_MODELS[@]}"; do
        if ollama_model_exists "$model"; then
            echo -e "${GREEN}Model already present: ${model}${NC}"
        else
            ollama_pull "$model"
        fi
        ollama_warmup "$model"
    done

    # --- Verify (mirrors the sidecar's final check) ---
    ollama_verify

fi

# ---------------------------------------------------------------------------
# 4. Deploy Docker Services
# ---------------------------------------------------------------------------

echo -e "${GRAY}--- Starting Services ---${NC}"

if [ "$USE_NATIVE_OLLAMA" = true ]; then
    # LLM compose not needed — Ollama runs natively on the host.
    # Pass OLLAMA_HOST so app containers reach it via host.docker.internal.
    OLLAMA_HOST="http://host.docker.internal:11434" \
        docker compose -f "$BASE_COMPOSE" up -d
elif [ "$HAS_GPU" = true ]; then
    docker compose -f "$BASE_COMPOSE" -f "$LLM_COMPOSE" up -d
else
    docker compose -f "$BASE_COMPOSE" up -d
fi

echo -e "${GREEN}--- Services Started ---${NC}"
echo "UI:      http://localhost:4200"