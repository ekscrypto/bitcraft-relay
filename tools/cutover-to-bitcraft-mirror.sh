#!/bin/sh
# cutover-to-bitcraft-mirror.sh — switch production from the per-instance
# public-mirror@*.service fleet + standalone relay-cache to the ONE-process
# spacetimedb-bitcraft-mirror (mirror + embedded read cache).
#
# Blue/green with warm standby:
#   green = bitcraft-mirror.service  — 127.0.0.1:3100 (WS), :3130 (status
#           sidecar), :8090 (embedded cache). Never binds a blue port.
#   blue  = public-mirror@bitcraft-live-N.service instances + relay-cache
#           on :8089. The WARM set keeps serving through green's seed and
#           the soak, making rollback an nginx flip + instance starts.
#
# Usage (run from anywhere; sources tools/relay-env.local.sh):
#   cutover-to-bitcraft-mirror.sh --prepare-only --apply
#       Zero-impact prep: sync bitcraft-relay + the fork to the host, build
#       spacetimedb-standalone there (throttled -j4 by default), install the
#       green unit DISABLED, daemon-reload, take the backup bundle, reset the
#       stale relay-fleet-sequencer failed state. Production untouched.
#   cutover-to-bitcraft-mirror.sh            # dry-run the real cutover
#   cutover-to-bitcraft-mirror.sh --apply    # execute it
#
# Full cutover (each step numbered in the output):
#   1/8 backup bundle to /srv/relay/backups/bitcraft-mirror-cutover-$TS/
#       (units, drop-ins, instances list, nginx config + nginx -T dump,
#        manifest of unit states/ports/checksums, cutover state)
#   2/8 install green units (bitcraft-mirror.service + ram-guard)
#   3/8 coordinator: fleet sequencer OFF (cannot resurrect stopped blue)
#   4/8 stop COLD blue instances (warm set + relay-cache keep running);
#       RAM gate: abort unless MemAvailable >= 16 GiB
#   5/8 start green; wait 14/14 live on :3130 and cache ready on :8090
#   6/8 nginx flip (3000–3025 → :3100, cache → :8090) via
#       nginx-flip-bitcraft-mirror.sh up; nginx -t guards the reload
#   7/8 coordinator /health → green sidecar :3130 (dashboard keeps working)
#   8/8 verify (loopback + public), print decommission + rollback commands
#
# Failure before step 6: blue still serves everything except cold-region WS;
# re-run (idempotent) or roll back (rollback-from-bitcraft-mirror.sh).
# Failure after step 6: rollback flips nginx back to warm blue in seconds.
#
# Knobs (environment): WARM_REGIONS (default "global 7 8 12 19"),
# REGIONS (default full production set), RELAY_CARGO_ARGS (prepare build;
# default -j4), CUTOVER_WAIT_TIMEOUT (default 3600s), plus everything
# relay-env.local.sh sets. --no-warm-standby stops ALL blue instances
# (maximum RAM headroom; rollback re-seeds every region progressively).
#
# Rollback: rollback-from-bitcraft-mirror.sh [--backup-dir <bundle>]

set -u

HERE=$(cd "$(dirname "$0")" && pwd)
BITCRAFT_ROOT=$(cd "$HERE/.." && pwd)
ENV_FILE="${BITCRAFT_ROOT}/../tools/relay-env.local.sh"

APPLY=0
PREPARE_ONLY=0
NO_WARM=0
WARM_REGIONS="${WARM_REGIONS:-global 7 8 12 19}"
while [ $# -gt 0 ]; do
    case "$1" in
        --apply)    APPLY=1 ;;
        --prepare-only) PREPARE_ONLY=1 ;;
        --no-warm-standby) NO_WARM=1 ;;
        --warm-regions) WARM_REGIONS="$2"; shift ;;
        -h|--help)  sed -n '2,40p' "$0"; exit 0 ;;
        *) echo "cutover-to-bitcraft-mirror.sh: unknown argument: $1" >&2; exit 2 ;;
    esac
    shift
done
[ "$NO_WARM" -eq 1 ] && WARM_REGIONS=""

RELAY_HOST="${RELAY_HOST:-relay.bitcraftsync.app}"
RELAY_SSH_USER="${RELAY_SSH_USER:-debian}"
RELAY_SERVICE_USER="${RELAY_SERVICE_USER:-relay}"
RELAY_BITCRAFT_DIR="${RELAY_BITCRAFT_DIR:-/srv/relay/bitcraft-relay}"
RELAY_BITCRAFT_MIRROR_DIR="${RELAY_BITCRAFT_MIRROR_DIR:-/srv/relay/spacetimedb-bitcraft-mirror}"
if [ -f "$ENV_FILE" ]; then
    # shellcheck disable=SC1090
    . "$ENV_FILE"
fi
SSH_TARGET="${RELAY_SSH:-${RELAY_SSH_USER}@${RELAY_HOST}}"

REGIONS="${REGIONS:-global 3 7 8 9 11 12 13 14 15 17 18 19 23}"
GREEN_WS_PORT="${GREEN_WS_PORT:-3100}"
GREEN_STATUS_PORT="${GREEN_STATUS_PORT:-3130}"
GREEN_CACHE_PORT="${GREEN_CACHE_PORT:-8090}"
BLUE_CACHE_PORT="${BLUE_CACHE_PORT:-8089}"
# 7200s: seeding is fully serialized (one mirror at a time via the subscribe
# gate, one table at a time via seed pacing) — see MULTI-MIRROR-UPSTREAM-
# RESETS.md — so a cold start can take well over an hour on the 4-core host.
CUTOVER_WAIT_TIMEOUT="${CUTOVER_WAIT_TIMEOUT:-7200}"
CARGO_ARGS="${RELAY_CARGO_ARGS:--j4}"
UPSTREAM_BASE="${UPSTREAM_BASE:-wss://bitcraft-early-access.spacetimedb.com}"

db_for() {
    case "$1" in
        global) echo "bitcraft-live-global" ;;
        bitcraft-live-*) echo "$1" ;;
        *) echo "bitcraft-live-$1" ;;
    esac
}

COLD_REGIONS=""
for r in $REGIONS; do
    case " $WARM_REGIONS " in
        *" $r "*) ;;
        *) COLD_REGIONS="$COLD_REGIONS $r" ;;
    esac
done

warm_units=""
for r in $WARM_REGIONS; do
    warm_units="$warm_units public-mirror@$(db_for "$r").service"
done
cold_units=""
for r in $COLD_REGIONS; do
    cold_units="$cold_units public-mirror@$(db_for "$r").service"
done

TS=$(date +%Y%m%d-%H%M%S)
BUNDLE="/srv/relay/backups/bitcraft-mirror-cutover-$TS"

run_local() {
    if [ "$APPLY" -eq 1 ]; then "$@"; else printf '$ %s\n' "$*"; fi
}

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH_TARGET" "$@" || exit $?
    else
        printf '$ ssh %s %s\n' "$SSH_TARGET" "$*"
    fi
}

rsync_repo() {
    src="$1"; dst="$2"
    run_local rsync -av --rsync-path='sudo rsync' \
        --exclude target/ --exclude .git/ --exclude .zcode/ \
        --exclude .claude/ --exclude '*.bak-*' --exclude '._*' --exclude '.DS_Store' \
        "$src" "${SSH_TARGET}:${dst}/"
    run_remote "sudo chown -R ${RELAY_SERVICE_USER}:${RELAY_SERVICE_USER} ${dst}"
}

echo "cutover-to-bitcraft-mirror.sh — target ${SSH_TARGET}"
echo "  green : bitcraft-mirror.service  ws :${GREEN_WS_PORT}  status :${GREEN_STATUS_PORT}  cache :${GREEN_CACHE_PORT}"
echo "  warm  : ${WARM_REGIONS:-<none — full stop>}"
echo "  cold  : ${COLD_REGIONS}"
echo "  bundle: ${BUNDLE}"
[ "$APPLY" -eq 0 ] && echo "DRY-RUN (add --apply to execute)."
echo

# --- shared step: backup bundle -------------------------------------------
backup_bundle() {
    echo "== backup bundle → ${BUNDLE} =="
    run_remote "sudo mkdir -p ${BUNDLE}/units ${BUNDLE}/dropins ${BUNDLE}/nginx && \
        sudo cp /etc/systemd/system/public-mirror@.service ${BUNDLE}/units/ 2>/dev/null || true; \
        sudo cp /etc/systemd/system/public-mirror.target ${BUNDLE}/units/ 2>/dev/null || true; \
        sudo cp /etc/systemd/system/public-mirror.service ${BUNDLE}/units/ 2>/dev/null || true; \
        sudo cp /etc/systemd/system/relay-cache.service ${BUNDLE}/units/; \
        sudo cp /etc/systemd/system/relay-coordinator.service ${BUNDLE}/units/; \
        sudo cp ${RELAY_BITCRAFT_DIR}/tools/public-mirror.instances ${BUNDLE}/units/; \
        sudo cp -a /etc/systemd/system/relay-cache.service.d ${BUNDLE}/dropins/ 2>/dev/null || true; \
        sudo cp -a /etc/systemd/system/relay-coordinator.service.d ${BUNDLE}/dropins/ 2>/dev/null || true; \
        sudo sh -c 'nginx -T > ${BUNDLE}/nginx/nginx-full-T.conf 2>/dev/null || true'; \
        sudo sh -c 'for f in \$(grep -rl \"proxy_pass http://127.0.0.1:\$server_port\" /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d 2>/dev/null | grep -v \"\\.bak\"); do \
            sudo cp \"\$f\" \"${BUNDLE}/nginx/\$(echo \"\$f\" | tr / _)\"; \
            echo \"\$f\" >> \"${BUNDLE}/nginx/paths.txt\"; \
        done'; \
        sudo sh -c '{ \
            echo \"# bitcraft-mirror cutover backup bundle\"; \
            echo \"date: \$(date -Is)\"; \
            echo \"warm: ${WARM_REGIONS}\"; \
            echo \"cold: ${COLD_REGIONS}\"; \
            echo \"green: ws=:${GREEN_WS_PORT} status=:${GREEN_STATUS_PORT} cache=:${GREEN_CACHE_PORT}\"; \
            echo; echo \"## unit states\"; \
            for u in public-mirror@.service public-mirror.target public-mirror.service relay-cache.service relay-coordinator.service bitcraft-mirror.service; do \
                printf \"%-36s enabled=%-8s active=%s\n\" \"\$u\" \"\$(systemctl is-enabled \$u 2>/dev/null || echo n/a)\" \"\$(systemctl is-active \$u 2>/dev/null || echo n/a)\"; \
            done; \
            echo; echo \"## listening ports\"; ss -ltn; \
            echo; echo \"## nginx files (see nginx/paths.txt)\"; \
            echo; echo \"## sha256\"; sha256sum ${BUNDLE}/units/* ${BUNDLE}/dropins/*/* ${BUNDLE}/nginx/* 2>/dev/null || true; \
        } > ${BUNDLE}/manifest.txt'; \
        sudo ls -laR ${BUNDLE}"
}

install_green_units() {
    echo "== install green units (bitcraft-mirror.service + ram-guard + page-pins) =="
    # The page-pin units vmtouch-mlock the green and blue binaries + libs in
    # RAM (attempt #4: text-page faults starve behind HDD writeback drains).
    # Restarting the green pin here picks up a freshly built binary inode;
    # the units stay enabled across reboots and across rollbacks — they
    # protect instance restarts/re-seeds in BOTH topologies.
    run_remote "sudo cp ${RELAY_BITCRAFT_DIR}/tools/bitcraft-mirror.service /etc/systemd/system/ && \
        sudo cp ${RELAY_BITCRAFT_DIR}/tools/bitcraft-mirror-ram-guard.service /etc/systemd/system/ && \
        sudo cp ${RELAY_BITCRAFT_DIR}/tools/relay-pin-bitcraft-mirror.service \
            ${RELAY_BITCRAFT_DIR}/tools/relay-pin-public-mirror.service /etc/systemd/system/ && \
        sudo chmod +x ${RELAY_BITCRAFT_DIR}/tools/bitcraft-mirror-ram-guard.sh \
            ${RELAY_BITCRAFT_DIR}/tools/nginx-flip-bitcraft-mirror.sh \
            ${RELAY_BITCRAFT_DIR}/tools/wait-mirrors-live.sh \
            ${RELAY_BITCRAFT_DIR}/tools/wait-cache-ready.sh \
            ${RELAY_BITCRAFT_DIR}/tools/relay-pin-pages.sh && \
        sudo systemctl daemon-reload && \
        sudo systemctl enable --now relay-pin-bitcraft-mirror.service relay-pin-public-mirror.service && \
        sudo systemctl restart relay-pin-bitcraft-mirror.service && \
        systemctl is-enabled bitcraft-mirror.service 2>/dev/null || echo 'bitcraft-mirror.service installed (not enabled yet)'"
}

# --- prepare-only mode ------------------------------------------------------
if [ "$PREPARE_ONLY" -eq 1 ]; then
    echo "== 1/4: sync bitcraft-relay (units, flip + wait helpers) → ${RELAY_BITCRAFT_DIR} =="
    rsync_repo "$BITCRAFT_ROOT/" "$RELAY_BITCRAFT_DIR"

    echo "== 2/4: sync spacetimedb-bitcraft-mirror → ${RELAY_BITCRAFT_MIRROR_DIR} =="
    rsync_repo "${BITCRAFT_ROOT}/../spacetimedb-bitcraft-mirror/" "$RELAY_BITCRAFT_MIRROR_DIR"

    echo "== 3/4: build spacetimedb-standalone on host (cargo ${CARGO_ARGS}; first build ~30–60 min) =="
    run_remote "sudo -u ${RELAY_SERVICE_USER} bash -lc 'cd ${RELAY_BITCRAFT_MIRROR_DIR} && cargo build --release -p spacetimedb-standalone ${CARGO_ARGS}'"

    install_green_units
    backup_bundle

    echo "== 4/4: clear stale failed state (cosmetic) =="
    run_remote "sudo systemctl reset-failed relay-fleet-sequencer.service 2>/dev/null || true"

    echo
    echo "Prepare complete (production untouched). Verify the binary:"
    echo "  ssh ${SSH_TARGET} 'ls -la ${RELAY_BITCRAFT_MIRROR_DIR}/target/release/spacetimedb-standalone'"
    echo "Next — review then execute the cutover:"
    echo "  ${HERE}/cutover-to-bitcraft-mirror.sh            # dry-run"
    echo "  ${HERE}/cutover-to-bitcraft-mirror.sh --apply    # execute"
    echo "Roll back any time with:"
    echo "  ${HERE}/rollback-from-bitcraft-mirror.sh --apply"
    if [ "$APPLY" -eq 0 ]; then
        echo
        echo "Dry-run complete. Re-run with --apply to execute."
    fi
    exit 0
fi

# --- full cutover -----------------------------------------------------------

echo "== 0/8: preflight =="
run_remote "test -x ${RELAY_BITCRAFT_MIRROR_DIR}/target/release/spacetimedb-standalone || { \
        echo 'green binary missing — run cutover-to-bitcraft-mirror.sh --prepare-only --apply first' >&2; exit 1; }"
run_remote "if ss -ltn | grep -qE ':((${GREEN_WS_PORT}|${GREEN_STATUS_PORT}|${GREEN_CACHE_PORT})) '; then \
        echo 'green port already in use — another green running?' >&2; ss -ltn | grep -E ':((${GREEN_WS_PORT}|${GREEN_STATUS_PORT}|${GREEN_CACHE_PORT})) '; exit 1; \
    fi; echo 'preflight OK: binary present, green ports free'"
run_remote "curl -sf http://127.0.0.1:${BLUE_CACHE_PORT}/cache-health >/dev/null && echo 'blue cache healthy' || { \
        echo 'blue relay-cache NOT healthy — fix before cutover' >&2; exit 1; }"

backup_bundle
install_green_units

echo "== 3/8: coordinator — fleet sequencer OFF (keep current mirrors URL for now) =="
run_remote "sudo sh -c 'old=\$(grep -h \"^Environment=RELAY_MIRRORS_URL=\" /etc/systemd/system/relay-coordinator.service.d/*.conf 2>/dev/null || true); \
        { echo \"[Service]\"; echo \"Environment=RELAY_FLEET_SEQUENCER=false\"; printf \"%s\n\" \"\$old\"; } \
        > /etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf' && \
    sudo systemctl daemon-reload && \
    sudo systemctl restart relay-coordinator.service && \
    sleep 2 && systemctl is-active relay-coordinator.service"

if [ -n "$cold_units" ]; then
    echo "== 4/8: stop cold blue instances: ${cold_units} =="
    run_remote "sudo systemctl stop${cold_units}"
else
    echo "== 4/8: no cold instances (--no-warm-standby not set, everything warm?) =="
fi

echo "== 4/8: RAM gate — need MemAvailable >= 16 GiB for green =="
run_remote "avail=\$(awk '/^MemAvailable:/ {print \$2}' /proc/meminfo); \
    echo \"MemAvailable: \$((avail/1024)) MiB\"; \
    [ \"\$avail\" -ge 16777216 ] || { echo 'NOT enough headroom — rolling nothing back automatically; warm blue intact. Free memory or widen the warm set down (fewer warm regions) and re-run.' >&2; exit 1; }"

echo "== 5/8: start green + wait for 14/14 live (timeout ${CUTOVER_WAIT_TIMEOUT}s) =="
# Best-effort telemetry (CPU/iowait split, disk, green's own CPU+IO) so the
# attempt is diagnosable even if it rolls back — see MULTI-MIRROR-UPSTREAM-
# RESETS.md. Never blocks the cutover.
run_remote "sudo test -x ${RELAY_BITCRAFT_DIR}/tools/cutover-telemetry-capture.sh && \
    sudo ${RELAY_BITCRAFT_DIR}/tools/cutover-telemetry-capture.sh start || \
    echo 'telemetry capture not started (continuing)'"
run_remote "sudo systemctl enable --now relay-pin-bitcraft-mirror.service bitcraft-mirror.service bitcraft-mirror-ram-guard.service && sleep 5 && \
    systemctl is-active bitcraft-mirror.service"
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-mirrors-live.sh \
    http://127.0.0.1:${GREEN_STATUS_PORT}/v1/mirrors 14 ${CUTOVER_WAIT_TIMEOUT} 10" || {
    echo
    echo "############################################################" >&2
    echo "# green did NOT come up. nginx still points at blue." >&2
    if [ -n "$warm_units" ]; then
        echo "# Blue state: warm instances + relay-cache still running —" >&2
        echo "# those regions and the cache API still serve. Cold-region WS is down." >&2
    else
        echo "# Blue state: ENTIRELY STOPPED — service is DOWN until green" >&2
        echo "# comes up or rollback finishes re-seeding blue (~15–45 min," >&2
        echo "# regions return progressively)." >&2
    fi
    echo "# Inspect: ssh ${SSH_TARGET} 'journalctl -u bitcraft-mirror.service -n 50'" >&2
    echo "# Re-run this script (idempotent) to retry green, or roll back:" >&2
    echo "#   ${HERE}/rollback-from-bitcraft-mirror.sh --apply" >&2
    echo "############################################################" >&2
    exit 1
}
run_remote "sudo -u ${RELAY_SERVICE_USER} ${RELAY_BITCRAFT_DIR}/tools/wait-cache-ready.sh \
    http://127.0.0.1:${GREEN_CACHE_PORT}/cache-health 600 5"

echo "== 6/8: nginx flip → green (WS band → :${GREEN_WS_PORT}, cache → :${GREEN_CACHE_PORT}) =="
run_remote "sudo ${RELAY_BITCRAFT_DIR}/tools/nginx-flip-bitcraft-mirror.sh up"

echo "== 7/8: coordinator /health → green sidecar =="
run_remote "sudo sh -c 'printf \"[Service]\nEnvironment=RELAY_FLEET_SEQUENCER=false\nEnvironment=RELAY_MIRRORS_URL=http://127.0.0.1:${GREEN_STATUS_PORT}/v1/mirrors\n\" \
        > /etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf' && \
    sudo systemctl daemon-reload && \
    sudo systemctl restart relay-coordinator.service && \
    sleep 2 && curl -sf http://127.0.0.1:8082/health | head -c 300; echo"

echo "== 8/8: verify =="
echo "-- green status sidecar (:${GREEN_STATUS_PORT})"
run_remote "curl -sf http://127.0.0.1:${GREEN_STATUS_PORT}/v1/mirrors | head -c 300; echo"
echo "-- green cache (:${GREEN_CACHE_PORT})"
run_remote "curl -sf http://127.0.0.1:${GREEN_CACHE_PORT}/cache-health | head -c 300; echo"
if [ -n "$warm_units" ]; then
    echo "-- warm blue standby still active"
    run_remote "systemctl is-active${warm_units}"
fi
echo "-- public endpoints (through nginx → green)"
run_remote "curl -sf https://relay.bitcraftsync.app/cache-health | head -c 200; echo"
run_remote "curl -sf 'https://relay.bitcraftsync.app:3014/v1/database/bitcraft-live-14/schema?version=9' | head -c 120; echo"
run_remote "curl -sf https://relay.bitcraftsync.app/health | head -c 200; echo"

echo
echo "Cutover complete. Green (one-process mirror + embedded cache) serves everything."
if [ -n "$warm_units" ]; then
    echo "Blue warm standby + relay-cache idle for instant rollback (decommission when satisfied)."
    echo "  Decommission blue: ${HERE}/decommission-public-mirror-fleet.sh --apply"
else
    echo "Blue is fully stopped. relay-cache still runs (stale, unused) — stop it via:"
    echo "  ${HERE}/decommission-public-mirror-fleet.sh --apply"
fi
echo
echo "Roll back (re-seeds blue progressively, ~15–45 min):"
echo "  ${HERE}/rollback-from-bitcraft-mirror.sh --apply --backup-dir ${BUNDLE}"
if [ "$APPLY" -eq 0 ]; then
    echo
    echo "Dry-run complete. Re-run with --apply to execute."
fi
