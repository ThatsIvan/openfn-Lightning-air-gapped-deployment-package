#!/usr/bin/env bash
# 02-generate-secrets.sh — Generate secrets on the air-gapped server.
#
# SAFE TO RE-RUN: only fills in missing/empty values. Already-set secrets are
# never overwritten. POSTGRES_PASSWORD and PRIMARY_ENCRYPTION_KEY are DB-bound
# and get extra protection (see --reset-all).
#
# Flags:
#   (no args)              Fill in any missing secrets; leave existing ones alone.
#   --rotate-worker-keys   Regenerate ONLY the worker auth trio. DB-bound secrets
#                          are untouched. Restart web + worker afterward.
#   --reset-all            Regenerate EVERYTHING. Refuses if the postgres_data
#                          volume exists (data loss guard).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

ENV_FILE="${BUNDLE_DIR}/.env"
TEMPLATE="${BUNDLE_DIR}/.env.template"

MODE="fill-missing"   # default
for arg in "$@"; do
  case "${arg}" in
    --rotate-worker-keys) MODE="rotate-worker" ;;
    --reset-all)          MODE="reset-all" ;;
    -h|--help)
      echo "Usage: $0 [--rotate-worker-keys | --reset-all]"
      echo ""
      echo "  (no args)            Fill missing secrets only (safe to re-run)."
      echo "  --rotate-worker-keys Regenerate worker auth keys only."
      echo "  --reset-all          Regenerate everything (requires no DB volume)."
      exit 0 ;;
    *) echo "Unknown flag: ${arg}. Use --help."; exit 1 ;;
  esac
done

# --- Helpers ---

# Read an existing value from .env (empty string if unset or missing)
env_get() {
  if [ -f "${ENV_FILE}" ]; then
    grep -E "^${1}=" "${ENV_FILE}" 2>/dev/null | head -1 | cut -d= -f2-
  fi
}

# Set a key=value in .env (in-place). Works whether or not the key exists.
env_set() {
  local key="$1" val="$2"
  if grep -qE "^${key}=" "${ENV_FILE}" 2>/dev/null; then
    sed -i.bak "s|^${key}=.*|${key}=${val}|" "${ENV_FILE}" && rm -f "${ENV_FILE}.bak"
  else
    echo "${key}=${val}" >> "${ENV_FILE}"
  fi
}

# Portable base64 encode (no newlines): works on both GNU and macOS
b64_encode() { base64 < "$1" | tr -d '\n'; }

# Detect the compose project name (directory name, lowercased, non-alphanum → dash)
pg_volume_exists() {
  local project
  project="$(basename "${BUNDLE_DIR}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g')"
  docker volume inspect "${project}_postgres_data" >/dev/null 2>&1
}

generate_worker_keys() {
  echo "  Generating worker auth keys..."
  WORKER_SECRET="$(openssl rand -hex 32)"
  RSA_TMPFILE="$(mktemp)"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${RSA_TMPFILE}" 2>/dev/null
  WORKER_RUNS_PRIVATE_KEY="$(b64_encode "${RSA_TMPFILE}")"
  WORKER_LIGHTNING_PUBLIC_KEY="$(openssl rsa -in "${RSA_TMPFILE}" -pubout 2>/dev/null | base64 | tr -d '\n')"
  rm -f "${RSA_TMPFILE}"

  env_set "WORKER_SECRET" "${WORKER_SECRET}"
  env_set "WORKER_RUNS_PRIVATE_KEY" "${WORKER_RUNS_PRIVATE_KEY}"
  env_set "WORKER_LIGHTNING_PUBLIC_KEY" "${WORKER_LIGHTNING_PUBLIC_KEY}"
}


# ======================================================================
# MODE: --reset-all
# ======================================================================
if [ "${MODE}" = "reset-all" ]; then
  echo "=== RESET ALL secrets ==="
  echo ""

  if pg_volume_exists; then
    echo "REFUSED: postgres_data volume exists — the database has been initialized."
    echo ""
    echo "Regenerating POSTGRES_PASSWORD or PRIMARY_ENCRYPTION_KEY would break the"
    echo "running database and make all stored credentials UNRECOVERABLE."
    echo ""
    echo "If you truly want a clean start (ALL DATA LOST), run:"
    echo "    docker compose down -v"
    echo "    bash $0 --reset-all"
    echo ""
    echo "To fix only worker auth issues, use --rotate-worker-keys instead."
    exit 1
  fi

  if [ ! -f "${TEMPLATE}" ]; then
    echo "FAIL: .env.template not found at ${TEMPLATE}"
    exit 1
  fi

  echo "No postgres_data volume found — safe to generate fresh secrets."
  cp "${TEMPLATE}" "${ENV_FILE}"

  echo "  Generating cryptographic material..."
  SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
  PRIMARY_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  DATABASE_URL="postgresql://lightning:${POSTGRES_PASSWORD}@postgres:5432/lightning"

  env_set "SECRET_KEY_BASE" "${SECRET_KEY_BASE}"
  env_set "PRIMARY_ENCRYPTION_KEY" "${PRIMARY_ENCRYPTION_KEY}"
  env_set "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
  env_set "DATABASE_URL" "${DATABASE_URL}"

  generate_worker_keys

  chmod 600 "${ENV_FILE}"
  echo ""
  echo "==========================="
  echo " All secrets generated"
  echo "==========================="
  echo ""
  echo " .env written to: ${ENV_FILE}"
  echo " Permissions: $(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}")"
  echo ""
  echo " CRITICAL: Back up .env to a secure offline location."
  echo " Losing PRIMARY_ENCRYPTION_KEY = stored credentials UNRECOVERABLE."
  exit 0
fi


# ======================================================================
# MODE: --rotate-worker-keys
# ======================================================================
if [ "${MODE}" = "rotate-worker" ]; then
  echo "=== Rotate worker auth keys ==="
  echo ""

  if [ ! -f "${ENV_FILE}" ]; then
    echo "FAIL: .env does not exist. Run this script with no flags first."
    exit 1
  fi

  # Verify DB-bound secrets are present (sanity check)
  if [ -z "$(env_get PRIMARY_ENCRYPTION_KEY)" ] || [ -z "$(env_get POSTGRES_PASSWORD)" ]; then
    echo "FAIL: .env is missing DB-bound secrets. Run this script with no flags first."
    exit 1
  fi

  generate_worker_keys

  chmod 600 "${ENV_FILE}"
  echo ""
  echo "==========================="
  echo " Worker keys rotated"
  echo "==========================="
  echo ""
  echo " DB-bound secrets (POSTGRES_PASSWORD, PRIMARY_ENCRYPTION_KEY) are UNCHANGED."
  echo ""
  echo " Restart BOTH web and worker to pick up the new keys:"
  echo "     docker compose up -d"
  echo "     bash server-scripts/05-verify.sh"
  exit 0
fi


# ======================================================================
# MODE: fill-missing (default — idempotent)
# ======================================================================
echo "=== Generating secrets (fill missing only) ==="
echo ""

# Start from template if no .env exists yet
if [ ! -f "${ENV_FILE}" ]; then
  if [ ! -f "${TEMPLATE}" ]; then
    echo "FAIL: .env.template not found at ${TEMPLATE}"
    exit 1
  fi
  cp "${TEMPLATE}" "${ENV_FILE}"
  echo "  Created .env from template."
fi

CHANGED=0

# --- DB-bound secrets (generate-once, never overwrite if volume exists) ---
if [ -z "$(env_get POSTGRES_PASSWORD)" ]; then
  POSTGRES_PASSWORD="$(openssl rand -hex 24)"
  env_set "POSTGRES_PASSWORD" "${POSTGRES_PASSWORD}"
  env_set "DATABASE_URL" "postgresql://lightning:${POSTGRES_PASSWORD}@postgres:5432/lightning"
  echo "  Generated POSTGRES_PASSWORD + DATABASE_URL"
  CHANGED=1
else
  echo "  POSTGRES_PASSWORD: already set — skipped"
  # Ensure DATABASE_URL is consistent
  if [ -z "$(env_get DATABASE_URL)" ]; then
    EXISTING_PW="$(env_get POSTGRES_PASSWORD)"
    env_set "DATABASE_URL" "postgresql://lightning:${EXISTING_PW}@postgres:5432/lightning"
    echo "  DATABASE_URL: rebuilt from existing POSTGRES_PASSWORD"
    CHANGED=1
  fi
fi

if [ -z "$(env_get PRIMARY_ENCRYPTION_KEY)" ]; then
  PRIMARY_ENCRYPTION_KEY="$(openssl rand -base64 32 | tr -d '\n')"
  env_set "PRIMARY_ENCRYPTION_KEY" "${PRIMARY_ENCRYPTION_KEY}"
  echo "  Generated PRIMARY_ENCRYPTION_KEY"
  CHANGED=1
else
  echo "  PRIMARY_ENCRYPTION_KEY: already set — skipped"
fi

# --- Session key (safe to rotate, but only fill if missing) ---
if [ -z "$(env_get SECRET_KEY_BASE)" ]; then
  SECRET_KEY_BASE="$(openssl rand -base64 48 | tr -d '\n')"
  env_set "SECRET_KEY_BASE" "${SECRET_KEY_BASE}"
  echo "  Generated SECRET_KEY_BASE"
  CHANGED=1
else
  echo "  SECRET_KEY_BASE: already set — skipped"
fi

# --- Worker auth trio (safe to rotate, but only fill if missing) ---
if [ -z "$(env_get WORKER_SECRET)" ] || \
   [ -z "$(env_get WORKER_RUNS_PRIVATE_KEY)" ] || \
   [ -z "$(env_get WORKER_LIGHTNING_PUBLIC_KEY)" ]; then
  generate_worker_keys
  echo "  Generated worker auth keys"
  CHANGED=1
else
  echo "  Worker auth keys: already set — skipped"
fi

chmod 600 "${ENV_FILE}"

echo ""
if [ "${CHANGED}" -eq 0 ]; then
  echo "==========================="
  echo " No changes — all secrets already present"
  echo "==========================="
else
  echo "==========================="
  echo " Secrets generated"
  echo "==========================="
  echo ""
  echo " .env written to: ${ENV_FILE}"
  echo " Permissions: $(stat -c '%a' "${ENV_FILE}" 2>/dev/null || stat -f '%Lp' "${ENV_FILE}")"
  echo ""
  echo " CRITICAL: Back up .env to a secure offline location."
  echo " Losing PRIMARY_ENCRYPTION_KEY = stored credentials UNRECOVERABLE."
fi
