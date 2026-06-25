# OpenFn Lightning — Air-Gapped Server Runbook

This runbook walks you through installing OpenFn Lightning on your server from
start to finish. Follow each step in order. Every step has a clear PASS/FAIL
check — do not continue past a FAIL.

**You will need:** The bundle tarball file (`openfn-airgap-v2.16.7.tar.gz`) and
its SHA-256 hash (a long string of letters and numbers given to you separately).

---

## Step 0: Prerequisites

Your server must have Docker Engine and Docker Compose v2 installed.

**Check Docker is running:**
```bash
docker info >/dev/null 2>&1 && echo "PASS: Docker is running" || echo "FAIL: Docker is not running"
```
You should see `PASS: Docker is running`.

**Check Compose v2 is present:**
```bash
docker compose version
```
You should see output like `Docker Compose version v2.x.x`. If you see
`command not found`, Docker Compose v2 is not installed.

---

## Step 1: Verify the bundle transferred intact

**1a.** Copy the tarball to your server (via USB or scp).

**1b.** Verify the tarball hash matches what you were given:
```bash
sha256sum openfn-airgap-v2.16.7.tar.gz
```
Compare the output hash to the value provided to you. They must match exactly.
If they do not match, the file was corrupted during transfer — re-transfer it.

**1c.** Extract the bundle:
```bash
mkdir -p /opt/openfn
tar xzf openfn-airgap-v2.16.7.tar.gz -C /opt/openfn
cd /opt/openfn
```

**1d.** Run the integrity check:
```bash
bash server-scripts/00-verify-bundle.sh
```
You must see `PASS — all files intact`. If you see `FAIL`, re-transfer.

---

## Step 2: Load Docker images

```bash
bash server-scripts/01-load-images.sh
```

This loads three container images from the bundle into Docker. It takes a few
minutes. You must see `PASS — all images loaded` at the end.

**What this does:** Imports pre-packaged software containers so Docker can run
them. No internet connection is needed or used.

---

## Step 3: Generate secrets

```bash
bash server-scripts/02-generate-secrets.sh
```

This generates all passwords and encryption keys your server needs. They are
written to a file called `.env` in the current directory.

You must see `Secrets generated` at the end.

**CRITICAL — Read this:**
- The `.env` file contains your `PRIMARY_ENCRYPTION_KEY`. If you lose this key,
  all stored credentials (passwords for connected systems like DHIS2) become
  **permanently unrecoverable**. There is no reset.
- **Back up `.env` now** to a secure offline location (encrypted USB, safe).
- Do not share `.env` or send it over a network.

---

## Step 4: Start Lightning

```bash
bash server-scripts/03-start.sh
```

This starts the database, runs setup tasks, and starts the web interface and
worker. It takes 1–2 minutes on first run.

You must see `Lightning is running` at the end. If you see a timeout warning,
check the logs as suggested.

---

## Step 5: Create the admin user

```bash
bash server-scripts/04-create-admin.sh
```

You will be asked for an email address and password. This creates the first
administrator account with full access.

You must see `Admin user created`.

---

## Step 6: Verify everything works

```bash
bash server-scripts/05-verify.sh
```

This runs a comprehensive check:
1. All containers are running and healthy
2. The web interface responds
3. The worker is connected
4. A test workflow runs end-to-end using a pre-installed adaptor

You must see `PASS — deployment verified`. This is the definitive sign that
the system is working correctly, including offline adaptor execution.

---

## Step 7: Log in

Open a web browser on any computer on the same network and go to:
```
http://<server-ip>:4000
```
Replace `<server-ip>` with your server's IP address. Log in with the email and
password from Step 5.

---

## Ongoing operations

### Check system health
```bash
bash server-scripts/status.sh
```
This shows container status, disk usage, and recent worker activity. Run it
any time you want to check on the system.

### Automatic health checks
To enable automatic monitoring every 5 minutes:
```bash
sudo cp systemd/openfn-healthcheck.service /etc/systemd/system/
sudo cp systemd/openfn-healthcheck.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now openfn-healthcheck.timer
```
This writes a `STATUS` file you can check, and logs results to `healthcheck.log`.

### Back up the database
```bash
bash server-scripts/backup-db.sh
```
Run this regularly (daily recommended). Keeps the last 7 backups automatically.
Transfer backups to an external drive for offsite storage.

### Restart after a reboot
Lightning starts automatically after a reboot (Docker restart policy is set).
If it does not, run:
```bash
cd /opt/openfn && docker compose up -d
```

---

## Troubleshooting: Worker connects but no jobs run

**Symptom:** The web UI shows workflows, you can trigger them, but runs stay in
"available" or fail immediately. The web service is healthy.

### Step A: Check worker logs
```bash
docker compose logs worker --tail=100
```

Look for one of these patterns:

---

**Pattern 1: Auth rejected**

```
Error: authentication failed
```
or
```
token verification failed
```

**Cause:** `WORKER_SECRET` or the RSA keys in `.env` do not match between web and
worker. This happens if `.env` was hand-edited and a key was changed for only
one service.

**Fix:**
```bash
# Regenerate all secrets (this resets everything)
bash server-scripts/02-generate-secrets.sh
docker compose down
docker compose up -d
# Re-verify
bash server-scripts/05-verify.sh
```

---

**Pattern 2: Could not connect**

```
CRITICAL ERROR: could not connect to lightning at ws://web:4000/worker
```

**Cause:** This is the Node.js v17+ DNS resolution issue. The worker resolves
the hostname `web` to an IPv6 address (`::1`) which Docker's internal DNS does
not route correctly.

**Fix:** This is already mitigated in the compose file with
`NODE_OPTIONS=--dns-result-order=ipv4first`. If you still see it:
```bash
# Verify the env var is set
docker compose exec worker env | grep NODE_OPTIONS
# Should show: NODE_OPTIONS=--dns-result-order=ipv4first
```
If it's missing, add it to the worker environment in `docker-compose.yml` and
restart: `docker compose up -d worker`.

---

**Pattern 3: Module not found**

```
Error: Cannot find module '@openfn/language-dhis2'
```
or
```
module not found
```

**Cause:** The workflow references an adaptor that was not pre-installed in the
bundle. On this air-gapped server, adaptors cannot be downloaded from the
internet. Only the following adaptors are pre-installed:
- `@openfn/language-common@3.3.3`
- `@openfn/language-http@7.3.1`
- `@openfn/language-dhis2@8.1.1`

**Fix:** If you need a different adaptor, you must rebuild the bundle on the
internet-connected jump host with the additional adaptor included, then transfer
and re-deploy. Edit `build-bundle.sh` to add the adaptor to the install list.

**Verify the pre-installed adaptors are present:**
```bash
ls adaptors/node_modules/ | grep openfn
```
You should see directories like `@openfn/language-common_3.3.3`.

Also verify the worker can see them:
```bash
docker compose exec worker ls /worker-repo/node_modules/ | grep openfn
```

If the directory is empty, the adaptors volume mount may be incorrect. Check
that `./adaptors` exists relative to `docker-compose.yml` and contains
`package.json` and `node_modules/`.

---

### General recovery steps

If none of the above patterns match:
```bash
# See ALL recent logs
docker compose logs --tail=200

# Restart just the worker
docker compose restart worker

# Full restart
docker compose down && docker compose up -d

# Nuclear option: regenerate secrets and start fresh
# WARNING: this resets all secrets — existing workflows keep their data
# but you'll need to recreate the admin user
bash server-scripts/02-generate-secrets.sh
docker compose down -v  # removes volumes — ALL DATA LOST
docker compose up -d
bash server-scripts/04-create-admin.sh
bash server-scripts/05-verify.sh
```
