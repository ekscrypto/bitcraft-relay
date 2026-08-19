#!/bin/sh
# public-mirror-start.sh — start one public-mirror instance for DATABASE.
#
# Invoked by public-mirror@.service as:
#   public-mirror-start.sh bitcraft-live-14
#
# Derives loopback listen port (3000 + regionID), per-database data dir,
# and a single --mirror upstream URL. Sidecar GET /v1/mirrors binds at
# main port + 30 (e.g. region 7 → :3007 main, :3037 status). Requires
# RELAY_UPSTREAM_TOKEN (or equivalent) via EnvironmentFile on the unit.

set -eu

DATABASE="${1:-}"
if [ -z "$DATABASE" ]; then
    echo "public-mirror-start: missing database argument" >&2
    exit 2
fi

UPSTREAM_BASE="${PUBLIC_MIRROR_UPSTREAM:-wss://bitcraft-early-access.spacetimedb.com}"
STANDALONE="${PUBLIC_MIRROR_BIN:-/srv/relay/spacetimedb-public-mirror/target/release/spacetimedb-standalone}"
JWT_DIR="${PUBLIC_MIRROR_JWT_DIR:-/srv/relay/.config/spacetime}"
DATA_ROOT="${PUBLIC_MIRROR_DATA_ROOT:-/var/lib/relay/public-mirror}"

case "$DATABASE" in
    bitcraft-live-global|*-global)
        PORT=3000
        ;;
    bitcraft-live-*)
        REGION="${DATABASE#bitcraft-live-}"
        case "$REGION" in
            *[!0-9]*)
                echo "public-mirror-start: cannot parse region from $DATABASE" >&2
                exit 2
                ;;
        esac
        PORT=$((3000 + REGION))
        ;;
    *)
        echo "public-mirror-start: unsupported database name: $DATABASE" >&2
        exit 2
        ;;
esac

DATA_DIR="${DATA_ROOT}/${DATABASE}"
mkdir -p "$DATA_DIR"

exec "$STANDALONE" start \
    --data-dir "$DATA_DIR" \
    --listen-addr "127.0.0.1:${PORT}" \
    --jwt-key-dir "$JWT_DIR" \
    --public-mirror-v1 \
    --non-interactive \
    --coordinator-socket /run/relay/coordinator.sock \
    --mirror "${UPSTREAM_BASE}/${DATABASE}"
