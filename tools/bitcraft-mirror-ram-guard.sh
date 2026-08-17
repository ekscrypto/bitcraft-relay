#!/bin/sh
# bitcraft-mirror-ram-guard.sh — stop the one-process bitcraft-mirror when
# free RAM is low.
#
# Uses MemAvailable from /proc/meminfo (same signal the kernel OOM logic
# uses). Polls every BITCRAFT_MIRROR_RAM_GUARD_INTERVAL seconds (default 2).
# When MemAvailable drops below BITCRAFT_MIRROR_RAM_MIN_FREE_KB (default
# 2 GiB — during blue/green overlap green must not OOM the warm blue
# standby), stops bitcraft-mirror.service immediately and keeps watching so a
# manual restart cannot run while RAM stays low.
#
# Intended to run under bitcraft-mirror-ram-guard.service.

set -eu

UNIT="${BITCRAFT_MIRROR_RAM_GUARD_UNIT:-bitcraft-mirror.service}"
MIN_FREE_KB="${BITCRAFT_MIRROR_RAM_MIN_FREE_KB:-2097152}"  # 2 GiB
INTERVAL="${BITCRAFT_MIRROR_RAM_GUARD_INTERVAL:-2}"
TAG=bitcraft-mirror-ram-guard

mem_available_kb() {
    awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo
}

mirror_active() {
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
        if mirror_active; then
            log "CRITICAL: MemAvailable=${avail}KiB < ${MIN_FREE_KB}KiB — stopping ${UNIT}"
            systemctl stop "$UNIT"
            log "stopped ${UNIT}; flip nginx back (rollback script) to serve blue"
        fi
    fi

    sleep "$INTERVAL"
done
