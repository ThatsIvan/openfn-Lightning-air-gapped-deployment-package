# OpenFn Lightning — Air-Gapped Deployment Package

An air-gapped deployment package for [OpenFn Lightning](https://github.com/OpenFn/lightning)
targeting a Ministry of Health running a single, permanently offline Ubuntu 22.04 server.
The package bundles all Docker images, pre-staged adaptors, and numbered scripts so a
non-developer Linux admin can deploy Lightning e2e from a USB drive with no internet
access. Secrets are generated on the target server at install time (not in the repo or
bundle). A canary workflow validates offline adaptor execution as the definitive acceptance
test.

## Repo map

```
.
.
├── RUNBOOK.md              # ministry admin
├── DECISIONS.md            # trade offs and thought process
├── README.md               
├── bundle/
│   ├── build-bundle.sh     # runs on jump host
│   ├── compose/
│   │   └── docker-compose.yml
│   ├── env/
│   │   └── .env.template       # documented. no screts
│   ├── server-scripts/         # index scripts for the admin
│   │   ├── 00-verify-bundle.sh
│   │   ├── 01-load-images.sh
│   │   ├── 02-generate-secrets.sh
│   │   ├── 03-start.sh
│   │   ├── 04-create-admin.sh
│   │   ├── 05-verify.sh
│   │   ├── status.sh
│   │   ├── healthcheck.sh
│   │   └── backup-db.sh
│   └── systemd/
│       ├── openfn-healthcheck.service
│       └── openfn-healthcheck.timer
└── dist/                   # Build output (this is gitignored)
```

## Pinned versions

| Component | Version | Digest |
|-----------|---------|--------|
| Lightning | v2.16.7 | sha256:5a1daafa5c02… |
| ws-worker | v1.26.1 | sha256:36261d8a0e66… |
| Postgres  | 15.12-alpine | sha256:ef9d1517df69… |
| @openfn/language-common | 3.3.3 | |
| @openfn/language-http | 7.3.1 | |
| @openfn/language-dhis2 | 8.1.1 | |
| @openfn/cli | 1.38.1 | |

## How to verify this work

### 1. Build the bundle (internet-connected machine)

```bash
# Requires: Docker Engine + Compose v2
bash bundle/build-bundle.sh
```

This pulls images, pre-stages adaptors, and produces
`dist/openfn-airgap-v2.16.7.tar.gz` + prints its SHA 256

### 2. Simulate air gapped install

```bash
# Remove docker chached images
docker rmi openfn/lightning:v2.16.7 openfn/ws-worker:v1.26.1 postgres:15.12-alpine 2>/dev/null

# Extract bundle to a temp directory
mkdir -p /tmp/openfn-test
tar xzf dist/openfn-airgap-v2.16.7.tar.gz -C /tmp/openfn-test
cd /tmp/openfn-test

# Run the admin workflow
bash server-scripts/00-verify-bundle.sh    # PASS: files intact
bash server-scripts/01-load-images.sh      # PASS: images loaded
bash server-scripts/02-generate-secrets.sh # Secrets generated
bash server-scripts/03-start.sh            # Lightning is running
bash server-scripts/04-create-admin.sh     # Create admin user
bash server-scripts/05-verify.sh           # PASS: canary runs offline
```

### 3. Prove air-gap correctness

The compose sets `pull_policy: never` on every service — a missing image fails
instead of pulling. The worker is on an `internal: true` Docker network with no
egress. A `.npmrc` poison pill in the adaptors repo dir ensures any
un-pre-staged adaptor install fails fast (3s ECONNREFUSED) instead of hanging.

For maximum confidence: bring it up with the host's internet blocked:
```bash
# block dockerhub (optional — pull_policy: never already covers this)
sudo iptables -A OUTPUT -d registry-1.docker.io -j REJECT
# Run 05-verify.sh — canary must still pass
bash server-scripts/05-verify.sh
```

## Elapsed time

| Session | Date | Duration(approximately) | What was done                                                                                                                                                                                                                                                                                            |
|---------|------|-------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1 | June 23 06:15 – 07:00 | ~45 min                 | Read task brief, studied Lightning repo (DEPLOYMENT.md, WORKERS.md, docker-compose.yml, Dockerfile). Mapped out recon items, chose docker save/load approach, drafted implementation roadmap.                                                                                                            |
| 2 | June 24 22:10 – 23:40 | ~1.5 hr                 | Built all deliverables: docker compose.yml, build-bundle.sh, server-scripts, .env.template, systemd units, RUNBOOK.md, DECISIONS.md, README.md. Debugged ARM/amd64 pulls, macOS base64/sha256sum portability, migrate env var requirements, registry cache format (Jason atoms! issue), origin check issue |
| 3 | June 25 04:15 – 06:00 | ~1.75 hr                | E2E testing of full install flow. Fixed migrate connection pool retry, adaptor registry crash loop, WebSocket origin config. Verified network topology (LAN reachable + worker zero-egress). Final cleanup and notes                                                                                     |
| | **Total** | **~4 hr**               |                                                                                                                                                                                                                                                                                                          |
