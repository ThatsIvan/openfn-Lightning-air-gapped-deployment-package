#!/usr/bin/env bash
# build-bundle.sh — Runs on an internet connected jump host.
set -euo pipefail


# Version pins (single source of truth)
VERSION="v2.16.7"
WS_WORKER_VERSION="v1.26.1"
POSTGRES_VERSION="15.12-alpine"

LIGHTNING_IMAGE="openfn/lightning:${VERSION}"
WORKER_IMAGE="openfn/ws-worker:${WS_WORKER_VERSION}"
POSTGRES_IMAGE="postgres:${POSTGRES_VERSION}"

# Pinned adaptor versions (no @latest — reproducible offline set)
OPENFN_CLI_VERSION="1.38.1"
ADAPTOR_COMMON_VERSION="3.3.3"
ADAPTOR_HTTP_VERSION="7.3.1"
ADAPTOR_DHIS2_VERSION="8.1.1"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$(mktemp -d)"
DIST_DIR="${SCRIPT_DIR}/../dist"

# Detect host arch — OpenFn images are amd64-only; pull with explicit platform
# on Apple Silicon / other ARM hosts so docker doesn't refuse the manifest
HOST_ARCH="$(uname -m)"
PLATFORM_FLAG=""
if [ "${HOST_ARCH}" != "x86_64" ]; then
  PLATFORM_FLAG="--platform linux/amd64"
  echo "NOTE: Host is ${HOST_ARCH}; pulling amd64 images via --platform flag."
  echo "      The target server is assumed to be x86_64."
  echo ""
fi

echo "=== OpenFn air-gapped bundle builder ==="
echo "Lightning : ${VERSION}"
echo "ws-worker : ${WS_WORKER_VERSION}"
echo "Postgres  : ${POSTGRES_VERSION}"
echo "Build dir : ${BUILD_DIR}"
echo ""

cleanup() { rm -rf "${BUILD_DIR}"; }
trap cleanup EXIT


# 1. Pull images (by tag; record digests)
echo "--- Pulling images ---"
# Capture digest from pull output (docker inspect RepoDigests can be empty
# when pulling cross-platform on ARM hosts)
extract_digest() {
  grep -o 'sha256:[a-f0-9]\{64\}' | head -1
}

LIGHTNING_DIGEST="$(docker pull ${PLATFORM_FLAG} "${LIGHTNING_IMAGE}" 2>&1 | extract_digest)"
WORKER_DIGEST="$(docker pull ${PLATFORM_FLAG} "${WORKER_IMAGE}" 2>&1 | extract_digest)"
POSTGRES_DIGEST="$(docker pull ${PLATFORM_FLAG} "${POSTGRES_IMAGE}" 2>&1 | extract_digest)"

echo "Lightning digest : ${LIGHTNING_DIGEST}"
echo "Worker digest    : ${WORKER_DIGEST}"
echo "Postgres digest  : ${POSTGRES_DIGEST}"
echo ""


# 2. Pre-stage adaptors using @openfn/cli (proper repo-dir layout)
echo "--- Pre-staging adaptors ---"
ADAPTORS_DIR="${BUILD_DIR}/adaptors"
mkdir -p "${ADAPTORS_DIR}"

# Install adaptors with npm aliases matching the ws-worker's expected layout.
# The worker resolves e.g. @openfn/language-common@3.3.3 to the directory
# node_modules/@openfn/language-common_3.3.3 (underscore + version suffix).
docker run --rm ${PLATFORM_FLAG} \
  -v "${ADAPTORS_DIR}:/repo" \
  --entrypoint sh \
  "${WORKER_IMAGE}" \
  -c "
    cd /repo && \
    npm install --save \
      '@openfn/language-common_${ADAPTOR_COMMON_VERSION}@npm:@openfn/language-common@${ADAPTOR_COMMON_VERSION}' \
      '@openfn/language-http_${ADAPTOR_HTTP_VERSION}@npm:@openfn/language-http@${ADAPTOR_HTTP_VERSION}' \
      '@openfn/language-dhis2_${ADAPTOR_DHIS2_VERSION}@npm:@openfn/language-dhis2@${ADAPTOR_DHIS2_VERSION}' \
      2>&1
  "

echo "Adaptors installed. Repo dir contents:"
ls -la "${ADAPTORS_DIR}/node_modules/@openfn/" 2>/dev/null || echo "(no node_modules yet)"

# Drop .npmrc pitfall, if autoinstall fires for an un-staged adaptor,
# npm hits a dead socket and fails in ~3s instead of hanging
cat > "${ADAPTORS_DIR}/.npmrc" << 'NPMRC'
registry=http://localhost:1/
fetch-timeout=3000
fetch-retries=0
NPMRC
echo "Dropped .npmrc poison pill in repo dir."


# 3. Generate adaptor registry cache
echo "--- Generating adaptor registry cache ---"
# Lightning deserialises this with Jason.decode!(json, keys: :atoms!) so only
# keys that already exist as atoms in the beam are allowed
if docker run --rm ${PLATFORM_FLAG} "${LIGHTNING_IMAGE}" cat /app/lib/lightning-*/priv/adaptor_registry_cache.json \
     > "${BUILD_DIR}/adaptor_registry_cache.json" 2>/dev/null && \
   [ -s "${BUILD_DIR}/adaptor_registry_cache.json" ]; then
  echo "Extracted registry cache from Lightning image."
else
  echo "Registry cache not found in image; generating from pre-staged adaptors..."
  cat > "${BUILD_DIR}/adaptor_registry_cache.json" << 'REGEOF'
[
  {"name":"@openfn/language-common","repo":"https://github.com/OpenFn/adaptors","latest":"ADAPTOR_COMMON_VERSION","versions":[{"version":"ADAPTOR_COMMON_VERSION"}]},
  {"name":"@openfn/language-http","repo":"https://github.com/OpenFn/adaptors","latest":"ADAPTOR_HTTP_VERSION","versions":[{"version":"ADAPTOR_HTTP_VERSION"}]},
  {"name":"@openfn/language-dhis2","repo":"https://github.com/OpenFn/adaptors","latest":"ADAPTOR_DHIS2_VERSION","versions":[{"version":"ADAPTOR_DHIS2_VERSION"}]}
]
REGEOF
  # Substitute actual versions
  sed -i.bak \
    -e "s/ADAPTOR_COMMON_VERSION/${ADAPTOR_COMMON_VERSION}/g" \
    -e "s/ADAPTOR_HTTP_VERSION/${ADAPTOR_HTTP_VERSION}/g" \
    -e "s/ADAPTOR_DHIS2_VERSION/${ADAPTOR_DHIS2_VERSION}/g" \
    "${BUILD_DIR}/adaptor_registry_cache.json"
  rm -f "${BUILD_DIR}/adaptor_registry_cache.json.bak"
  echo "Generated registry cache with pre-staged adaptor versions."
fi


# 4. Save images
echo "--- Saving images to images.tar ---"
docker save \
  "${LIGHTNING_IMAGE}" \
  "${WORKER_IMAGE}" \
  "${POSTGRES_IMAGE}" \
  -o "${BUILD_DIR}/images.tar"

IMAGE_SIZE="$(du -h "${BUILD_DIR}/images.tar" | cut -f1)"
echo "images.tar: ${IMAGE_SIZE}"


# 5. Stage bundle contents
echo "--- Staging bundle ---"

# Compose + env
cp "${SCRIPT_DIR}/compose/docker-compose.yml" "${BUILD_DIR}/docker-compose.yml"
cp "${SCRIPT_DIR}/env/.env.template"          "${BUILD_DIR}/.env.template"

# Server scripts
cp -r "${SCRIPT_DIR}/server-scripts" "${BUILD_DIR}/server-scripts"
chmod +x "${BUILD_DIR}"/server-scripts/*.sh

# Systemd units
cp -r "${SCRIPT_DIR}/systemd" "${BUILD_DIR}/systemd"

# Runbook
cp "${SCRIPT_DIR}/../RUNBOOK.md" "${BUILD_DIR}/RUNBOOK.md"


# 6. Write manifest
cat > "${BUILD_DIR}/manifest.txt" << EOF
# OpenFn air-gapped bundle manifest
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')

[images]
lightning = ${LIGHTNING_IMAGE} @ ${LIGHTNING_DIGEST}
worker    = ${WORKER_IMAGE} @ ${WORKER_DIGEST}
postgres  = ${POSTGRES_IMAGE} @ ${POSTGRES_DIGEST}

[adaptors]
@openfn/cli            = ${OPENFN_CLI_VERSION}
@openfn/language-common = ${ADAPTOR_COMMON_VERSION}
@openfn/language-http   = ${ADAPTOR_HTTP_VERSION}
@openfn/language-dhis2  = ${ADAPTOR_DHIS2_VERSION}

[sizes]
images.tar = ${IMAGE_SIZE}
EOF

echo "Manifest written."


# 7. Generate sha256sum
echo "--- Computing checksums ---"
cd "${BUILD_DIR}"
# Use sha256sum on Linux, shasum -a 256 on macOS
if command -v sha256sum >/dev/null 2>&1; then
  SHA256CMD="sha256sum"
else
  SHA256CMD="shasum -a 256"
fi
find . -type f ! -name 'SHA256SUMS' | sort | xargs ${SHA256CMD} > SHA256SUMS
echo "SHA256SUMS generated ($(wc -l < SHA256SUMS) entries)."


# 8. Create tarball
echo "--- Creating tarball ---"
mkdir -p "${DIST_DIR}"
TARBALL="${DIST_DIR}/openfn-airgap-${VERSION}.tar.gz"
tar czf "${TARBALL}" -C "${BUILD_DIR}" .

TARBALL_SIZE="$(du -h "${TARBALL}" | cut -f1)"
TARBALL_SHA="$(${SHA256CMD} "${TARBALL}" | cut -d' ' -f1)"

echo ""
echo "============================================="
echo " Bundle ready"
echo "============================================="
echo " Path   : ${TARBALL}"
echo " Size   : ${TARBALL_SIZE}"
echo " SHA-256: ${TARBALL_SHA}"
echo "============================================="
echo ""
echo "Transfer this tarball + the SHA-256 above to the air-gapped server."
echo "The admin verifies the hash before extracting. See RUNBOOK.md."
