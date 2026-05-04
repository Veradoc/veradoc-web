#!/bin/bash

# 1. Get the directory where THIS script is located
# This ensures paths work even if the user calls the script from elsewhere
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"

# Configuration
COMPOSE_DIR="$REPO_ROOT/compose"
BASE_COMPOSE="$COMPOSE_DIR/docker-base.yml"
LLM_COMPOSE="$COMPOSE_DIR/docker-llm.yml"

echo "--- Deployment Scripts ---"
echo $BASE_COMPOSE
echo $LLM_COMPOSE

# Check if the user wants to stop or start
if [ "$1" == "down" ]; then
    echo "Stopping DocSphere..."
    docker compose -f $BASE_COMPOSE -f $LLM_COMPOSE down -v --rmi local
    echo "Done."
    exit 0
fi

# 2. Hardware Detection
# We check if the nvidia-smi command exists and returns a 0 exit code
if command -v nvidia-smi &> /dev/null && nvidia-smi &> /dev/null; then
    HAS_GPU=true
    echo "NVIDIA GPU detected. Activating hardware acceleration..."
else
    HAS_GPU=false
    echo "No NVIDIA GPU detected. Deploying LLM in CPU-only mode..."
fi

echo "--- Deploying Services ---"

# Detect if LLM file exists
if [ "$HAS_GPU" = true ]; then
    echo "GPU override detected. Starting with NVIDIA support..."
    docker compose -f $BASE_COMPOSE -f $LLM_COMPOSE up -d
else
    echo "GPU override not found. Starting in CPU-only mode..."
    docker compose -f $BASE_COMPOSE up -d
fi

echo "--- Services Started ---"
echo "UI:      http://localhost:4200"