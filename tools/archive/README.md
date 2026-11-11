# Archived ops scripts

**Historical reference only — NOT a supported rollback path.** Production
runs a single `bitcraft-mirror.service` against the BitCraft 1.0 release
upstream (`bitcraft-release.spacetimedb.com`); there is no going back to
the blue fleet or to the Early Access upstream, which no longer exists.
Nothing here is maintained or expected to work against the current host.

Retired systemd units, nginx snippets, and cutover scripts from pre-green
topologies (14× `relay-bc*` fleet, blue `public-mirror@*` fleet, standalone
`relay-cache`, trial mirror, EA2-era rollback tooling). **Do not use for
deploys.**

Current production scripts live in [`../`](../) (parent `tools/`). Deploy:
[`../../DEPLOY.md`](../../DEPLOY.md).

| Group | Files | Retired |
|-------|-------|---------|
| Blue public-mirror fleet | `public-mirror@.service`, `public-mirror.target`, `public-mirror.service`, `public-mirror.instances`, `public-mirror-start.sh`, `public-mirror-stop-all.sh`, `relay-pin-public-mirror.service`, `nginx-public-mirror-frontends.snippet` | 2026-08-17 decommission |
| Standalone cache (blue) | `relay-cache.service` | 2026-08-17 (cache embedded in `bitcraft-mirror`) |
| Green cutover (one-time) | `switch-to-bitcraft-mirror.sh`, `cutover-to-bitcraft-mirror.sh`, `cutover-telemetry-capture.sh`, `decommission-public-mirror-fleet.sh`, `nginx-flip-bitcraft-mirror.sh` | Cutover completed 2026-08-17 |
| Partial / trial migrations | `cutover-regions-to-public-mirror.sh`, `rollback-regions-from-public-mirror.sh`, `public-mirror-trial-*`, `nginx-public-mirror-trial-frontends.snippet` | Superseded by green; trial service removed |
| Legacy relay fleet | `relay-fleet-start.sh`, `nginx-relay-frontends.snippet`, `fleet-status.sh` | Pre-public-mirror era |
| EA2-era blue rollback | `rollback-from-bitcraft-mirror.sh`, `relay-staleness-monitor.sh` (targets retired blue `relay-*` units) | Retired; blue fleet and EA upstream are gone |
| EA2 unit file | `bitcraft-mirror.service.ea2` — the last unit pointing at the Early Access upstream (`bitcraft-live-*`) | EA upstream retired 2026-11 (1.0 release cutover); kept as a record only |
