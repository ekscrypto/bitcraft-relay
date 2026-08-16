# AGENTS.md

Guidance for coding agents (ZCode, Claude Code, etc.) working in
**bitcraft-relay**. Read this before touching the repo — it exists to
prevent confusion that's specific to this project's split layout.

## What this repo is (and isn't)

`bitcraft-relay` is the **BitCraft-specific ops layer** only:

- `www/` — fleet dashboard, in-browser table explorer, tutorial site.
- `tools/` — systemd unit(s), nginx snippets, fleet shell scripts.
- `BITCRAFT.md` / `PORTS.md` — BitCraft upstream architecture + port scheme.

The **Rust code** (the `relay-cache` read cache) lived here until 2026-08;
it now lives in the sibling fork
[`ekscrypto/spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror)
(`crates/relay-cache`), which also embeds it into the BitCraft-tuned
mirror binary via `--bitcraft-cache`. The standalone WebSocket-mode
`relay-cache` binary still builds from that repo unchanged. The
**generic relay core** remains in the sibling repo
[`ekscrypto/spacetimedb-relay`](https://github.com/ekscrypto/spacetimedb-relay)
(consumed by the fork as a path dep). Do not expect to find the relay
daemon, the publisher, the frontend proxy, or the per-region systemd
units in this repo — they are not here.

## Where `relay-cache` builds (`../spacetimedb-bitcraft-mirror`)

```sh
git -C ../spacetimedb-bitcraft-mirror pull
(cd ../spacetimedb-bitcraft-mirror && cargo build -p relay-cache --release)
```

That repo path-deps `relay-protocol` / `relay-coordinator` from
`../spacetimedb-relay`, so **both siblings must be checked out** to build
(no authorization needed — plain filesystem reads; the siblings already
exist at exactly those paths on this workstation). Day-to-day deploys
build it there — see [`../DEPLOY.md`](../DEPLOY.md).

## What it takes to update the full production fleet

**This repo alone is NOT sufficient to update all production
components.** It can rebuild and ship `relay-cache` and the dashboard
assets, and it carries the fleet ops scripts — but it cannot rebuild or
roll the relay binary, the per-instance systemd units, SpacetimeDB
itself, or the nginx config end-to-end. Specifically, the following are
**not** captured here:

- **The relay daemon binary** — built in the sibling repo, not here.
- **Per-instance systemd units** — only `tools/relay-cache.service`
  exists. `relay-global.service`, `relay-bc<N>.service`,
  `relay-coordinator.service`, `relay-fleet-sequencer.service`, and the
  staleness-monitor unit are referenced by ops scripts but not stored
  in the repo. They live only on the production host.
- **SpacetimeDB** — no install procedure, version pin, or download
  script. The relays spawn their own stdb via `--stdb-spawn`, but how
  `spacetime` got onto the box and how to upgrade it is undocumented
  here.
- **Deploy/runbook automation** — this repo has no `Makefile` / CI/CD /
  deploy entrypoint of its own. Day-to-day deploys live in the parent
  workspace ([`DEPLOY.md`](../DEPLOY.md),
  [`tools/deploy.sh`](../tools/deploy.sh)). Operator specifics (SSH
  account, deploy IPs, host layout) live in **`AGENTS.local.md`** /
  **`CLAUDE.local.md`**, which are gitignored and intentionally absent
  from the tree.
- **Secrets** — upstream developer JWT (from Clockwork Labs), used via
  `RELAY_UPSTREAM_TOKEN` / host `/etc/relay/upstream.env`. Gitignored
  locally (e.g. `.developer-token`); never commit or log it. See
  `BITCRAFT.md`.

If asked to "update production," scope the work explicitly: confirm
which component (cache only vs. full fleet) and, for anything beyond
`relay-cache`, pull in the sibling repo and the host-side unit files
before proceeding.

## Local build

Happens in the sibling fork (see "Where `relay-cache` builds" above):

```sh
cd ../spacetimedb-bitcraft-mirror
cargo build -p relay-cache --release
cargo test  -p relay-cache
cargo run   -p relay-cache --release
```

## Partial region cutover scripts

To move **some** regions from `relay-bc*` to public-mirror (and back) without
touching the rest of the fleet, use the paired ops scripts in `tools/`:

| Script | Purpose |
|--------|---------|
| `cutover-regions-to-public-mirror.sh` | Stop `relay-bcN`, repoint nginx, hybrid cache/coordinator drop-ins |
| `rollback-regions-from-public-mirror.sh` | Reverse the above for the same `--regions` list |

Full runbook (trial soak, env vars, gotchas, full-host rollback):
[`../DEPLOY.md` — Partial region cutover](../DEPLOY.md#partial-region-cutover-relay--public-mirror).

## Conventions

- Comments only when the WHY is non-obvious.
- `anyhow::Result` at binary boundaries, `thiserror` inside libraries.
- No `unwrap()` in production code paths.
- Rust changes belong in `../spacetimedb-bitcraft-mirror` (relay-cache) or
  `../spacetimedb-relay` (generic core); external dep versions must stay
  aligned across those workspaces so SpacetimeDB wire-format versions line
  up.

## Security rules (non-negotiable)

- Never push to production without explicit per-change authorization.
  Prior approval does not carry over.
- Never log production identity tokens — they are long-lived developer
  bearer credentials from Clockwork Labs (`BITCRAFT.md`).
