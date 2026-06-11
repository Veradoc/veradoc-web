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

# 2. Hardware Detection (NVIDIA)
HAS_GPU=false
if command -v nvidia-smi &>/dev/null; then
    if nvidia-smi -L &>/dev/null; then
        HAS_GPU=true
        echo -e "${CYAN}NVIDIA GPU detected. Activating hardware acceleration...${NC}"
    fi
fi

if [ "$HAS_GPU" = false ]; then
    echo -e "${YELLOW}No NVIDIA GPU detected. Deploying in CPU-only mode...${NC}"
fi

# 3. Deploy Services
echo -e "${GRAY}--- Starting Services ---${NC}"

if [ "$HAS_GPU" = true ]; then
    docker compose -f "$BASE_COMPOSE" -f "$LLM_COMPOSE" up -d
else
    docker compose -f "$BASE_COMPOSE" up -d
fi

echo -e "${GREEN}--- Services Started ---${NC}"
