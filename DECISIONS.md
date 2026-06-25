# Decisions & Trade-offs

## Assumptions

- **Target OS:** Ubuntu 22.04, 8 GB RAM, 4 vCPU, 50 GB SSD
- **Docker Engine + Compose v2** present (`docker compose`, not `docker-compose`)
- **HTTP on LAN, no TLS termination** in scope: the server sits on an internal
  ministry LAN with no internet. TLS would require certificate management on an
  offline box (self signed + trust distribution or internal CA), complexity not
  justified for a single site LAN deployment. Stated as a future enhancement 
- **DHIS2 is the primary target system** — a Ministry of Health typically uses OpenFn
  to integrate facility/health data with DHIS2, which is why DHIS2 is the adaptor 
  I'm assuming is needed and pre stage. standard for health-information systems.
  Inn addition, other Pre-staged adaptors include `language-dhis2`, `language-http`, 
  and `language-common`.
- **One server, one operator, infrequent updates** - Assuming number of sites tp deploy, N=1
  entire design assumes we're deploying to one single server at one Ministry of Health. 
  Every decision (docker save/load, openssl secrets on-box, manual USB transfer, systemd timer 
  instead of Prometheus) is justified given this assumption

---

## 1. Image handling: `docker save`/`load` over a registry

**Decision:** Ship images as a single `images.tar` archive via `docker save`,
loaded on the target with `docker load`. Pin all images by tag and record
digests in `manifest.txt` for easy verification. Every compose service sets
`pull_policy: never` to avoid any image lookup over the internet.

**Why, for N=1:**
- `docker save`/`load` is Docker's native air-gap primitive. Zero configuration
  on the target: the admin runs one command and images are available.
- A registry (Harbor, `distribution`, Zot) is itself a service to run, store,
  secure (TLS), debug, and back up. For one server that receives updates
  a few times a year, that's pure overhead.
- Saving all three images in one archive lets Docker deduplicate shared layers
  within the tarball.

**Trade-off we accept:**
- `docker save` encodes layers per-image; no cross version layer dedup. A
  patch upgrade (v2.16. to v2.16.8) re transfers the full Lightning image
  (~1.2 GB) even if only one layer changed. For a single site with USB/scp
  transfer, this is acceptable.
- Manual steps: the admin must extract, load, bump the version in `.env`, and
  restart. No "pull new tag" shortcut.

**Pivot to a registry at ~20 sites or frequent updates:**
- Seed a private registry (Harbor or plain `distribution/registry`) on the jump
  host. Transfer new layers via `skopeo sync` / `regctl` / `oras` to a portable
  drive.
- On each site, run a local registry. `docker compose pull` works natively once
  compose points at the internal registry.
- Gains: incremental layer sync, `docker pull` workflow, simpler update script.
- Cost: registry operation, TLS for registry (even self-signed), storage(images and harbor metadata), 
  a separate postgres instance(in case we choose harbor), and a registry seeding workflow

---

## 2. Secrets management

**Decision:** Secrets generated on the target server at install time via
`openssl`. Written to `.env` with `chmod 600`. Never in the repo, never in the
bundle, never on the jump host.

**Why:**
- **Sovereignty:** the ministry's keys never traverse a network or exist on a
  machine they don't control.
- **Per site uniqueness:** each deployment gets its own keys and credentials.
  A compromise of one site cannot decrypt another.
- **Simplicity:** `openssl` is universally available on Ubuntu. The admin runs
  one script. No Elixir or mix required on the target.

**Rotation costs per secret:**

| Secret | Rotation impact                                                                                                                                                                             | Procedure                                   |
|--------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------|
| `POSTGRES_PASSWORD` | Update `DATABASE_URL` requires an ALTER USER statement not a `.env`, and postgres services                                                                                                  | Low risk — brief downtime                   |
| `SECRET_KEY_BASE` | Invalidates all active Phoenix sessions everyone logged out                                                                                                                                 | Low risk: users reauthenticate              |
| `WORKER_SECRET` | Worker can't authenticate until both web + worker have the new value                                                                                                                        | Coordinate: update `.env`, restart both     |
| `WORKER_RUNS_PRIVATE_KEY` + `WORKER_LIGHTNING_PUBLIC_KEY` | Regenerate keypair, update both vars, restart both services                                                                                                                                 | Same as above                               |
| **`PRIMARY_ENCRYPTION_KEY`** | **DO NOT casually rotate.** All stored credentials (DHIS2 passwords, OAuth tokens) are encrypted with this key. Rotation requires re-encrypting every credential. **Loss = unrecoverable.** | Back up `.env` to a secure offline location |

**At 20 deployments:** Central per-site secret generation with secrets encrypted
at rest in git using **SOPS + age** (simple, no key server dependency) or
**Ansible Vault** (if Ansible is adopted for deployment). Each site gets a unique
keyset; the encrypted vault is the audit trail. Avoid a live network secret
store (Vault, AWS Secrets Manager) since sites have no egress.

---

## 3. Updates: v2.16.7 to v2.20 in 6 months

**General offline update loop:**
1. On the jump host: rebuild the bundle with the new version
   (`VERSION=v2.17.0` in `build-bundle.sh`), which pulls the new image and
   re-stages adaptors.
2. Transfer the new tarball to the server.
3. Verify integrity (`00-verify-bundle.sh`).
4. `docker load` the new images (old images remain cached).
5. Update `VERSION` in `.env`.
6. `docker compose up -d` — Compose recreates containers with the new image.
   The `migrate` service runs any new Ecto migrations.
7. Run `05-verify.sh` to confirm the canary still passes.

**Patch upgrade (v2.16.7 to v2.16.8):**
- Usually no breaking migrations or new env vars.
- Low risk. Rollback: revert `VERSION` in `.env`, restart. The old image is
  still loaded from the previous `docker load`.

**Minor upgrade (v2.16 to v2.17):**
- **`pg_dump` first** — always. Schema migrations are not trivially reversible.
- Read the CHANGELOG for new/renamed env vars and breaking changes.
- Rollback may require a database **restore** from the pre-upgrade dump if
  migrations altered the schema.

**Jumping to v2.20 (multiple minors):**
- All intervening Ecto migrations run in sequence (Ecto handles ordering).
  Generally safe, but:
  - Read each minor's release notes for squashed migrations or required
    intermediate versions.
  - A missing newly-required env var causes a crash on boot — the CHANGELOG
    flags these.

**Air-gap-specific risks:**
- **New env var crash:** Lightning adds a required env var in v2.18. The admin
  upgrades to v2.20 without reading the notes → boot crash. Mitigation: the
  update workflow includes "read CHANGELOG, diff `.env.template`."
- **Lightning/worker version skew:** A new Lightning may require a newer
  ws-worker. Always pin a compatible worker version and update both together.
- **Disk budget during transition:** Both old and new images exist on disk
  simultaneously. On a 50 GB SSD, budget ~3-4 GB for two sets of images. Prune
  old images after confirming the upgrade: `docker image prune`.
- **Adaptor compatibility:** A new Lightning version may expect newer adaptor
  versions. Re-run adaptor staging in the build script with updated versions.

---

## 4. Observability: no egress, no off-site metrics

**Prevention (built into the compose):**
- **T5:** Log rotation per service (`max-size: 10m, max-file: 3`) — logs cannot
  fill the 50 GB disk.
- **T6:** `restart: unless-stopped` — services recover from crashes and reboots.
- **T7:** Healthchecks + `depends_on` conditions — startup ordering is
  deterministic.
- **T10:** Memory limits per service — no single service can OOM the box.

**Local self-check (`healthcheck.sh` on a systemd timer):**

Runs every 5 minutes. Checks:
- All three containers running + web healthy
- `/health_check` returns 200
- `pg_isready` confirms Postgres is accepting connections
- **Disk usage < 85%** — the #1 silent killer on a 50 GB air-gapped box with
  no alerting
- Worker not crash-looping

Writes:
- `STATUS` file (human-readable, one-line summary) — the admin checks this
- `healthcheck.log` (append-only) — audit trail of health over time

**How the admin finds out before they call:**
- The systemd timer + STATUS file. The RUNBOOK trains them to check STATUS.
- If an internal SMTP relay exists: the healthcheck can email on failure (not
  implemented in baseline — noted as enhancement).
- Daily `pg_dump` (`backup-db.sh`) doubles as a readability signal: a failing
  backup is itself an alert that something is wrong with Postgres.

**Heavier option (not in baseline):**
Lightning has built-in **PromEx** (`PROMEX_ENABLED=true`) exposing `/metrics`
that a local Prometheus + Grafana stack could scrape with zero egress. Cost:
~0.5–1 GB RAM on an 8 GB box. This is the scale-up path when:
- Multiple sites are deployed and you want consistent dashboards
- The ministry IT team has Prometheus/Grafana experience
- The server has 16+ GB RAM

For the 8 GB baseline with one site, the systemd timer + STATUS file + daily
backup is the right trade-off.

---

## Other design decisions

### Named volume for Postgres, bind mount for adaptors
- **Postgres:** Named Docker volume. Docker manages UID mapping and permissions.
  Avoids the classic "postgres can't write to bind-mounted dir" problem that
  trips up non-developers. Trade-off: slightly harder to inspect the raw files;
  backup uses `pg_dump` (the right way) rather than file copy.
- **Adaptors:** Bind mount (`./adaptors:/worker-repo`). Must be populated from
  the bundle, so a bind mount is pragmatic — `docker load` doesn't populate
  named volumes. Trade-off: the admin must run from the correct directory.
  The RUNBOOK specifies `/opt/openfn` as the standard location.

### Two-network topology (backend + frontend)
- **backend** (`internal: true`): postgres, web, worker. No egress — the worker
  cannot reach npm or any external registry, even if DNS leaks. Combined with
  the `.npmrc` poison pill in the adaptors repo dir, a missing-adaptor npm
  attempt fails in ~3 seconds with `ECONNREFUSED` instead of hanging.
- **frontend** (normal bridge): web only. Publishes the UI/API port to the host
  LAN. Web attaches to both networks so it can reach postgres and the worker
  on the backend.

### Disable DB SSL (`DISABLE_DB_SSL=true`)
Lightning defaults to requiring SSL for Postgres connections in production.
Since Postgres is local (same Docker network, no external exposure), there
are no certs to configure. The connection is already isolated to the internal
Docker bridge. If a network-separated Postgres were used, this decision would
change — noted for future multi-server deployments.

### `MAIL_PROVIDER=local`
Lightning's SMTP+TLS requires TLS 1.3 and hostname matching a cert SAN. An
internal relay with a bare IP or self-signed cert won't work. Default to `local`
(no email delivery) and use the admin bootstrap script to set passwords
directly. Password-reset emails won't send — the RUNBOOK documents this and
the admin can reset passwords via the eval interface.

### Resource budget (8 GB)

| Service | Memory limit | CPU limit | Notes |
|---------|-------------|-----------|-------|
| OS + Docker | ~1 GB | — | Reserved headroom |
| postgres | 1.5 GB | 1.0 | `shared_buffers` ~256 MB default |
| web (BEAM) | 2.5 GB | 1.5 | Elixir/Phoenix — largest consumer |
| worker | 1.5 GB | 1.0 | `WORKER_CAPACITY=2`, 256 MB per run |
| **Total** | **~7 GB** | **3.5** | ~1 GB headroom |

**At 4 GB:** `WORKER_CAPACITY=1`, tighten web to 1.5 GB, postgres to 1 GB,
worker to 768 MB. Add swap (`fallocate -l 2G /swapfile`). Accept lower
throughput and higher OOM risk under concurrent load. All limits are env-tunable
in `.env` — the same bundle serves both hardware profiles.
