# AGENTS.md

Canonical agent guide (`CLAUDE.md` is a symlink to this file).

Guidance for coding agents working in **bitcraft-relay**. Read this before
touching the repo.

## What this repo is

**BitCraft ops layer only** — no Rust since 2026-08:

| Path | Purpose |
|------|---------|
| `www/` | Fleet dashboard, explorer SPA, tutorial site |
| `tools/` | **Active** systemd units, nginx snippets, deploy/verify scripts |
| `tools/archive/` | Retired relay-fleet / blue / EA2-era scripts — historical only, **not** a rollback path |
| `BITCRAFT.md`, `PORTS.md` | Upstream architecture + port scheme |

Rust lives in sibling **`../spacetimedb-bitcraft-mirror/`**, branch
`bitcraft-mirror-v2` (the GitHub default; mirror, embedded `relay-cache`,
`mirror-health`, `relay-protocol`, `relay-test-harness`).

## Active `tools/` (production)

| Script / unit | Role |
|---------------|------|
| `bitcraft-mirror.service` | The one production process: mirrors `idc-global` + `idc-{7,8,9,12,13,14,17,18,19}` from `bitcraft-release.spacetimedb.com`, embedded cache |
| `bitcraft-mirror-ram-guard.*` | RAM gate for `bitcraft-mirror.service` |
| `relay-pin-bitcraft-mirror.service`, `relay-pin-pages.sh` | vmtouch page pins |
| `nginx-relay-cache.snippet` | Cache + `/roads/*` proxy |
| `check-integrity.sh` | Post-deploy WS/schema gate |
| `wait-mirrors-live.sh`, `wait-cache-ready.sh` | Readiness polling |
| `mirror-health.service` | Fleet `/health` sidecar (polls status `:3130`) |
| `relay-roadsgen.service`, `relay-roadsgen.timer` | Every 10 min: `roadsgen` (calculator repo binary at `/srv/relay/bin/roadsgen`) condenses the roads cache into `www/maps/region-N-roads/` for the map viewer's Roads layer |

nginx site configs for the production host are kept privately, not in
this repo.

Deploy from workspace root: [`../DEPLOY.md`](../DEPLOY.md),
[`../tools/deploy.sh`](../tools/deploy.sh).

## Building relay-cache

```sh
cd ../spacetimedb-bitcraft-mirror
cargo build -p relay-cache --release   # standalone binary (dev only)
cargo build -p spacetimedb-standalone --release   # production
```

All relay Rust crates live in the same workspace (`relay-cache`, `mirror-health`,
`relay-protocol`, `relay-test-harness`).

## Archived scripts

Pre-green fleet / blue public-mirror / EA2-era cutover tooling is in
[`tools/archive/`](tools/archive/) — historical reference only. There is
no supported rollback to the blue fleet or the Early Access upstream (it
no longer exists). See [`tools/archive/README.md`](tools/archive/README.md).

## Operator-only (gitignored)

SSH host / user facts and deploy cautions: **`AGENTS.local.md`**
(`CLAUDE.local.md` is a symlink to it). Never commit the upstream
developer JWT / `.developer-token`.

## Security

- Never push to production without explicit authorization per change.
- Never log production identity tokens (`BITCRAFT.md`).
