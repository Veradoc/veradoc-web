#!/usr/bin/env bash
# VeraDoc Install — downloads deploy.sh and runs it.
# Usage: curl -fsSL https://veradoc.ai/install.sh | bash

set -euo pipefail

DEPLOY_URL="https://veradoc.ai/scripts/deploy.sh"
DEPLOY_PATH="$(pwd)/deploy.sh"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m' # No Colour

echo -e "${CYAN}Downloading latest deploy.sh...${NC}"

if command -v curl &>/dev/null; then
    curl -fsSL "$DEPLOY_URL" -o "$DEPLOY_PATH"
elif command -v wget &>/dev/null; then
    wget -q "$DEPLOY_URL" -O "$DEPLOY_PATH"
else
    echo -e "${RED}[ERROR] Neither curl nor wget found. Please install one and retry.${NC}"
    exit 1
fi

echo -e "${GREEN}[OK] deploy.sh ready.${NC}"

chmod +x "$DEPLOY_PATH"
#bash "$DEPLOY_PATH"
. "$DEPLOY_PATH"

echo -e "${GREEN}🚀 Veradoc is running at http://${HOST_IP}:4200"
echo -e "${GREEN}🔒 Use these credentials to login by default:"
echo -e "${GREEN}email: admin@veradoc.ai"
echo -e "${GREEN}password: password"