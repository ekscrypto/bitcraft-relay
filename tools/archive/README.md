# Archived ops scripts

Retired systemd units, nginx snippets, and cutover scripts from pre-green
topologies (14× `relay-bc*` fleet, blue `public-mirror@*` fleet, standalone
`relay-cache`, trial mirror). **Do not use for day-to-day deploys.**

Current production scripts live in [`../`](../) (parent `tools/`). Deploy:
[`../../DEPLOY.md`](../../DEPLOY.md).

| Group | Files | Retired |
|-------|-------|---------|
| Blue public-mirror fleet | `public-mirror@.service`, `public-mirror.target`, `public-mirror.service`, `public-mirror.instances`, `public-mirror-start.sh`, `public-mirror-stop-all.sh`, `relay-pin-public-mirror.service`, `nginx-public-mirror-frontends.snippet` | 2026-08-17 decommission |
| Standalone cache (blue) | `relay-cache.service` | 2026-08-17 (cache embedded in green) |
| Green cutover (one-time) | `switch-to-bitcraft-mirror.sh`, `cutover-to-bitcraft-mirror.sh`, `cutover-telemetry-capture.sh`, `decommission-public-mirror-fleet.sh` | Cutover completed 2026-08-17 |
| Partial / trial migrations | `cutover-regions-to-public-mirror.sh`, `rollback-regions-from-public-mirror.sh`, `public-mirror-trial-*`, `nginx-public-mirror-trial-frontends.snippet` | Superseded by green |
| Legacy relay fleet | `relay-fleet-start.sh`, `nginx-relay-frontends.snippet`, `fleet-status.sh` | Pre-public-mirror era |

Emergency rollback to blue still uses some archived paths — see
`../rollback-from-bitcraft-mirror.sh` and [`../../DEPLOY-ARCHIVE.md`](../../DEPLOY-ARCHIVE.md).
