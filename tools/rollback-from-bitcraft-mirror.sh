#!/bin/sh
# rollback-from-bitcraft-mirror.sh — revert production from the one-process
# bitcraft-mirror (green) back to the per-instance public-mirror@*.service
# fleet + standalone relay-cache (blue), restoring everything from the
# backup bundle the cutover script created.
#
# Speed depends on when you roll back:
#   - Before decommission (blue warm): nginx restore + reload is seconds;
#     warm instances and relay-cache never stopped, so service is immediate.
#     Cold instances are restarted by the coordinator fleet sequencer and
#     serve progressively as each finishes seeding (~1–3 min per region).
#   - After decommission: same script; everything re-seeds progressively
#     (~15–45 min until the last region is live).
#
# Usage:
#   rollback-from-bitcraft-mirror.sh                # dry-run, latest bundle
#   rollback-from-bitcraft-mirror.sh --apply        # execute
#   rollback-from-bitcraft-mirror.sh --apply --backup-dir /srv/relay/backups/bitcraft-mirror-cutover-<TS>
#
# Steps:
#   1. resolve the backup bundle (latest unless --backup-dir)
#   2. restore nginx config from the bundle; nginx -t guards the reload
#      (falls back to nginx-flip-bitcraft-mirror.sh down if the bundle has
#      no nginx copies) — warm blue serves again from this moment
#   3. stop + disable green (bitcraft-mirror.service + ram-guard)
#   4. restore the coordinator drop-in; restart — sequencer ON again, which
#      starts the stopped blue instances sequentially
#   5. ensure relay-cache is enabled + started
#   6. advisory waits: per-region sidecar live, cache ready
#   7. verify (loopback + public)

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BITCRAFT_ROOT=$(cd "$HERE/.." && pwd)
ENV_FILE="${BITCRAFT_ROOT}/../tools/relay-env.local.sh"

APPLY=0
BACKUP_DIR=""
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)      APPLY=1 ;;
        --backup-dir) BACKUP_DIR="$2"; shift ;;
        -h|--help)    sed -n '2,28p' "$0"; exit 0 ;;
        *) echo "rollback-from-bitcraft-mirror.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
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
GREEN_WS_PORT="${GREEN_WS_PORT:-3100}"
GREEN_CACHE_PORT="${GREEN_CACHE_PORT:-8090}"
BACKUP_ROOT="${BACKUP_ROOT:-/srv/relay/backups}"

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH_TARGET" "$@" || exit $?
    else
        printf '$ ssh %s %s\n' "$SSH_TARGET" "$*"
    fi
}

echo "rollback-from-bitcraft-mirror.sh — target ${SSH_TARGET}"
[ "$APPLY" -eq 0 ] && echo "DRY-RUN (add --apply to execute)."
echo

echo "== 1/7: resolve backup bundle =="
if [ -z "$BACKUP_DIR" ]; then
    if [ "$APPLY" -eq 1 ]; then
        BACKUP_DIR=$(ssh "$SSH_TARGET" "sudo ls -1dt ${BACKUP_ROOT}/bitcraft-mirror-cutover-* 2>/dev/null | head -1") || exit $?
        if [ -z "$BACKUP_DIR" ]; then
            echo "no backup bundle found under ${BACKUP_ROOT} — pass --backup-dir" >&2
            exit 1
        fi
        echo "resolved bundle: ${BACKUP_DIR}"
        run_remote "test -f ${BACKUP_DIR}/manifest.txt && echo 'bundle OK' || { echo 'bundle incomplete (no manifest.txt)' >&2; exit 1; }"
    else
        run_remote "sudo ls -1dt ${BACKUP_ROOT}/bitcraft-mirror-cutover-* 2>/dev/null | head -1"
        echo "(dry-run: latest bundle is resolved at apply time)"
    fi
else
    run_remote "test -f ${BACKUP_DIR}/manifest.txt && echo 'bundle OK: ${BACKUP_DIR}'"
fi

echo "== 2/7: restore nginx from bundle → blue (warm blue serves again after reload) =="
if [ -n "$BACKUP_DIR" ]; then
    run_remote "sudo sh -c 'test -s ${BACKUP_DIR}/nginx/paths.txt || { echo \"no nginx copies in bundle — using nginx-flip down\"; exit 10; }'; rc=\$?; \
        if [ \"\$rc\" = 10 ]; then sudo ${RELAY_BITCRAFT_DIR}/tools/nginx-flip-bitcraft-mirror.sh down; \
        else sudo sh -c 'cd /; while read -r f; do base=\$(echo \"\$f\" | tr / _); \
                cp \"${BACKUP_DIR}/nginx/\$base\" \"\$f\" || exit 1; \
            done < ${BACKUP_DIR}/nginx/paths.txt' && \
            sudo nginx -t && sudo nginx -s reload && echo 'nginx restored from bundle'; \
        fi"
else
    echo "(dry-run: bundle not resolved yet — at apply time the latest bundle is used)"
    run_remote "sudo ${RELAY_BITCRAFT_DIR}/tools/nginx-flip-bitcraft-mirror.sh down"
fi

echo "== 3/7: stop + disable green =="
run_remote "sudo systemctl disable --now bitcraft-mirror.service bitcraft-mirror-ram-guard.service 2>/dev/null || true; \
    systemctl is-active bitcraft-mirror.service 2>/dev/null || echo 'green stopped'"

echo "== 4/7: restore coordinator drop-in; restart (sequencer ON → blue instances start) =="
if [ -n "$BACKUP_DIR" ]; then
    run_remote "sudo rm -rf /etc/systemd/system/relay-coordinator.service.d && \
        sudo cp -a ${BACKUP_DIR}/dropins/relay-coordinator.service.d /etc/systemd/system/ 2>/dev/null || true; \
        sudo systemctl daemon-reload && \
        sudo systemctl restart relay-coordinator.service && sleep 2 && \
        systemctl is-active relay-coordinator.service"
else
    echo "(dry-run: drop-in restore from the resolved bundle happens at apply time)"
    run_remote "sudo systemctl restart relay-coordinator.service"
fi

echo "== 5/7: ensure relay-cache enabled + running =="
run_remote "sudo systemctl enable relay-cache.service 2>/dev/null || true; \
    sudo systemctl start relay-cache.service 2>/dev/null || true; \
    systemctl is-active relay-cache.service"

echo "== 6/7: advisory waits (regions serve as they finish seeding) =="
echo "-- per-region: bitcraft-live-global :3030, bitcraft-live-N :\$((3030+N))"
run_remote "for db in \$(sed '/^[[:space:]]*#/d;/^[[:space:]]*\$/d' ${RELAY_BITCRAFT_DIR}/tools/public-mirror.instances); do \
        case \$db in \
            bitcraft-live-global) p=3030 ;; \
            *) p=\$((3030 + \${db##*-})) ;; \
        esac; \
        echo \"-- waiting \$db on :\$p\"; \
        sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-mirrors-live.sh \
            http://127.0.0.1:\$p/v1/mirrors 1 900 10 || echo \"WARN: \$db not live yet — sequencer may still be working; check fleet-status\"; \
    done" || true
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-cache-ready.sh \
    http://127.0.0.1:8089/cache-health 600 5" || echo "WARN: blue cache not ready yet — it resyncs as regions come back"

echo "== 7/7: verify =="
run_remote "curl -sf http://127.0.0.1:8089/cache-health | head -c 300; echo"
run_remote "curl -sf https://relay.bitcraftsync.app/cache-health | head -c 200; echo"
run_remote "curl -sf 'https://relay.bitcraftsync.app:3014/v1/database/bitcraft-live-14/schema?version=9' | head -c 120; echo"
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/fleet-status.sh | head -25 || true"

echo
echo "Rollback complete — blue (per-instance fleet + standalone cache) serves again."
echo "Re-run the cutover any time (idempotent):"
echo "  ${HERE}/cutover-to-bitcraft-mirror.sh --apply"
if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run complete. Re-run with --apply to execute."
fi
