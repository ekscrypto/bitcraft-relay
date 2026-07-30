#!/bin/sh
# public-mirror-stop-all.sh — stop every instance in public-mirror.instances.
#
# Used before a fresh fleet bootstrap (deploy / relay-fleet-start) so the
# coordinator sequencer can cold-start regions one at a time.

set -eu

INSTANCES_FILE="${INSTANCES_FILE:-/srv/relay/bitcraft-relay/tools/public-mirror.instances}"

if [ ! -f "$INSTANCES_FILE" ]; then
    echo "public-mirror-stop-all: missing $INSTANCES_FILE" >&2
    exit 1
fi

while IFS= read -r line || [ -n "$line" ]; do
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    unit="public-mirror@${line}.service"
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        echo "public-mirror-stop-all: stopping $unit"
        systemctl stop "$unit" || true
    fi
done < "$INSTANCES_FILE"
