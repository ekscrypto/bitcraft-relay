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
| `tools/` | systemd units (`bitcraft-mirror.service`, `mirror-health.service`, `relay-pin-bitcraft-mirror.service`, ram-guard), nginx snippets, and fleet scripts (`check-integrity.sh`, `wait-cache-ready.sh`, `wait-mirrors-live.sh`, `relay-pin-pages.sh`). Retired relay-fleet / blue / EA2-era files live in `tools/archive/` (historical only, not a rollback path). |
| `BITCRAFT.md` | BitCraft server architecture: global → shard discovery, full 25-region grid, developer-token auth, SpacetimeDB v2 upstream protocol (relay clients may use `v2.bsatn` or `v1.bsatn` / `v1.json`). |
| `PORTS.md` | BitCraft port-allocation scheme (public band `3000 + regionID`; loopback `:3100` mirror, `:3130` status, `:8090` cache). |

## Where the Rust lives (`../spacetimedb-bitcraft-mirror`)

All Rust — the BitCraft-tuned SpacetimeDB fork, the `relay-cache` read
cache (columnar stores + HTTP/protobuf API + dim-buildings WebSocket),
and the `mirror-health` fleet aggregator — lives in the sibling fork
[`ekscrypto/spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror)
(branch `bitcraft-mirror-v2`, the default).
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
  JSON on `:8082`. It mirrors 10 databases from the 1.0 release
  upstream `bitcraft-release.spacetimedb.com`: `idc-global` +
  `idc-{7,8,9,12,13,14,17,18,19}` (the 9 regions with player
  settlements; the other 16 of the 25 regions are empty and not
  mirrored). Clients select a database by name.
- Operator notes (host/user facts, deploy cautions) live in
  `AGENTS.local.md` (gitignored; `CLAUDE.local.md` is a symlink to
  it). Copy it in manually on a new operator workstation.
- nginx site configs for the production host are kept privately, not
  in this repo.
- Live fleet status: the operator-level `relay-status` agent skill
  (`~/.agents/skills/relay-status/`, not in this repo).

## License

MIT, see [`LICENSE`](LICENSE).
