#!/bin/bash

if docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
  echo "🚀 NVIDIA GPU detected, starting with GPU support..."
  docker compose -f docker-base.yaml -f docker-gpu.yaml up -d
else
  echo "🚀 No GPU detected, starting without GPU..."
  docker compose -f docker-base.yaml up -d
fi

echo "✅ Services started"
docker compose -f docker-base.yaml ps