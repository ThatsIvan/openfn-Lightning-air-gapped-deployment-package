#!/usr/bin/env bash
# 03-start.sh — Start OpenFn Lightning
# The compose file handles ordering via depends_on + healthchecks.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Starting OpenFn Lightning ==="

cd "${BUNDLE_DIR}"

if [ ! -f .env ]; then
  echo "FAIL: .env not found. Run 02-generate-secrets.sh first."
  exit 1
fi

if [ ! -f docker-compose.yml ]; then
  echo "FAIL: docker-compose.yml not found in ${BUNDLE_DIR}"
  exit 1
fi

# Bring up all services using docker compose
echo "Starting services (this may take 1-2 minutes on first run)..."
docker compose up -d

echo ""
echo "Waiting for web to become healthy..."
TRIES=0
MAX_TRIES=60
while [ $TRIES -lt $MAX_TRIES ]; do
  HEALTH="$(docker compose ps web --format '{{.Health}}' 2>/dev/null || true)"
  if [ "${HEALTH}" = "healthy" ]; then
    echo ""
    echo "==========================="
    echo " Lightning is running"
    echo "==========================="
    echo ""
    docker compose ps
    echo ""
    echo "Next: run 04-create-admin.sh to create the first admin user."
    exit 0
  fi
  TRIES=$((TRIES + 1))
  printf "."
  sleep 5
done

echo ""
echo "WARNING: web did not become healthy within 5 minutes."
echo "Check logs:"
echo "  docker compose logs web"
echo "  docker compose logs migrate"
echo "  docker compose logs postgres"
exit 1
