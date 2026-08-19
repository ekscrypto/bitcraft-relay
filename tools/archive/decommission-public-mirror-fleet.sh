#!/bin/sh
# decommission-public-mirror-fleet.sh — after the post-cutover soak, stop the
# blue standby: all public-mirror@*.service instances and the standalone
# relay-cache.service. Green (bitcraft-mirror.service) is untouched.
#
# From this moment, rollback-from-bitcraft-mirror.sh still works but blue
# re-seeds progressively (~15–45 min) instead of serving instantly.
#
# Usage:
#   decommission-public-mirror-fleet.sh            # dry-run
#   decommission-public-mirror-fleet.sh --apply    # execute
#
# Steps:
#   1. verify green is healthy (abort unless 14/14 live + cache ready)
#   2. stop every blue instance (public-mirror-stop-all.sh)
#   3. disable + stop relay-cache.service
#   4. disable public-mirror.target; daemon-reload
#   5. verify green still healthy; report freed memory

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BITCRAFT_ROOT=$(cd "$HERE/.." && pwd)
ENV_FILE="${BITCRAFT_ROOT}/../tools/relay-env.local.sh"

APPLY=0
for arg in "$@"; do
    case "$arg" in
        --apply)   APPLY=1 ;;
        -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
        *) echo "decommission-public-mirror-fleet.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

RELAY_HOST="${RELAY_HOST:-relay.bitcraftsync.app}"
RELAY_SSH_USER="${RELAY_SSH_USER:-debian}"
RELAY_SERVICE_USER="${RELAY_SERVICE_USER:-relay}"
RELAY_BITCRAFT_DIR="${RELAY_BITCRAFT_DIR:-/srv/relay/bitcraft-relay}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi
SSH_TARGET="${RELAY_SSH:-${RELAY_SSH_USER}@${RELAY_HOST}}"
GREEN_STATUS_PORT="${GREEN_STATUS_PORT:-3130}"
GREEN_CACHE_PORT="${GREEN_CACHE_PORT:-8090}"

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH_TARGET" "$@" || exit $?
    else
        printf '$ ssh %s %s\n' "$SSH_TARGET" "$*"
    fi
}

echo "decommission-public-mirror-fleet.sh — target ${SSH_TARGET}"
[ "$APPLY" -eq 0 ] && echo "DRY-RUN (add --apply to execute)."
echo

echo "== 1/5: verify green is healthy (abort otherwise) =="
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-mirrors-live.sh \
    http://127.0.0.1:${GREEN_STATUS_PORT}/v1/mirrors 14 300 10" || {
    echo "green NOT healthy — not decommissioning blue. Roll back instead:" >&2
    echo "  ${HERE}/rollback-from-bitcraft-mirror.sh --apply" >&2
    exit 1
}
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-cache-ready.sh \
    http://127.0.0.1:${GREEN_CACHE_PORT}/cache-health 300 5"

echo "== 2/5: stop all blue instances =="
run_remote "sudo ${RELAY_BITCRAFT_DIR}/tools/archive/public-mirror-stop-all.sh"

echo "== 3/5: disable + stop standalone relay-cache =="
run_remote "sudo systemctl disable --now relay-cache.service && echo 'relay-cache stopped + disabled'"

echo "== 4/5: disable public-mirror.target; daemon-reload =="
run_remote "sudo systemctl disable public-mirror.target 2>/dev/null || true; \
    sudo systemctl daemon-reload"

echo "== 5/5: verify green + report memory =="
run_remote "curl -sf http://127.0.0.1:${GREEN_STATUS_PORT}/v1/mirrors | head -c 200; echo; \
    curl -sf https://relay.bitcraftsync.app/cache-health | head -c 200; echo; \
    free -h"

echo
echo "Blue decommissioned; green is the only topology. Rollback is still"
echo "possible but now re-seeds blue progressively:"
echo "  ${HERE}/rollback-from-bitcraft-mirror.sh --apply"
if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run complete. Re-run with --apply to execute."
fi
