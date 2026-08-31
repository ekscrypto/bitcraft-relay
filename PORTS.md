# Port allocation

> **Production topology (since 2026-08-17).** `spacetimedb-bitcraft-mirror`
> runs one process mirroring all regions **with the read cache embedded**
> (`--bitcraft-cache`) — same public port band, same URLs, but
> `relay-cache.service` and the per-instance `public-mirror@*.service` fleet
> collapsed into that single process. It listens on `127.0.0.1:3100`
> (WS/HTTP), `127.0.0.1:3130` (status sidecar, main + 30), and serves the
> cache API on `127.0.0.1:8090`. nginx flipped at the 2026-08-17 cutover
> (`bitcraft-relay/tools/nginx-flip-bitcraft-mirror.sh`: WS band → `:3100`,
> cache `:8089` → `:8090`; see DEPLOY.md § "One-process bitcraft-mirror
> cutover") and the blue fleet was decommissioned the same day. Nothing
> changes for clients.

## Formula (public ports — unchanged for clients)

```
BASE = 3000

GLOBAL        public port = BASE              (= 3000)
REGIONAL      public port = BASE + regionID   (e.g. region 14 → 3014)
```

`regionID` is the BitCraft in-game region number (1–49). Global is the
special case at offset 0.

## Backend

Production (green, `bitcraft-mirror.service`):

| Role | Address |
|------|---------|
| Mirror HTTP + WS (loopback) | `127.0.0.1:3100` (`bitcraft-mirror.service`) |
| Mirror readiness JSON (isolated sidecar) | `GET http://127.0.0.1:3130/v1/mirrors` (main `:3100`, offset **+30**) |
| Embedded cache HTTP/WS incl. loopback `/internal/stats` | `127.0.0.1:8090` |
| Fleet `/health` (mirror-health) | `127.0.0.1:8082` → public `/health` (fed by `:3130/v1/mirrors` since the cutover) |

Blue, rollback-only — re-seeded progressively (~15–45 min) by
`rollback-from-bitcraft-mirror.sh`; stopped + disabled 2026-08-17:

| Role | Address |
|------|---------|
| Mirror HTTP + WS (loopback) | `127.0.0.1:3000+N` (`public-mirror@N`; monolithic `:3000` historically) |
| Status | `127.0.0.1:3030+N/v1/mirrors` |
| `relay-cache` HTTP/WS (standalone) | `127.0.0.1:8089` |

There is no per-region dashboard band (`3100+N`) and no per-region
`relay` / spawned stdb process.

## Bands

| Band | Ports | Use |
|------|-------|-----|
| Global + regional (public WSS/HTTP) | `3000–3025` | nginx TLS → `127.0.0.1:3100` (green; was `:3000` pre-cutover) |
| Reserved (future public) | `3026–3049` | Widen nginx/UFW when needed |
| **Trial** (regions 7–8 only) | `3030` loopback, status `3060`, public `3037–3038` | Isolated `public-mirror-trial.service`; see [`tools/public-mirror-trial-deploy.sh`](tools/public-mirror-trial-deploy.sh) |
| **bitcraft-mirror (production)** | `3100` WS, `3130` status, `8090` cache | One-process mirror + embedded cache; see [`tools/cutover-to-bitcraft-mirror.sh`](tools/cutover-to-bitcraft-mirror.sh) |
| ~~Dashboard~~ | ~~`3100–3149`~~ | Retired with the old relay fleet (green reuses `3100`/`3130`) |

## Public URLs

```
wss://relay.bitcraftsync.app:<port>/v1/database/<database>/subscribe
https://relay.bitcraftsync.app:<port>/v1/database/<database>/schema?version=9
```

`<database>` is the upstream name: `bitcraft-live-global` or
`bitcraft-live-N`. Any public port in the open band reaches every
database (nginx fans all ports to the single mirror listen). Prefer
`3000 + regionID` for clarity.

Subprotocol: `v1.bsatn.spacetimedb` (provenance-preserving) or
`v2.bsatn.spacetimedb` (row updates; mutations still rejected).

## Public exposure

- nginx binds the public IPs on each port `3000–3025`, terminates TLS
  with the host's Let's Encrypt cert for `relay.bitcraftsync.app`, and
  proxies to `http://127.0.0.1:3100` (green; the pre-cutover configs said
  `:3000` / per-port `$server_port` —
  [`tools/nginx-public-mirror-frontends.snippet`](tools/nginx-public-mirror-frontends.snippet)
  documents the history).
- UFW allows `3000:3025/tcp` (plus `22/80/443`).
- The embedded cache in `bitcraft-mirror.service` binds `127.0.0.1:8090`
  (loopback). nginx proxies a fixed allowlist of its routes publicly
  (`/cache-health`, `/proto`, `/claim`, `/player`, `/deposits`,
  `/storage-logs`, and the WS `/internal/dim-buildings/ws`) and **not**
  `/internal/stats` — the loopback diagnostics live at
  `curl http://127.0.0.1:8090/internal/stats`. The standalone
  `relay-cache` (`:8089`) is retired with blue and kept for rollback only.
- `mirror-health.service` serves fleet `/health` on loopback `:8082`
  (proxied publicly as `/health`), polling the standalone's `:3130`
  `GET /v1/mirrors` plus host CPU/RAM/NIC samples.
