#!/bin/bash

echo "🛑 Stopping services..."

if docker info 2>/dev/null | grep -q "Runtimes.*nvidia"; then
  docker compose -f docker-base.yaml -f docker-gpu.yaml down
else
  docker compose -f docker-base.yaml down
fi

echo "✅ Services stopped"