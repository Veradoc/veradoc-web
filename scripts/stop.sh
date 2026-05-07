#!/usr/bin/env bash
# --- VeraDoc Stop (Bash) ---

set -euo pipefail

BASE_COMPOSE="docker-base.yml"
LLM_COMPOSE="docker-llm.yml"

YELLOW='\033[1;33m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${YELLOW}Stopping VeraDoc and cleaning volumes...${NC}"
docker compose -f "$BASE_COMPOSE" -f "$LLM_COMPOSE" down -v --rmi local
echo -e "${GREEN}Done.${NC}"
