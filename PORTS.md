# Port allocation

The live data path is a single **`spacetimedb-public-mirror`** process
(`--public-mirror-v1`) that mirrors global + every regional BitCraft
database in memory. It listens on one loopback address. nginx keeps the
historical public port band so existing client tooling that keys off
`3000 + regionID` still works — every public port proxies to the same
backend; the database name selects the region.

## Formula (public ports — unchanged for clients)

```
BASE = 3000

GLOBAL        public port = BASE              (= 3000)
REGIONAL      public port = BASE + regionID   (e.g. region 14 → 3014)
```

`regionID` is the BitCraft in-game region number (1–49). Global is the
special case at offset 0.

## Backend (public-mirror)

| Role | Address |
|------|---------|
| Mirror HTTP + WS (loopback) | `127.0.0.1:3000` |
| Mirror readiness JSON (isolated sidecar) | `GET http://127.0.0.1:3030/v1/mirrors` (monolithic `:3000` main) |
| Per-region sidecar (native-port cutover) | `GET http://127.0.0.1:3030+N/v1/mirrors` (main `:3000+N`, offset **+30**) |
| Per-mirror readiness JSON (legacy, main server) | `GET http://127.0.0.1:3000/v1/mirrors` |
| Fleet `/health` (coordinator) | `127.0.0.1:8082` → public `/health` |
| `relay-cache` HTTP/WS | `127.0.0.1:8089` |

There is no per-region dashboard band (`3100+N`) and no per-region
`relay` / spawned stdb process.

## Bands

| Band | Ports | Use |
|------|-------|-----|
| Global + regional (public WSS/HTTP) | `3000–3025` | nginx TLS → `127.0.0.1:3000` |
| Reserved (future public) | `3026–3049` | Widen nginx/UFW when needed |
| **Trial** (regions 7–8 only) | `3030` loopback, status `3060`, public `3037–3038` | Isolated `public-mirror-trial.service`; see [`tools/public-mirror-trial-deploy.sh`](tools/public-mirror-trial-deploy.sh) |
| ~~Dashboard~~ | ~~`3100–3149`~~ | Retired with the old relay fleet |

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
  proxies to `http://127.0.0.1:3000` (see
  [`tools/nginx-public-mirror-frontends.snippet`](tools/nginx-public-mirror-frontends.snippet)).
- UFW allows `3000:3025/tcp` (plus `22/80/443`).
- `relay-cache` binds `127.0.0.1:8089` (loopback). nginx proxies a
  fixed allowlist of its routes publicly (`/cache-health`, `/proto`,
  `/claim`, `/player`, `/deposits`, `/storage-logs`, and the WS
  `/internal/dim-buildings/ws`) and **not** `/internal/stats`.
- `relay-coordinator` serves fleet `/health` on loopback `:8082`
  (proxied publicly as `/health`), aggregating `GET /v1/mirrors` plus
  host CPU/RAM/NIC samples.
