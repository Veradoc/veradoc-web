#!/usr/bin/env bash
# VeraDoc Uninstall — downloads undeploy.sh and runs it.
# Usage: curl -fsSL https://veradoc.ai/uninstall.sh | bash

set -euo pipefail

UNDEPLOY_URL="https://veradoc.ai/scripts/undeploy.sh"
UNDEPLOY_PATH="$(pwd)/undeploy.sh"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
NC='\033[0m'

echo -e "${YELLOW}⚠️  This will stop and remove VeraDoc from your system.${NC}"
read -rp "Are you sure you want to uninstall VeraDoc? (y/N): " confirm

if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
    echo -e "${CYAN}Uninstall cancelled.${NC}"
    exit 0
fi

echo -e "${CYAN}Downloading latest undeploy.sh...${NC}"

if command -v curl &>/dev/null; then
    curl -fsSL "$UNDEPLOY_URL" -o "$UNDEPLOY_PATH"
elif command -v wget &>/dev/null; then
    wget -q "$UNDEPLOY_URL" -O "$UNDEPLOY_PATH"
else
    echo -e "${RED}[ERROR] Neither curl nor wget found. Please install one and retry.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] undeploy.sh ready.${NC}"

chmod +x "$UNDEPLOY_PATH"
bash "$UNDEPLOY_PATH"
