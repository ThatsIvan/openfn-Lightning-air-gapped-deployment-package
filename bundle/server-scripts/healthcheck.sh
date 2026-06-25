#!/usr/bin/env bash
# healthcheck.sh — Machine-readable health check for systemd timer.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATUS_FILE="${BUNDLE_DIR}/STATUS"
LOG_FILE="${BUNDLE_DIR}/healthcheck.log"

cd "${BUNDLE_DIR}"

TIMESTAMP="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
HEALTHY=true
ISSUES=""

check() {
  local name="$1" cmd="$2"
  if eval "${cmd}" >/dev/null 2>&1; then
    return 0
  else
    HEALTHY=false
    ISSUES="${ISSUES}  - ${name}\n"
    return 1
  fi
}

# Container checks
check "postgres running" "docker compose ps postgres --format '{{.State}}' | grep -q running"
check "web running"      "docker compose ps web --format '{{.State}}' | grep -q running"
check "worker running"   "docker compose ps worker --format '{{.State}}' | grep -q running"
check "web healthy"      "docker compose ps web --format '{{.Health}}' | grep -q healthy"

# Health endpoint
check "health_check 200" "curl -sf http://localhost:${LIGHTNING_PORT:-4000}/health_check"

# Postgres accepting connections
check "pg_isready" "docker compose exec -T postgres pg_isready -U ${POSTGRES_USER:-lightning} -d ${POSTGRES_DB:-lightning}"

# Disk check — warn if >85% full
DISK_PCT="$(df / | tail -1 | awk '{print $5}' | tr -d '%')"
if [ "${DISK_PCT}" -gt 85 ]; then
  HEALTHY=false
  ISSUES="${ISSUES}  - disk ${DISK_PCT}% full (>85% threshold)\n"
fi

# Worker not crash-looping (restarted <3 times in log window)
RESTART_COUNT="$(docker compose ps worker --format '{{.State}}' 2>/dev/null | grep -c restarting || true)"
if [ "${RESTART_COUNT}" -gt 0 ]; then
  HEALTHY=false
  ISSUES="${ISSUES}  - worker is restarting\n"
fi

# Write STATUS file
if [ "${HEALTHY}" = true ]; then
  cat > "${STATUS_FILE}" << EOF
status: HEALTHY
checked: ${TIMESTAMP}
disk: ${DISK_PCT}%
EOF
else
  cat > "${STATUS_FILE}" << EOF
status: UNHEALTHY
checked: ${TIMESTAMP}
disk: ${DISK_PCT}%
issues:
$(echo -e "${ISSUES}")
EOF
fi

# Append to log
echo "[${TIMESTAMP}] $([ "${HEALTHY}" = true ] && echo "HEALTHY" || echo "UNHEALTHY: $(echo -e "${ISSUES}" | tr '\n' ' ')")" >> "${LOG_FILE}"

# Exit code for systemd
[ "${HEALTHY}" = true ]
