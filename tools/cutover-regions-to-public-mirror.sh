#!/bin/sh
# cutover-regions-to-public-mirror.sh — partial WS + cache cutover for
# named regions from relay-bc* to spacetimedb-public-mirror.
#
# Dry-run by default. With --apply:
#   1. Verifies trial/production mirror rows are live on /v1/mirrors
#   2. Points nginx :300N for each region at the mirror WS listen
#   3. Stops relay-bcN units for those regions
#   4. Installs relay-cache + relay-coordinator drop-ins for hybrid mirror
#      discovery and restarts both
#
# Trial (regions 7/8 soak on loopback :3030):
#   ./tools/cutover-regions-to-public-mirror.sh \
#       --regions 7,8 \
#       --mirrors-url http://127.0.0.1:3031/v1/mirrors \
#       --mirror-ws-host 127.0.0.1:3030
#
# Production monolithic public-mirror (all regions on :3000):
#   ./tools/cutover-regions-to-public-mirror.sh \
#       --regions 7,8 \
#       --mirrors-url http://127.0.0.1:3001/v1/mirrors \
#       --mirror-ws-host 127.0.0.1:3000 \
#       --mirror-upstream http://127.0.0.1:3000
#
# Usage:
#   ./tools/cutover-regions-to-public-mirror.sh [options]
#   ./tools/cutover-regions-to-public-mirror.sh --apply [options]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT}/tools/relay-env.local.sh" 2>/dev/null || true

APPLY=0
REGIONS=""
MIRRORS_URL="${RELAY_MIRRORS_URL:-http://127.0.0.1:3031/v1/mirrors}"
MIRROR_WS_HOST="${RELAY_CACHE_MIRROR_WS_HOST:-127.0.0.1:3030}"
MIRROR_UPSTREAM="${MIRROR_UPSTREAM:-127.0.0.1:3030}"
SSH="${RELAY_SSH:-debian@relay.bitcraftsync.app}"
RELAY_BITCRAFT_DIR="${RELAY_BITCRAFT_DIR:-/srv/relay/bitcraft-relay}"
RELAY_CORE_DIR="${RELAY_CORE_DIR:-/srv/relay/spacetimedb-relay}"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --regions) REGIONS="$2"; shift 2 ;;
        --mirrors-url) MIRRORS_URL="$2"; shift 2 ;;
        --mirror-ws-host) MIRROR_WS_HOST="$2"; shift 2 ;;
        --mirror-upstream) MIRROR_UPSTREAM="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,28p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$REGIONS" ]; then
    echo "error: --regions required (e.g. --regions 7,8)" >&2
    exit 2
fi

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "$@"
    else
        echo "DRY-RUN ssh $SSH $*"
    fi
}

echo "== cutover regions $REGIONS to public-mirror =="
echo "   mirrors_url=$MIRRORS_URL"
echo "   mirror_ws_host=$MIRROR_WS_HOST"
echo "   nginx upstream=$MIRROR_UPSTREAM"
echo

echo "== 1/4: verify /v1/mirrors rows live =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    db="bitcraft-live-${r}"
    run_remote "curl -sf --max-time 5 '${MIRRORS_URL}' | python3 -c \"
import json, sys
d = json.load(sys.stdin)
for m in d.get('mirrors') or []:
    if m.get('database') == '${db}':
        conn = m.get('connectivity')
        tl, tt = m.get('tables_live'), m.get('tables_total')
        if conn != 'live' or tl != tt:
            print('NOT LIVE: ${db}', conn, tl, tt)
            sys.exit(1)
        print('OK ${db}', tl, '/', tt)
        sys.exit(0)
print('MISSING: ${db}')
sys.exit(1)
\""
done

echo "== 2/4: nginx :300N → ${MIRROR_UPSTREAM} for cutover regions =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    port=$((3000 + r))
    run_remote "sudo sed -i.bak-cutover-${r} \
        's|proxy_pass http://127.0.0.1:${port};|proxy_pass http://${MIRROR_UPSTREAM};|' \
        /etc/nginx/sites-available/relay-frontends 2>/dev/null || true"
done
run_remote "sudo cp /etc/nginx/sites-available/relay-frontends /etc/nginx/sites-enabled/relay-frontends && \
    sudo nginx -t && sudo nginx -s reload"

echo "== 3/4: stop relay-bc units for cutover regions =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    run_remote "sudo systemctl disable --now relay-bc${r}.service 2>/dev/null || true"
done

echo "== 4/4: relay-cache + relay-coordinator hybrid mirror config =="
CACHE_DROPIN="/etc/systemd/system/relay-cache.service.d/public-mirror-cutover.conf"
COORD_DROPIN="/etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf"
run_remote "sudo mkdir -p /etc/systemd/system/relay-cache.service.d /etc/systemd/system/relay-coordinator.service.d"
run_remote "printf '%s\n' \
    '[Service]' \
    'Environment=RELAY_CACHE_MIRRORS_URL=${MIRRORS_URL}' \
    'Environment=RELAY_CACHE_MIRROR_WS_HOST=${MIRROR_WS_HOST}' \
    'Environment=RELAY_CACHE_SCHEMA_HOST=${MIRROR_WS_HOST}' \
    'Environment=RELAY_CACHE_SCHEMA_DB=bitcraft-live-7' \
    | sudo tee ${CACHE_DROPIN} >/dev/null"
run_remote "printf '%s\n' \
    '[Service]' \
    'Environment=RELAY_MIRRORS_URL=${MIRRORS_URL}' \
    | sudo tee ${COORD_DROPIN} >/dev/null"
run_remote "sudo systemctl daemon-reload && sudo systemctl restart relay-coordinator relay-cache"

echo
echo "Done. Verify:"
echo "  curl -s http://127.0.0.1:8082/health | python3 -m json.tool"
echo "  curl -s http://127.0.0.1:8089/cache-health | python3 -m json.tool"
echo "  ./tools/public-mirror-trial-status.sh   # if using trial sidecar"
echo
echo "Rollback:"
echo "  ./tools/rollback-regions-from-public-mirror.sh --apply --regions ${REGIONS} \\"
echo "      --mirror-upstream ${MIRROR_UPSTREAM}"
