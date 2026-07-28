# bitcraft-relay

BitCraft-specific read cache, fleet dashboard, and operations tooling for
[spacetimedb-relay](https://github.com/ekscrypto/spacetimedb-relay).

This repo was split out of `spacetimedb-relay` so the generic relay can
be deployed against any SpacetimeDB upstream without carrying BitCraft's
tables, queries, deploy topology, or fan-research. Everything BitCraft-
specific lives here.

## What's in here

| Path | What it is |
|---|---|
| `crates/relay-cache/` | Same-host in-memory read cache over the relay fleet. Subscribes to each regional frontend on loopback, holds claim / building / inventory / player / housing / craft / hexite-deposit / storage-log tables in columnar memory, and serves HTTP + protobuf queries plus a public housing-interior building-id WebSocket. See [`crates/relay-cache/README.md`](crates/relay-cache/README.md) and [`crates/relay-cache/DIM-BUILDINGS-WS.md`](crates/relay-cache/DIM-BUILDINGS-WS.md). |
| `www/` | Fleet dashboard (`index.html`), in-browser table browser (`explorer/`), and tutorial site (`tutorial/`). Served by nginx in front of `relay-coordinator`'s `/health` and `relay-cache`'s HTTP endpoints. |
| `tools/` | systemd unit (`relay-cache.service`), nginx snippets, and fleet shell scripts (`fleet-status.sh`, `relay-fleet-start.sh`, `relay-staleness-monitor.sh`, `check-integrity.sh`) tuned for the BitCraft deployment's `relay-bc<N>` / `relay-global` unit-naming convention. |
| `BITCRAFT.md` | BitCraft server architecture: global → shard discovery, full 25-region grid, developer-token auth, SpacetimeDB v1 protocol. |
| `PORTS.md` | BitCraft port-allocation scheme (region band `3000 + regionID`, dashboard band `3100 + regionID`, etc.). |

## Relationship to spacetimedb-relay

`relay-cache` consumes the generic, deployment-neutral crates from
[`ekscrypto/spacetimedb-relay`](https://github.com/ekscrypto/spacetimedb-relay)
as workspace dependencies:

- **`relay-protocol`** — BSATN row decoder + module-schema types
  (`MirroredSchema`, `MirroredField`, `MirroredType`, `bsatn::decode_row`).
- **`relay-coordinator`** — systemd unit discovery
  (`relay_coordinator::health::discover`), used by `relay-cache`'s
  `discovery.rs` to find each regional frontend.

### Path-dep vs git-dep

The active `Cargo.toml` uses a **relative path dep** so the workspace
builds in-place alongside a sibling checkout of `spacetimedb-relay`:

```toml
relay-protocol    = { path = "../spacetimedb-relay/crates/relay-protocol" }
relay-coordinator = { path = "../spacetimedb-relay/crates/relay-coordinator" }
```

The production form (documented inline in `Cargo.toml`) is a git dep
on the published tag:

```toml
relay-protocol    = { git = "https://github.com/ekscrypto/spacetimedb-relay.git", tag = "relay-core-v2.2.0" }
relay-coordinator = { git = "https://github.com/ekscrypto/spacetimedb-relay.git", tag = "relay-core-v2.2.0" }
```

Switch to the git-dep form when deploying to a host that doesn't have
a sibling `spacetimedb-relay` checkout. Bump the tag when consuming
newer relay-core behaviour; the BSATN / SpacetimeDB wire-format
versions in this repo's `[workspace.dependencies]` must match the
generic repo's exactly.

## Build

```sh
# Requires a sibling checkout of spacetimedb-relay
# (path-dep form). See above if deploying without one.
cargo build -p relay-cache --release
cargo test  -p relay-cache
```

105 unit tests cover the BSATN decoders, columnar stores, and HTTP
response shaping.

## Run

```sh
cargo run -p relay-cache --release
```

Defaults discover regions from `/etc/systemd/system/relay-bc*.service`
and fetch the shared schema from `http://127.0.0.1:3014`. See
[`crates/relay-cache/README.md`](crates/relay-cache/README.md) for the
full flag list and the query/catalogue surface.

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
