# AGENTS.md

Guidance for coding agents working in **bitcraft-relay**. Read this before
touching the repo.

## What this repo is

**BitCraft ops layer only** — no Rust since 2026-08:

| Path | Purpose |
|------|---------|
| `www/` | Fleet dashboard, explorer SPA, tutorial site |
| `tools/` | **Active** systemd units, nginx snippets, deploy/verify scripts |
| `tools/archive/` | Retired blue/relay-fleet cutover scripts (reference only) |
| `BITCRAFT.md`, `PORTS.md` | Upstream architecture + port scheme |

Rust lives in siblings:

- **`../spacetimedb-bitcraft-mirror/`** — mirror + embedded `relay-cache`
- **`../spacetimedb-relay/`** — `relay-coordinator` + `relay-test-harness`

## Active `tools/` (production)

| Script / unit | Role |
|---------------|------|
| `bitcraft-mirror.service` | Green unit (mirror + embedded cache) |
| `bitcraft-mirror-ram-guard.*` | RAM gate for green |
| `relay-pin-bitcraft-mirror.service`, `relay-pin-pages.sh` | vmtouch page pins |
| `nginx-flip-bitcraft-mirror.sh` | Manual nginx up/down lever |
| `nginx-relay-cache.snippet` | Cache + `/roads/*` proxy |
| `check-integrity.sh` | Post-deploy WS/schema gate |
| `wait-mirrors-live.sh`, `wait-cache-ready.sh` | Readiness polling |
| `rollback-from-bitcraft-mirror.sh` | Emergency revert to blue (rare) |
| `relay-staleness-monitor.sh` | Ops monitoring |
| `relay-coordinator.sudoers` | Coordinator permissions |

Deploy from workspace root: [`../DEPLOY.md`](../DEPLOY.md),
[`../tools/deploy.sh`](../tools/deploy.sh).

## Building relay-cache

```sh
cd ../spacetimedb-bitcraft-mirror
cargo build -p relay-cache --release   # standalone binary (rollback/dev)
cargo build -p spacetimedb-standalone --release   # production
```

Requires sibling `../spacetimedb-relay` for path deps.

## Archived scripts

Pre-green fleet / blue public-mirror / cutover tooling is in
[`tools/archive/`](tools/archive/). See [`tools/archive/README.md`](tools/archive/README.md).
Historical runbooks: [`../DEPLOY-ARCHIVE.md`](../DEPLOY-ARCHIVE.md).

## Operator-only (gitignored)

SSH host, tokens, live status skill: **`AGENTS.local.md`** /
**`CLAUDE.local.md`**. Never commit upstream JWT / `.developer-token`.

## Security

- Never push to production without explicit authorization per change.
- Never log production identity tokens (`BITCRAFT.md`).
