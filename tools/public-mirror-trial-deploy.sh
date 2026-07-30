#!/bin/sh
# public-mirror-trial-deploy.sh — install and run an isolated trial mirror.
#
# Syncs only the trial systemd unit (+ optional binary build). Does NOT:
#   - restart public-mirror.service / public-mirror.target
#   - restart relay-cache.service or relay-coordinator.service
#   - modify nginx ports 3000–3025
#
# Usage (on operator laptop, from workspace root):
#   ./bitcraft-relay/tools/public-mirror-trial-deploy.sh              # dry-run
#   ./bitcraft-relay/tools/public-mirror-trial-deploy.sh --apply      # install + start
#   ./bitcraft-relay/tools/public-mirror-trial-deploy.sh --apply --build  # rsync source + cargo build first
#   ./bitcraft-relay/tools/public-mirror-trial-deploy.sh --apply --stop   # stop trial only
#   ./bitcraft-relay/tools/public-mirror-trial-deploy.sh --apply --no-wait # skip mirror readiness poll
#
# Requires tools/relay-env.local.sh (same as deploy.sh).

set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
ENV_FILE="$ROOT/tools/relay-env.local.sh"

RELAY_HOST="relay.bitcraftsync.app"
RELAY_SSH_USER="debian"
RELAY_SERVICE_USER="relay"
RELAY_MIRROR_DIR="/srv/relay/spacetimedb-public-mirror"
RELAY_BITCRAFT_DIR="/srv/relay/bitcraft-relay"
RELAY_CARGO_ARGS=""

if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
else
    echo "public-mirror-trial-deploy.sh: $ENV_FILE not found." >&2
    exit 2
fi

SSH_TARGET="${RELAY_SSH_USER}@${RELAY_HOST}"
UNIT=public-mirror-trial.service
GUARD_UNIT=public-mirror-trial-ram-guard.service
TRIAL_LOOPBACK="127.0.0.1:3030"
MIRRORS_URL="http://${TRIAL_LOOPBACK}/v1/mirrors"

APPLY=0
DO_BUILD=0
DO_STOP=0
NO_WAIT=0
MIN_FREE_KB=2097152  # 2 GiB — matches RAM guard

usage() {
    sed -n '2,16p' "$0"
    exit 2
}

for arg in "$@"; do
    case "$arg" in
        --apply)  APPLY=1 ;;
        --build)  DO_BUILD=1 ;;
        --stop)   DO_STOP=1 ;;
        --no-wait) NO_WAIT=1 ;;
        -h|--help) usage ;;
        *) echo "unknown argument: $arg" >&2; usage ;;
    esac
done

run_local() {
    if [ "$APPLY" -eq 1 ]; then
        "$@"
    else
        printf '$ %s\n' "$*"
    fi
}

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH_TARGET" "$*"
    else
        printf '$ ssh %s %s\n' "$SSH_TARGET" "$*"
    fi
}

rsync_file() {
    src="$1"
    dst="$2"
    run_local rsync -av --rsync-path='sudo rsync' "$src" "${SSH_TARGET}:${dst}"
    run_remote "sudo chown ${RELAY_SERVICE_USER}:${RELAY_SERVICE_USER} ${dst}"
}

echo "target: ${SSH_TARGET}"
echo "trial unit: ${UNIT} (loopback ${TRIAL_LOOPBACK})"
echo "production public-mirror, relay-cache, relay-coordinator: NOT touched"
echo

if [ "$DO_STOP" -eq 1 ]; then
    echo "== trial: stop ${UNIT} + ${GUARD_UNIT} =="
    run_remote "sudo systemctl stop ${GUARD_UNIT} ${UNIT} 2>/dev/null || true"
    run_remote "sudo systemctl disable ${GUARD_UNIT} ${UNIT} 2>/dev/null || true"
    exit 0
fi

if [ "$DO_BUILD" -eq 1 ]; then
    echo "== trial: sync spacetimedb-public-mirror source (no restart of production) =="
    run_local rsync -av --rsync-path='sudo rsync' \
        --exclude target/ --exclude .git/ --exclude .zcode/ \
        --exclude .claude/ --exclude '*.bak-*' --exclude '._*' --exclude '.DS_Store' \
        "$ROOT/spacetimedb-public-mirror/" "${SSH_TARGET}:${RELAY_MIRROR_DIR}/"
    run_remote "sudo chown -R ${RELAY_SERVICE_USER}:${RELAY_SERVICE_USER} ${RELAY_MIRROR_DIR}"
    echo "== trial: build spacetimedb-standalone on host =="
    run_remote "sudo -u ${RELAY_SERVICE_USER} bash -lc 'cd ${RELAY_MIRROR_DIR} && cargo build --release -p spacetimedb-standalone ${RELAY_CARGO_ARGS}'"
fi

echo "== trial: sync tools + install systemd units =="
run_local rsync -av --rsync-path='sudo rsync' \
    "$HERE/public-mirror-trial.service" \
    "$HERE/public-mirror-trial-ram-guard.service" \
    "$HERE/public-mirror-trial-ram-guard.sh" \
    "$HERE/public-mirror-trial-status.sh" \
    "${SSH_TARGET}:${RELAY_BITCRAFT_DIR}/tools/"
run_remote "sudo cp ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial.service /etc/systemd/system/${UNIT} && \
    sudo cp ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial-ram-guard.service /etc/systemd/system/${GUARD_UNIT} && \
    sudo chmod +x ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial-ram-guard.sh ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial-status.sh && \
    sudo chown -R ${RELAY_SERVICE_USER}:${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools"
run_remote "sudo mkdir -p /var/lib/relay/public-mirror-trial && sudo chown ${RELAY_SERVICE_USER}:${RELAY_SERVICE_USER} /var/lib/relay/public-mirror-trial"
run_remote "sudo systemctl daemon-reload"
run_remote "sudo systemctl enable ${UNIT} ${GUARD_UNIT}"
run_remote "sudo systemctl restart ${UNIT} ${GUARD_UNIT}"
echo "== trial: RAM guard active (stops ${UNIT} if MemAvailable < 2 GiB) =="

if [ "$APPLY" -eq 1 ]; then
    avail=$(ssh "$SSH_TARGET" "awk '/^MemAvailable:/ {print \$2; exit}' /proc/meminfo" 2>/dev/null || echo 0)
    if [ -n "$avail" ] && [ "$avail" -lt "$MIN_FREE_KB" ]; then
        echo "WARN: host MemAvailable=${avail}KiB is already below ${MIN_FREE_KB}KiB; RAM guard may stop trial immediately" >&2
    else
        echo "host MemAvailable: ${avail}KiB (guard threshold ${MIN_FREE_KB}KiB)"
    fi
fi

if [ "$NO_WAIT" -eq 1 ]; then
    echo "== trial: --no-wait set; services started, skipping /v1/mirrors poll =="
    echo "monitor: ssh ${SSH_TARGET} journalctl -u ${UNIT} -f"
    echo "         ssh ${SSH_TARGET} ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial-status.sh -w"
    exit 0
fi

echo "== trial: wait for mirrors (up to 3600s; /v1/mirrors may hang while seeding) =="
if [ "$APPLY" -eq 1 ]; then
    ok=0
    i=0
    while [ "$i" -lt 360 ]; do
        status=$(ssh "$SSH_TARGET" "curl -sf --max-time 60 ${MIRRORS_URL} 2>/dev/null || true" | python3 -c '
import json, sys
raw = sys.stdin.read().strip()
if not raw:
    print("waiting: /v1/mirrors empty or timed out (normal while seeding large tables)")
    raise SystemExit(1)
try:
    d = json.loads(raw)
except json.JSONDecodeError:
    print("waiting: /v1/mirrors returned non-JSON")
    raise SystemExit(1)
mirrors = d.get("mirrors") or []
want = {"bitcraft-live-7", "bitcraft-live-8", "bitcraft-live-9"}
live = {m.get("database") for m in mirrors if m.get("connectivity") == "live"}
if want <= live:
    print("all trial mirrors live:", ", ".join(sorted(want)))
    raise SystemExit(0)
pending = []
for m in mirrors:
    db = m.get("database") or "?"
    conn = m.get("connectivity") or "?"
    tl = m.get("tables_live")
    tt = m.get("tables_total")
    tables = f"{tl}/{tt}" if tl is not None and tt is not None else "-"
    pending.append(f"{db}={conn}({tables})")
missing = sorted(want - {m.get("database") for m in mirrors})
msg = "partial: " + ", ".join(pending[:6])
if missing:
    msg += "; missing: " + ", ".join(missing)
print(msg)
raise SystemExit(1)
' 2>&1) || true
        seed=$(ssh "$SSH_TARGET" "journalctl -u ${UNIT} -n 1 --no-pager 2>/dev/null | tail -1" 2>/dev/null || true)
        [ -n "$seed" ] && printf '  latest: %s\n' "$seed"
        printf '%s\n' "$status"
        if printf '%s' "$status" | grep -q '^all trial mirrors live:'; then
            ok=1
            break
        fi
        i=$((i + 1))
        sleep 10
    done
    if [ "$ok" -ne 1 ]; then
        echo "trial mirrors not all live after 3600s (services are running; seed may still be in progress)." >&2
        echo "monitor: ssh ${SSH_TARGET} journalctl -u ${UNIT} -f" >&2
        echo "         ssh ${SSH_TARGET} ${RELAY_BITCRAFT_DIR}/tools/public-mirror-trial-status.sh -w" >&2
        exit 0
    fi
    ssh "$SSH_TARGET" "curl -s --max-time 60 ${MIRRORS_URL}" | python3 -m json.tool 2>/dev/null || true
else
    printf '$ # (would poll %s until bitcraft-live-7/8/9 are live, up to 3600s)\n' "$MIRRORS_URL"
fi

if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run complete. Re-run with --apply to execute."
fi
