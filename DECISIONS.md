# Decisions & Trade-offs

## Assumptions

- **Target OS:** Ubuntu 22.04, 8 GB RAM, 4 vCPU, 50 GB SSD
- **Docker Engine + Compose v2** present (`docker compose`, not `docker-compose`)
- **HTTP on LAN, no TLS termination** in scope: the server sits on an internal
  ministry LAN with no internet. TLS would require certificate management on an
  offline box (self-signed + trust distribution or internal CA), complexity not
  justified for a single site LAN deployment. Stated as a future enhancement 
- **DHIS2 is the primary target system** — standard for health-information systems.
  Pre-staged adaptors include `language-dhis2`, `language-http`, `language-common`.
- **One server, one operator, infrequent updates** — design point for every
  decision below. We flag the pivot points where scale changes the answer.

---

## 1. Image handling: `docker save`/`load` over a registry

**Decision:** Ship images as a single `images.tar` archive via `docker save`,
loaded on the target with `docker load`. Pin all images by tag and record
digests in `manifest.txt` for verification. Every compose service sets
`pull_policy: never`.

**Why, for N=1:**
- `docker save`/`load` is Docker's native air-gap primitive. Zero configuration
  on the target — the admin runs one command and images are available.
- A registry (Harbor, `distribution`, Zot) is itself a service to run, store,
  secure (TLS), debug, and back up. For one server that receives updates
  a few times a year, that's pure overhead.
- Saving all three images in one archive lets Docker deduplicate shared layers
  within the tarball.

