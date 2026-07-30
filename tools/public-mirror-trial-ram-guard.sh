#!/bin/sh
# public-mirror-trial-ram-guard.sh — stop the trial mirror when free RAM is low.
#
# Uses MemAvailable from /proc/meminfo (same signal the kernel OOM logic uses).
# Polls every TRIAL_RAM_GUARD_INTERVAL seconds (default 2). When MemAvailable
# drops below TRIAL_RAM_MIN_FREE_KB (default 1 GiB), stops public-mirror-trial.service
# immediately and keeps watching so a manual restart cannot run while RAM stays low.
#
# Intended to run under public-mirror-trial-ram-guard.service.

set -eu

UNIT="${TRIAL_RAM_GUARD_UNIT:-public-mirror-trial.service}"
MIN_FREE_KB="${TRIAL_RAM_MIN_FREE_KB:-1048576}"  # 1 GiB
INTERVAL="${TRIAL_RAM_GUARD_INTERVAL:-2}"
TAG=public-mirror-trial-ram-guard

mem_available_kb() {
    awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
}

trial_active() {
    systemctl is-active --quiet "$UNIT" 2>/dev/null
}

log() {
    logger -t "$TAG" "$*"
    printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

log "watching MemAvailable >= ${MIN_FREE_KB}KiB (interval ${INTERVAL}s) for ${UNIT}"

while :; do
    avail=$(mem_available_kb)
    if [ -z "$avail" ]; then
        log "WARN: could not read MemAvailable"
        sleep "$INTERVAL"
        continue
    fi

    if [ "$avail" -lt "$MIN_FREE_KB" ]; then
        if trial_active; then
            log "CRITICAL: MemAvailable=${avail}KiB < ${MIN_FREE_KB}KiB — stopping ${UNIT}"
            systemctl stop "$UNIT"
            log "stopped ${UNIT}; production public-mirror unchanged"
        fi
    fi

    sleep "$INTERVAL"
done
