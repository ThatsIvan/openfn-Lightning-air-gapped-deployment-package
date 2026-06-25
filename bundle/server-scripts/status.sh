#!/usr/bin/env bash
# status.sh — One-command human-readable health overview.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "${BUNDLE_DIR}"

echo "=== OpenFn Lightning status ==="
echo "Time: $(date)"
echo ""

# Container status
echo "--- Containers ---"
docker compose ps --format 'table {{.Service}}\t{{.State}}\t{{.Health}}\t{{.RunningFor}}'
echo ""

# Health endpoint
echo "--- Health check ---"
HTTP_CODE="$(curl -sf -o /dev/null -w '%{http_code}' http://localhost:${LIGHTNING_PORT:-4000}/health_check 2>/dev/null || echo "000")"
echo "  /health_check: HTTP ${HTTP_CODE}"
echo ""

# Disk usage
echo "--- Disk ---"
df -h / | tail -1 | awk '{printf "  Total: %s  Used: %s  Avail: %s  Use%%: %s\n", $2, $3, $4, $5}'
echo "  Docker volumes:"
docker system df --format '  {{.Type}}: {{.Size}} ({{.Reclaimable}} reclaimable)' 2>/dev/null || echo "  (could not query docker)"
echo ""

# Postgres
echo "--- Postgres ---"
docker compose exec -T postgres pg_isready -U "${POSTGRES_USER:-lightning}" -d "${POSTGRES_DB:-lightning}" 2>/dev/null && echo "  pg_isready: OK" || echo "  pg_isready: FAIL"
echo ""

# Recent worker activity
echo "--- Worker (last 10 log lines) ---"
docker compose logs worker --tail=10 --no-log-prefix 2>/dev/null || echo "  (no logs)"
