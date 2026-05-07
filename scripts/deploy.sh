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
HAS_GPU=false

case "$OS" in
    Linux)
        # On Linux, check for a real NVIDIA GPU via nvidia-smi
        if command -v nvidia-smi &>/dev/null && nvidia-smi -L &>/dev/null; then
            HAS_GPU=true
            echo -e "${CYAN}NVIDIA GPU detected. Activating hardware acceleration...${NC}"
        else
            echo -e "${YELLOW}No NVIDIA GPU detected. Deploying in CPU-only mode...${NC}"
        fi
        ;;
    Darwin)
        # On macOS, Docker Desktop runs inside a Linux VM with no access
        # to the host GPU — neither NVIDIA (Intel Macs) nor Metal (Apple Silicon).
        # CPU-only mode is the only supported option.
        ARCH="$(uname -m)"
        if [ "$ARCH" = "arm64" ]; then
            echo -e "${YELLOW}Apple Silicon detected (Metal GPU not accessible inside Docker). Deploying in CPU-only mode...${NC}"
        else
            echo -e "${YELLOW}macOS Intel detected (GPU not accessible inside Docker). Deploying in CPU-only mode...${NC}"
        fi
        ;;
    *)
        echo -e "${YELLOW}Unknown OS ($OS). Deploying in CPU-only mode...${NC}"
        ;;
esac

# 3. Deploy Services
echo -e "${GRAY}--- Starting Services ---${NC}"

if [ "$HAS_GPU" = true ]; then
    docker compose -f "$BASE_COMPOSE" -f "$LLM_COMPOSE" up -d
else
    docker compose -f "$BASE_COMPOSE" up -d
fi

echo -e "${GREEN}--- Services Started ---${NC}"
echo "UI:      http://localhost:4200"