#!/bin/sh
# public-mirror-trial-status.sh — one-line status for the trial mirror fleet.
#
# Polls GET http://127.0.0.1:3030/v1/mirrors (regions 7 and 8 only).
# Does not touch production /v1/mirrors on :3000.
#
# Usage:
#   ./tools/public-mirror-trial-status.sh
#   ./tools/public-mirror-trial-status.sh -w

set -eu

MIRRORS_URL="${TRIAL_MIRRORS_URL:-http://127.0.0.1:3031/v1/mirrors}"
INTERVAL="${TRIAL_INTERVAL:-5}"

print_once() {
    json=$(curl -sf --max-time 5 "$MIRRORS_URL" 2>/dev/null || true)
    if [ -z "$json" ]; then
        echo "trial: ${MIRRORS_URL} unreachable (is public-mirror-trial.service running?)"
        return 1
    fi
    printf '%s\n' "$json" | python3 <<'PY'
import json, sys
d = json.load(sys.stdin)
mirrors = d.get("mirrors") or []
print(f"{'DATABASE':<22} {'CONNECTIVITY':<12} {'TABLES':<12} NOTES")
for m in sorted(mirrors, key=lambda x: x.get("database") or ""):
    db = m.get("database", "?")
    conn = m.get("connectivity", "?")
    tl = m.get("tables_live")
    tt = m.get("tables_total")
    tables = f"{tl}/{tt}" if tl is not None and tt is not None else "-"
    notes = []
    if m.get("last_disconnect_reason"):
        notes.append(str(m["last_disconnect_reason"])[:60])
    print(f"{db:<22} {conn:<12} {tables:<12} {', '.join(notes)}")
want = {"bitcraft-live-7", "bitcraft-live-8"}
have = {m.get("database") for m in mirrors}
missing = want - have
if missing:
    print("missing:", ", ".join(sorted(missing)))
PY
}

if [ "${1:-}" = "-w" ] || [ "${1:-}" = "--watch" ]; then
    while :; do
        clear 2>/dev/null || true
        echo "public-mirror trial — $(date '+%Y-%m-%d %H:%M:%S')  (${MIRRORS_URL})"
        echo
        print_once || true
        sleep "$INTERVAL"
    done
else
    print_once
fi
