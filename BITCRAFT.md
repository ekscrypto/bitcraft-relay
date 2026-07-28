# BitCraft server architecture

Fan-research against the live Early Access deployment. Hostnames, module
names, and table layouts can change without notice.

## Overview

BitCraft’s game logic runs as SpacetimeDB modules: one **global** module
plus one **gameplay shard per region**. Do not confuse that with this
repo’s relay fleet — we mirror many upstream shards onto **one** box;
Clockwork’s deployment is multi-shard and almost certainly multi-machine.

Each shard is addressed as a `(host, module)` pair. Clients learn those
pairs from global (see below); they do not hard-code a single upstream
machine.

| Module | Role |
|--------|------|
| `bitcraft-live-global` | Reference data (items, recipes, …) and the meta tables that advertise shards |
| `bitcraft-live-{N}` | Gameplay shard for region ID `N` (1–25) |

As of 2026-07-28 every `region_connection_info.host` is still the same
URL string:

```
https://bitcraft-early-access.spacetimedb.com
```

That is a **shared DNS name**, not proof of one server. The name
currently resolves to multiple A records, and the `host` column exists
so a region can point at a different origin (different domain, same
usual TLS port) without a client rebuild. Always use the `host` from
discovery — do not assume global and region *N* are co-located.

## Protocol: SpacetimeDB v1

BitCraft still speaks **SpacetimeDB protocol v1** on the wire
(`v1.bsatn.spacetimedb` or `v1.json.spacetimedb`). Both subprotocols are
accepted interchangeably on `bitcraft-live-*` modules.

The relay fleet uses the BSATN path (`--upstream-protocol v1`). Public
scrapers often prefer JSON because it is easier to debug from Python —
that is a client convention, not a server requirement.

Subscribe / schema URL shape (replace `<host>` with the discovered
origin, `https` → `wss` for the socket):

```
wss://<host-without-scheme>/v1/database/<module>/subscribe
https://<host-without-scheme>/v1/database/<module>/schema?version=9
```

## Connect global first, then discover shards

1. Authenticate (see below) and open a v1 WebSocket to
   `bitcraft-live-global` on the known bootstrap host (today: the EA
   hostname above).
2. Subscribe to the public meta tables that describe the world.
3. For the region you want, read its `host` + `module` from
   `region_connection_info` and open a **second** connection to that
   pair — which may be a different origin than global.

### Useful global tables

| Table | Columns (summary) | Use |
|-------|-------------------|-----|
| `region_connection_info` | `id` (u8), `host`, `module` | Canonical shard directory — one row per region |
| `world_region_name_state` | `id`, `player_facing_name`, `module_name_prefix` | Display names |
| `region_population_info` | `region_id`, `signed_in_players`, `players_in_queue` | Live occupancy (only for regions that publish it) |
| `region_control_info` | `region_id`, `initialized`, `allow_players`, `allow_player_spawns` | Whether the shard is open |
| `region_sign_in_parameters` | caps / queue / grace period per `region_id` | Sign-in limits |

`module` is `bitcraft-live-{id}`. Treat `host` as authoritative per
region even when every row currently repeats the EA hostname.
Anonymous identities cannot read these tables — use a developer token
(see Authentication).

## Regions (full 5×5 = 25)

The world is a fixed **5×5 grid of region IDs 1–25**. Every cell has a
`region_connection_info` row and a `bitcraft-live-{N}` module name.
Only a subset is currently initialized for players
(`region_control_info` / `region_population_info`).

Layout (**north up**, west → east), snapshot **2026-07-28** from
`world_region_name_state` + live population rows:

```
21             22             23 Northern Islands*  24             25
16             17 Draxen*     18 Oryxen*            19 Zephra*     20
11 Western Is.* 12 Elyndor*   13 Hexalis*           14 Lumethis*   15 Eastern Is.*
 6              7 Virexal*     8 Solmere*            9 Marowik*    10
 1              2              3 Southern Islands*   4              5
```

IDs increase west→east within a row and south→north by row
(`1` = south-west corner, `21` = north-west corner).
`*` = present in `region_population_info` / `region_control_info` (player-facing
shard today). Unmarked cells still appear in `region_connection_info` with
placeholder names like `Region N` in `world_region_name_state`.

| ID | Name | Module | Live today |
|----|------|--------|------------|
| 1 | Region 1 | `bitcraft-live-1` | |
| 2 | Region 2 | `bitcraft-live-2` | |
| 3 | Southern Islands | `bitcraft-live-3` | yes |
| 4 | Region 4 | `bitcraft-live-4` | |
| 5 | Region 5 | `bitcraft-live-5` | |
| 6 | Region 6 | `bitcraft-live-6` | |
| 7 | Virexal | `bitcraft-live-7` | yes |
| 8 | Solmere | `bitcraft-live-8` | yes |
| 9 | Marowik | `bitcraft-live-9` | yes |
| 10 | Region 10 | `bitcraft-live-10` | |
| 11 | Western Islands | `bitcraft-live-11` | yes |
| 12 | Elyndor | `bitcraft-live-12` | yes |
| 13 | Hexalis | `bitcraft-live-13` | yes |
| 14 | Lumethis | `bitcraft-live-14` | yes |
| 15 | Eastern Islands | `bitcraft-live-15` | yes |
| 16 | Region 16 | `bitcraft-live-16` | |
| 17 | Draxen | `bitcraft-live-17` | yes |
| 18 | Oryxen | `bitcraft-live-18` | yes |
| 19 | Zephra | `bitcraft-live-19` | yes |
| 20 | Region 20 | `bitcraft-live-20` | |
| 21 | Region 21 | `bitcraft-live-21` | |
| 22 | Region 21† | `bitcraft-live-22` | |
| 23 | Northern Islands | `bitcraft-live-23` | yes |
| 24 | Region 23† | `bitcraft-live-24` | |
| 25 | Region 24† | `bitcraft-live-25` | |

† Placeholder string currently stored in `world_region_name_state` (upstream
data quirk — trust the `id` / module name, not the placeholder label).

Public occupancy mirrors (e.g. Bitjita’s `https://bitjita.com/api/status`)
track the live subset; **`region_connection_info` is the discovery source
of truth** for the full 25.

## Authentication

**Do not use a player / game-account token** for this project. Player
auth (email access codes, Unity PlayerPrefs JWTs, etc.) is out of
scope for the relay: it can kick a live game session, ties the mirror
to a personal account, and is not how production is meant to run.

Upstream access for the relay uses a **developer token** issued by
[Clockwork Labs](https://clockworklabs.io/) (the studio behind BitCraft
and SpacetimeDB. Reach out to them to
obtain one; this repo does not document or automate player signup.

### How the relay uses the developer token

The token is a long-lived SpacetimeDB bearer JWT. Every upstream
WebSocket the relay opens (global + each region) sends:

```
Authorization: Bearer <developer-token>
```

Wire it in without pasting the secret into shell history or docs:

| Context | Mechanism |
|---------|-----------|
| Local / ad-hoc | `RELAY_UPSTREAM_TOKEN` (or `--upstream-token`) — load from a gitignored file such as `.developer-token` at the workspace root |
| Production | `/etc/relay/upstream.env` (`EnvironmentFile=` on the systemd units), mode `640`, owned `root:relay` |

Never commit the token, never log it, and never put it in unit files or
scripts checked into git. Rotate via Clockwork Labs if it leaks.

## Talking to a region

After discovery (example uses today’s advertised host for region 14):

```sh
RELAY_UPSTREAM_TOKEN=$(grep -E '^eyJ' .developer-token | head -1) \
  cargo run -p relay --manifest-path ../spacetimedb-relay/Cargo.toml -- \
  --upstream wss://bitcraft-early-access.spacetimedb.com \
  --database bitcraft-live-14 \
  --upstream-protocol v1 \
  ...
```

Prefer the `host` / `module` from `region_connection_info` over a
hard-coded upstream. (`relay` lives in the sibling
[`spacetimedb-relay`](https://github.com/ekscrypto/spacetimedb-relay)
workspace.) Region modules expose hundreds of public-user tables; first
connect / mirror publish is heavy regardless of any subscribe-table
filter (the filter only limits which tables are ingested).
