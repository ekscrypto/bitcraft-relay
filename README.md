# bitcraft-relay

BitCraft fleet dashboard and operations tooling for the
[`spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror)
deployment at `relay.bitcraftsync.app`. This is the ops layer — static
sites, systemd/nginx tooling, and docs; it contains **no Rust**.

The old generic `spacetimedb-relay` repo (and its `relay-coordinator`)
was retired in 2026-08; everything BitCraft-specific that used to live
there is now split between this repo and the Rust fork (see below).

## What's in here

| Path | What it is |
|---|---|
| `www/` | Fleet dashboard (`index.html`), in-browser table browser (`explorer/`), and tutorial site (`tutorial/`). Served by nginx in front of `mirror-health`'s `/health` and the relay-cache HTTP endpoints. |
| `tools/` | systemd units (`bitcraft-mirror.service`, `mirror-health.service`, `relay-pin-bitcraft-mirror.service`, ram-guard), nginx snippets, and fleet scripts (`check-integrity.sh`, `relay-staleness-monitor.sh`, `wait-cache-ready.sh`, `wait-mirrors-live.sh`, `nginx-flip-bitcraft-mirror.sh`, `relay-pin-pages.sh`). Retired blue-stack units live in `tools/archive/`. |
| `BITCRAFT.md` | BitCraft server architecture: global → shard discovery, full 25-region grid, developer-token auth, SpacetimeDB v1 protocol. |
| `PORTS.md` | BitCraft port-allocation scheme (region band `3000 + regionID`, dashboard band `3100 + regionID`, etc.). |

## Where the Rust lives (`../spacetimedb-bitcraft-mirror`)

All Rust — the BitCraft-tuned SpacetimeDB fork, the `relay-cache` read
cache (columnar stores + HTTP/protobuf API + dim-buildings WebSocket),
and the `mirror-health` fleet aggregator — lives in the sibling fork
[`ekscrypto/spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror).
`relay-cache` consumes `relay-protocol` and
`spacetimedb-public-mirror-client` from that same workspace, so a
single checkout is enough:

```sh
cd ../spacetimedb-bitcraft-mirror
cargo build --release -p spacetimedb-standalone -p mirror-health -p relay-test-harness
```

See that repo's `BITCRAFT-FORK.md` and
`crates/relay-cache/README.md` / `USED-TABLES.md` for the flag list
and the query/catalogue surface.

## Deployment notes

- Day-to-day deploys for this workspace live in the parent
  [`DEPLOY.md`](../DEPLOY.md) / [`tools/deploy.sh`](../tools/deploy.sh)
  (not in this repo's `tools/`).
- Production runs a single `bitcraft-mirror.service`
  (`spacetimedb-standalone --public-mirror-v1 --bitcraft-cache`):
  WebSocket on `127.0.0.1:3100` (nginx fans ports 3000–3025 into it),
  status on `:3130`, cache API on `127.0.0.1:8090`.
  `mirror-health.service` polls `:3130` and serves the fleet `/health`
  JSON on `:8082`. Clients select regions by database name
  (`bitcraft-live-global`, `bitcraft-live-N`, …).
- Operator notes (host names, account specifics, deploy IPs) live in
  `CLAUDE.local.md` / `AGENTS.local.md`, which are gitignored. Copy
  them in manually when standing up a new host.
- The `relay-status` ZCode skill under `.zcode/skills/` (also
  gitignored) reports live production fleet status via SSH; copy it
  in for operator workstations.

## License

MIT, see [`LICENSE`](LICENSE).
