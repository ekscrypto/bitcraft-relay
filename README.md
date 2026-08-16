# bitcraft-relay

BitCraft fleet dashboard and operations tooling for
[spacetimedb-relay](https://github.com/ekscrypto/spacetimedb-relay) and
[spacetimedb-bitcraft-mirror](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror).

This repo was split out of `spacetimedb-relay` so the generic relay can
be deployed against any SpacetimeDB upstream without carrying BitCraft's
tables, queries, deploy topology, or fan-research. Everything BitCraft-
specific lives here — **except the Rust code**, which moved to the
`spacetimedb-bitcraft-mirror` fork in 2026-08 (see below).

## What's in here

| Path | What it is |
|---|---|
| `www/` | Fleet dashboard (`index.html`), in-browser table browser (`explorer/`), and tutorial site (`tutorial/`). Served by nginx in front of `relay-coordinator`'s `/health` and `relay-cache`'s HTTP endpoints. |
| `tools/` | systemd unit (`relay-cache.service`), nginx snippets, and fleet shell scripts (`fleet-status.sh`, `relay-fleet-start.sh`, `relay-staleness-monitor.sh`, `check-integrity.sh`) tuned for the BitCraft deployment's `relay-bc<N>` / `relay-global` unit-naming convention. |
| `BITCRAFT.md` | BitCraft server architecture: global → shard discovery, full 25-region grid, developer-token auth, SpacetimeDB v1 protocol. |
| `PORTS.md` | BitCraft port-allocation scheme (region band `3000 + regionID`, dashboard band `3100 + regionID`, etc.). |

## Where the Rust lives (`../spacetimedb-bitcraft-mirror`)

The `relay-cache` read cache (columnar stores + HTTP/protobuf API +
dim-buildings WebSocket, and its native integration into the BitCraft
mirror binary behind `--bitcraft-cache`) lives in the sibling fork
[`ekscrypto/spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror)
at `crates/relay-cache`. It consumes `relay-protocol` /
`relay-coordinator` from a sibling `spacetimedb-relay` checkout, so
building requires both siblings:

```sh
cd ../spacetimedb-bitcraft-mirror
cargo build -p relay-cache --release   # standalone WebSocket-mode binary
cargo test  -p relay-cache
cargo build -p spacetimedb-standalone --release  # mirror + embedded cache
```

See that repo's `BITCRAFT-FORK.md` and
`crates/relay-cache/README.md` / `DIM-BUILDINGS-WS.md` for the flag
list and the query/catalogue surface.

## Deployment notes

- Day-to-day deploys for this workspace live in the parent
  [`DEPLOY.md`](../DEPLOY.md) / [`tools/deploy.sh`](../tools/deploy.sh)
  (not in this repo's `tools/`).
- `relay-coordinator` should be started with
  `--source-name-template 'bitcraft-live-{stem}' --source-name-stem-prefix 'relay-bc'`
  so `/health` projects `relay-bc14` → `bitcraft-live-14` for the
  fleet dashboard. The generic coordinator defaults to passthrough
  naming; the BitCraft convention is supplied at the deployment
  boundary, not in the generic code.
- Operator notes (host names, account specifics, deploy IPs) live in
  `CLAUDE.local.md`, which is gitignored. Copy them in manually when
  standing up a new host.
- The `relay-status` ZCode skill under `.zcode/skills/` (also
  gitignored) reports live production fleet status via SSH; copy it
  in for operator workstations.

## License

MIT, see [`LICENSE`](LICENSE).
