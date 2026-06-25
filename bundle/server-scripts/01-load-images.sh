#!/usr/bin/env bash
# 01-load-images.sh — Load Docker images from images.tar and verify digests.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Loading Docker images ==="

IMAGES_TAR="${BUNDLE_DIR}/images.tar"
MANIFEST="${BUNDLE_DIR}/manifest.txt"

if [ ! -f "${IMAGES_TAR}" ]; then
  echo "FAIL: images.tar not found at ${IMAGES_TAR}"
  exit 1
fi

echo "Loading images.tar (this may take a few minutes)..."
docker load -i "${IMAGES_TAR}"
echo ""

# Verify loaded images match manifest digests
echo "--- Verifying image digests against manifest ---"
PASS=true

verify_image() {
  local label="$1" tag="$2" expected_digest="$3"
  if [ -z "${expected_digest}" ]; then
    echo "WARN: No digest found in manifest for ${label}, skipping verification."
    return
  fi
  local actual_digest
  actual_digest="$(docker inspect --format='{{index .RepoDigests 0}}' "${tag}" 2>/dev/null | cut -d'@' -f2 || true)"
  if [ "${actual_digest}" = "${expected_digest}" ]; then
    echo "  ${label}: digest OK"
  elif [ -z "${actual_digest}" ]; then
    # docker load from a save archive may not preserve RepoDigests —
    # fall back to verifying the image ID exists.
    if docker image inspect "${tag}" >/dev/null 2>&1; then
      echo "  ${label}: loaded OK (digest not available from docker-load archive)"
    else
      echo "  ${label}: FAIL — image not found after load"
      PASS=false
    fi
  else
    echo "  ${label}: FAIL — digest mismatch"
    echo "    expected: ${expected_digest}"
    echo "    actual:   ${actual_digest}"
    PASS=false
  fi
}

if [ -f "${MANIFEST}" ]; then
  # Parse digests from manifest
  LIGHTNING_DIGEST="$(grep '^lightning' "${MANIFEST}" | grep -o 'sha256:[a-f0-9]*' || true)"
  WORKER_DIGEST="$(grep '^worker' "${MANIFEST}" | grep -o 'sha256:[a-f0-9]*' || true)"
  POSTGRES_DIGEST="$(grep '^postgres' "${MANIFEST}" | grep -o 'sha256:[a-f0-9]*' || true)"

  # Parse image tags from .env.template
  if [ -f "${BUNDLE_DIR}/.env.template" ]; then
    . <(grep -E '^(VERSION|WS_WORKER_VERSION|POSTGRES_VERSION)=' "${BUNDLE_DIR}/.env.template")
  fi
  VERSION="${VERSION:-v2.16.7}"
  WS_WORKER_VERSION="${WS_WORKER_VERSION:-v1.26.1}"
  POSTGRES_VERSION="${POSTGRES_VERSION:-15.12-alpine}"

  verify_image "lightning" "openfn/lightning:${VERSION}" "${LIGHTNING_DIGEST}"
  verify_image "ws-worker" "openfn/ws-worker:${WS_WORKER_VERSION}" "${WORKER_DIGEST}"
  verify_image "postgres"  "postgres:${POSTGRES_VERSION}" "${POSTGRES_DIGEST}"
else
  echo "WARN: manifest.txt not found — skipping digest verification."
  echo "      Images were loaded but could not be verified against expected digests."
fi

echo ""
if [ "${PASS}" = true ]; then
  echo "==========================="
  echo " PASS — all images loaded"
  echo "==========================="
else
  echo "==========================="
  echo " FAIL — see errors above"
  echo "==========================="
  exit 1
fi
