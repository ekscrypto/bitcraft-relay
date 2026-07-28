# AGENTS.md

Guidance for coding agents (ZCode, Claude Code, etc.) working in
**bitcraft-relay**. Read this before touching the repo — it exists to
prevent confusion that's specific to this project's split layout.

## What this repo is (and isn't)

`bitcraft-relay` is the **BitCraft-specific layer** only:

- `crates/relay-cache/` — same-host in-memory read cache over the relay
  fleet (the one crate in the workspace: `members = ["crates/relay-cache"]`).
- `www/` — fleet dashboard, in-browser table explorer, tutorial site.
- `tools/` — systemd unit(s), nginx snippets, fleet shell scripts.
- `BITCRAFT.md` / `PORTS.md` — BitCraft upstream architecture + port scheme.

The **generic relay core** lives in the sibling repo
[`ekscrypto/spacetimedb-relay`](https://github.com/ekscrypto/spacetimedb-relay)
and is consumed as a workspace dependency (see "Sibling repo access"
below). Do not expect to find the relay daemon, the publisher, the
frontend proxy, or the per-region systemd units in this repo — they
are not here.

## Sibling repo access (`../spacetimedb-relay`)

`Cargo.toml` consumes two crates from the sibling generic repo:

```toml
relay-protocol    = { path = "../spacetimedb-relay/crates/relay-protocol" }
relay-coordinator = { path = "../spacetimedb-relay/crates/relay-coordinator" }
```

**No authorization or special access is required.** The path dep is a
plain filesystem read; the sibling checkout already exists at exactly
that path on this workstation, and it is readable like any other folder.
If an agent believes it "can't access" the sibling repo, that belief is
wrong — it is a normal local directory, not a remote or a gated
resource.

Two things to know about the active form:

1. **It's a path dep, not a git dep.** The build uses whatever is
   checked out in `../spacetimedb-relay`. The prod-ready git-dep form
   (tag `relay-core-v2.2.0`) is documented inline in `Cargo.toml` but
   **not** active. To build against the published tag locally, either
   check the sibling out at the tag (`git -C ../spacetimedb-relay
   checkout relay-core-v2.2.0`) or swap `Cargo.toml` to the git-dep
   lines.
2. **The sibling is the source of the relay binary.** The relay daemon
   (`crates/relay`, plus `relay-frontend`, `relay-publisher`,
   `relay-upstream`, `relay-mirror-driver`) builds in the sibling
   workspace, not here. Ops scripts here reference
   `/srv/relay/spacetimedb-relay/target/release/relay` on the host —
   that path mirrors the sibling's layout.

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
  [`tools/deploy.sh`](../tools/deploy.sh)). Operator specifics (host
  names, account details, deploy IPs) live in **`CLAUDE.local.md`**,
  which is gitignored and intentionally absent from the tree.
- **Secrets** — upstream developer JWT (from Clockwork Labs), used via
  `RELAY_UPSTREAM_TOKEN` / host `/etc/relay/upstream.env`. Gitignored
  locally (e.g. `.developer-token`); never commit or log it. See
  `BITCRAFT.md`.

If asked to "update production," scope the work explicitly: confirm
which component (cache only vs. full fleet) and, for anything beyond
`relay-cache`, pull in the sibling repo and the host-side unit files
before proceeding.

## Local build

Requires a readable `../spacetimedb-relay` checkout (present by
default on this workstation):

```sh
cargo build -p relay-cache --release
cargo test  -p relay-cache
cargo run   -p relay-cache --release
```

## Conventions

- Comments only when the WHY is non-obvious.
- `anyhow::Result` at binary boundaries, `thiserror` inside libraries.
- No `unwrap()` in production code paths.
- External deps go in the root `Cargo.toml` `[workspace.dependencies]`,
  and **must** match the versions pinned in the sibling repo's
  `Cargo.toml` so SpacetimeDB wire-format versions line up.

## Security rules (non-negotiable)

- Never push to production without explicit per-change authorization.
  Prior approval does not carry over.
- Never log production identity tokens — they are long-lived developer
  bearer credentials from Clockwork Labs (`BITCRAFT.md`).
