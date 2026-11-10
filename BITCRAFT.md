# BitCraft server architecture

Fan-research against the live deployment — updated 2026-11 for the
**1.0 official release** (`bitcraft-release.spacetimedb.com`, `idc-*`
modules), replacing the Early Access environment
(`bitcraft-early-access.spacetimedb.com`, `bitcraft-live-*`). Hostnames,
module names, and table layouts can change without notice.

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
| `idc-global` | Reference data (items, recipes, …) and the meta tables that advertise shards |
| `idc-{N}` | Gameplay shard for region ID `N` (1–25) |

Verified 2026-11-10 against 1.0 `region_connection_info`: every row is

```
https://bitcraft-release.spacetimedb.com
```

That is a **shared DNS name**, not proof of one server. The `host`
column exists so a region can point at a different origin (different
domain, same usual TLS port) without a client rebuild. Always use the
`host` from discovery — do not assume global and region *N* are
co-located.

## Protocol: SpacetimeDB v2

Since the game servers moved to **SpacetimeDB v2.0** (2026-09-21, late
EA2; carried into 1.0), the upstream speaks the v2 wire protocol
(`v2.bsatn.spacetimedb`). The relay mirrors over v2 BSATN; downstream
clients of our relay can still use `v1.bsatn` / `v1.json` (served by the
mirror), but `v1.json` directly against the upstream requires a
developer token — anonymous upstream connections stall before
`IdentityToken`/`InitialConnection`.

Subscribe / schema URL shape (replace `<host>` with the discovered
origin, `https` → `wss` for the socket):

```
wss://<host-without-scheme>/v1/database/<module>/subscribe
https://<host-without-scheme>/v1/database/<module>/schema?version=9
```

## Connect global first, then discover shards

1. Authenticate (see below) and open a WebSocket to
   `idc-global` on the known bootstrap host (today: the release
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

`module` is `idc-{id}` (verified 2026-11-10). Treat `host` as authoritative per
region even when every row currently repeats the release hostname.
Anonymous identities cannot read these tables — use a developer token
(see Authentication).

## Regions (full 5×5 = 25)

The world is a fixed **5×5 grid of region IDs 1–25**. Every cell has a
`region_connection_info` row and an `idc-{N}` module name.
For 1.0, **9 regions are player-buildable: 8, 9, 10, 12, 13, 14, 17, 18,
19**; the relay mirrors exactly those plus global.

Layout (**north up**, west → east), grid geometry from EA2 (2026-07-28).
Region **names** below are EA2-era — `world_region_name_state` was still
empty on 1.0 at cutover (pre-launch), so 1.0 display names are pending
verification:

```
21             22             23 Northern Islands   24             25
16             17 Draxen•     18 Oryxen•            19 Zephra•     20
11 Western Is. 12 Elyndor•   13 Hexalis•           14 Lumethis•   15 Eastern Is.
 6              7 Virexal      8 Solmere•            9 Marowik•    10
 1              2              3 Southern Islands    4              5
```

IDs increase west→east within a row and south→north by row
(`1` = south-west corner, `21` = north-west corner).
`•` = player-buildable in 1.0 (mirrored by the relay). Note region 10
is buildable in 1.0 but was not live in EA2; EA2-only regions 3, 7, 11,
15, 23 are not mirrored.

| ID | Name (EA2-era) | Module | Buildable in 1.0 |
|----|------|--------|------------|
| 1 | Region 1 | `idc-1` | |
| 2 | Region 2 | `idc-2` | |
| 3 | Southern Islands | `idc-3` | |
| 4 | Region 4 | `idc-4` | |
| 5 | Region 5 | `idc-5` | |
| 6 | Region 6 | `idc-6` | |
| 7 | Virexal | `idc-7` | |
| 8 | Solmere | `idc-8` | yes |
| 9 | Marowik | `idc-9` | yes |
| 10 | Region 10 | `idc-10` | yes |
| 11 | Western Islands | `idc-11` | |
| 12 | Elyndor | `idc-12` | yes |
| 13 | Hexalis | `idc-13` | yes |
| 14 | Lumethis | `idc-14` | yes |
| 15 | Eastern Islands | `idc-15` | |
| 16 | Region 16 | `idc-16` | |
| 17 | Draxen | `idc-17` | yes |
| 18 | Oryxen | `idc-18` | yes |
| 19 | Zephra | `idc-19` | yes |
| 20 | Region 20 | `idc-20` | |
| 21 | Region 21 | `idc-21` | |
| 22 | Region 22† | `idc-22` | |
| 23 | Northern Islands | `idc-23` | |
| 24 | Region 23† | `idc-24` | |
| 25 | Region 24† | `idc-25` | |

† Placeholder string stored in EA2 `world_region_name_state` (upstream
data quirk — trust the `id` / module name, not the placeholder label).

**`region_connection_info` is the discovery source of truth** for the
full 25.

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
../spacetimedb-bitcraft-mirror/target/release/spacetimedb-standalone start \
  --data-dir /tmp/bitcraft-mirror-data \
  --listen-addr 127.0.0.1:3000 \
  --jwt-pub-key-path /path/to/id_ecdsa.pub \
  --jwt-priv-key-path /path/to/id_ecdsa \
  --public-mirror-v1 \
  --mirror-token-file /path/to/.developer-token \
  --mirror wss://bitcraft-release.spacetimedb.com/idc-14 \
  ...
```

Prefer the `host` / `module` from `region_connection_info` over a
hard-coded upstream. (`spacetimedb-standalone` lives in the sibling
[`spacetimedb-bitcraft-mirror`](https://github.com/ekscrypto/spacetimedb-bitcraft-mirror)
fork; see its `BITCRAFT-FORK.md` quick start.) Region modules expose
hundreds of public-user tables; first connect / mirror publish is heavy
regardless of any subscribe-table filter (the filter only limits which
tables are ingested).
