#!/usr/bin/env bash
# 00-verify-bundle.sh: verify bundle integrity after transfer
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "=== Bundle integrity check ==="
echo "Bundle dir: ${BUNDLE_DIR}"
echo ""

cd "${BUNDLE_DIR}"

if [ ! -f SHA256SUMS ]; then
  echo "FAIL: SHA256SUMS not found in ${BUNDLE_DIR}"
  echo "      Are you running this from the extracted bundle directory?"
  exit 1
fi

echo "Verifying checksums..."
if sha256sum -c SHA256SUMS --quiet 2>/dev/null; then
  echo ""
  echo "==========================="
  echo " PASS — all files intact"
  echo "==========================="
else
  echo ""
  echo "==========================="
  echo " FAIL — checksum mismatch"
  echo "==========================="
  echo "One or more files were corrupted during transfer."
  echo "Re-transfer the bundle and try again."
  exit 1
fi
