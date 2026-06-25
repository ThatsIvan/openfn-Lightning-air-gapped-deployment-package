#!/usr/bin/env bash
# backup-db.sh — pg_dump the Lightning database.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${BUNDLE_DIR}"

# Source .env for credentials
if [ -f .env ]; then
  set -a
  . .env
  set +a
fi

BACKUP_DIR="${BUNDLE_DIR}/backups"
mkdir -p "${BACKUP_DIR}"

TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_FILE="${BACKUP_DIR}/lightning_${TIMESTAMP}.sql.gz"

echo "=== Database backup ==="
echo "Backing up to: ${BACKUP_FILE}"

docker compose exec -T postgres \
  pg_dump -U "${POSTGRES_USER:-lightning}" -d "${POSTGRES_DB:-lightning}" \
  --no-owner --no-privileges \
  | gzip > "${BACKUP_FILE}"

BACKUP_SIZE="$(du -h "${BACKUP_FILE}" | cut -f1)"
echo "Backup complete: ${BACKUP_FILE} (${BACKUP_SIZE})"

# Prune old backups (keep last 7)
echo "Pruning old backups (keeping last 7)..."
ls -t "${BACKUP_DIR}"/lightning_*.sql.gz 2>/dev/null | tail -n +8 | xargs -r rm -v

echo ""
echo "==========================="
echo " Backup OK"
echo "==========================="
