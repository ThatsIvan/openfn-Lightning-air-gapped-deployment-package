#!/usr/bin/env bash
# 02-generate-secrets.sh — Generate all secrets only on the air gapped server
# Secrets never leave this box. Run once
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${BUNDLE_DIR}/.env"
TEMPLATE="${BUNDLE_DIR}/.env.template"

echo "=== Generating secrets ==="

if [ -f "${ENV_FILE}" ]; then
  echo "WARNING: .env already exists at ${ENV_FILE}"
  read -rp "Overwrite? This will regenerate ALL secrets. [y/N] " confirm
  if [[ "${confirm}" != [yY] ]]; then
    echo "Aborted. Existing .env left untouched."
    exit 0
  fi
fi

if [ ! -f "${TEMPLATE}" ]; then
  echo "FAIL: .env.template not found at ${TEMPLATE}"
  exit 1
fi

# --- Generate secrets ---
echo "Generating cryptographic material..."

SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
PRIMARY_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
WORKER_SECRET="$(openssl rand -hex 32)"
POSTGRES_PASSWORD="$(openssl rand -hex 24)"

# RSA keypair for worker run tokens
RSA_TMPFILE="$(mktemp)"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${RSA_TMPFILE}" 2>/dev/null

# Portable base64 encode (no newlines): works on both GNU (base64 -w0) and macOS (base64 + tr)
b64_encode() { base64 < "$1" | tr -d '\n'; }

WORKER_RUNS_PRIVATE_KEY="$(b64_encode "${RSA_TMPFILE}")"
WORKER_LIGHTNING_PUBLIC_KEY="$(openssl rsa -in "${RSA_TMPFILE}" -pubout 2>/dev/null | base64 | tr -d '\n')"
rm -f "${RSA_TMPFILE}"

# Compose DATABASE_URL
DATABASE_URL="postgresql://lightning:${POSTGRES_PASSWORD}@postgres:5432/lightning"

# --- Write .env ---
echo "Writing .env..."

# Start from template
cp "${TEMPLATE}" "${ENV_FILE}"

# Inject generated values
sed -i.bak \
  -e "s|^SECRET_KEY_BASE=.*|SECRET_KEY_BASE=${SECRET_KEY_BASE}|" \
  -e "s|^PRIMARY_ENCRYPTION_KEY=.*|PRIMARY_ENCRYPTION_KEY=${PRIMARY_ENCRYPTION_KEY}|" \
  -e "s|^WORKER_SECRET=.*|WORKER_SECRET=${WORKER_SECRET}|" \
  -e "s|^WORKER_RUNS_PRIVATE_KEY=.*|WORKER_RUNS_PRIVATE_KEY=${WORKER_RUNS_PRIVATE_KEY}|" \
  -e "s|^WORKER_LIGHTNING_PUBLIC_KEY=.*|WORKER_LIGHTNING_PUBLIC_KEY=${WORKER_LIGHTNING_PUBLIC_KEY}|" \
  -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${POSTGRES_PASSWORD}|" \
  -e "s|^DATABASE_URL=.*|DATABASE_URL=${DATABASE_URL}|" \
  "${ENV_FILE}"
rm -f "${ENV_FILE}.bak"

# Lock permissions — only root/owner can read
chmod 600 "${ENV_FILE}"

echo ""
echo "==========================="
echo " Secrets generated"
echo "==========================="
echo ""
echo " .env written to: ${ENV_FILE}"
echo " Permissions: $(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}")"
echo ""
echo " CRITICAL: Back up .env to a secure offline location."
echo " Losing PRIMARY_ENCRYPTION_KEY = stored credentials UNRECOVERABLE."
