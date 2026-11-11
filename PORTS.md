# Port allocation

> **Production topology (since 2026-08-17).** `spacetimedb-bitcraft-mirror`
> runs one process mirroring all regions **with the read cache embedded**
> (`--bitcraft-cache`) — same public port band, same URLs, but
> `relay-cache.service` and the per-instance `public-mirror@*.service` fleet
> collapsed into that single process. It listens on `127.0.0.1:3100`
> (WS/HTTP), `127.0.0.1:3130` (status sidecar, main + 30), and serves the
> cache API on `127.0.0.1:8090`. nginx was repointed at the 2026-08-17
> cutover (WS band → `:3100`, cache `:8089` → `:8090`) and the blue fleet
> was decommissioned the same day. Since 2026-11 it mirrors the 1.0
> release upstream (`bitcraft-release.spacetimedb.com`): `idc-global` +
> `idc-{7,8,9,12,13,14,17,18,19}` = 10 databases. Nothing changes for
> clients.

## Formula (public ports — unchanged for clients)

```
BASE = 3000

GLOBAL        public port = BASE              (= 3000)
REGIONAL      public port = BASE + regionID   (e.g. region 14 → 3014)
```

`regionID` is the BitCraft in-game region number (1–49). Global is the
special case at offset 0.

## Backend

Production (`bitcraft-mirror.service`, the only backend):

| Role | Address |
|------|---------|
| Mirror HTTP + WS (loopback) | `127.0.0.1:3100` (`bitcraft-mirror.service`) |
| Mirror readiness JSON (isolated sidecar) | `GET http://127.0.0.1:3130/v1/mirrors` (main `:3100`, offset **+30**) |
| Embedded cache HTTP/WS incl. loopback `/internal/stats` | `127.0.0.1:8090` |
| Fleet `/health` (mirror-health) | `127.0.0.1:8082` → public `/health` (fed by `:3130/v1/mirrors` since the cutover) |

Historical (retired, not a rollback target): the blue `public-mirror@N`
fleet used loopback `3000+N` / status `3030+N` and a standalone
`relay-cache` on `:8089`; decommissioned 2026-08-17.

There is no per-region dashboard band (`3100+N`) and no per-region
`relay` / spawned stdb process.

## Bands

| Band | Ports | Use |
|------|-------|-----|
| Global + regional (public WSS/HTTP) | `3000–3025` | nginx TLS → `127.0.0.1:3100` |
| Reserved (future public) | `3026–3049` | Widen nginx/UFW when needed |
| **bitcraft-mirror (production)** | `3100` WS, `3130` status, `8090` cache | One-process mirror + embedded cache; see [`tools/bitcraft-mirror.service`](tools/bitcraft-mirror.service) |
| ~~Dashboard~~ | ~~`3100–3149`~~ | Retired with the old relay fleet (`bitcraft-mirror` reuses `3100`/`3130`) |

## Public URLs

```
wss://relay.bitcraftsync.app:<port>/v1/database/<database>/subscribe
https://relay.bitcraftsync.app:<port>/v1/database/<database>/schema?version=9
```

`<database>` is the upstream name: `idc-global` or `idc-N` (1.0 release
fleet; the EA2 names `bitcraft-live-*` were retired 2026-11). Any public
port in the open band reaches every database (nginx fans all ports to
the single mirror listen). Prefer `3000 + regionID` for clarity.

Subprotocol (offered in `Sec-WebSocket-Protocol`; the relay prefers v2
when several are offered): `v2.bsatn.spacetimedb` is the default —
required for the mirrored event tables (`market_trade_event`,
`craft_event`, …; insert-only `EventTable` frames, no snapshot/catch-up;
unsupported on v1 — rejected on `v1.bsatn`, empty snapshot on
`v1.json`). `v1.bsatn.spacetimedb` /
`v1.json.spacetimedb` still serve every state table and carry
per-transaction caller identity + timestamp (v2 frames carry rows only).
Mutations (`CallReducer`/`CallProcedure`) are rejected on all protocols.

nginx: the WS band proxies with plain `Upgrade`/`Connection` headers and
never touches `Sec-WebSocket-Protocol`, so v1/v2 negotiation passes
end-to-end — no per-protocol config. `tools/check-integrity.sh` re-proves
all four client paths (v2/v1.bsatn/v1.json/schema) through the public
band after every deploy.

## Public exposure

- nginx binds the public IPs on each port `3000–3025`, terminates TLS
  with the host's Let's Encrypt cert for `relay.bitcraftsync.app`, and
  proxies to `http://127.0.0.1:3100`. The live nginx site configs are
  kept privately, not in this repo.
- UFW allows `3000:3025/tcp` (plus `22/80/443`).
- The embedded cache in `bitcraft-mirror.service` binds `127.0.0.1:8090`
  (loopback). nginx proxies a fixed allowlist of its routes publicly
  (`/cache-health`, `/proto`, `/claim`, `/player`, `/deposits`,
  `/storage-logs`, and the WS `/internal/dim-buildings/ws`) and **not**
  `/internal/stats` — the loopback diagnostics live at
  `curl http://127.0.0.1:8090/internal/stats`. The standalone
  `relay-cache` (`:8089`) was retired with blue.
- `mirror-health.service` serves fleet `/health` on loopback `:8082`
  (proxied publicly as `/health`), polling `bitcraft-mirror`'s `:3130`
  `GET /v1/mirrors` plus host CPU/RAM/NIC samples.
