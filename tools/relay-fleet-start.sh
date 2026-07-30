#!/bin/sh
# relay-fleet-start.sh — start public-mirror and wait until mirrors are live.
#
# Thin wrapper around `systemctl start public-mirror.service`. The old
# sequential per-relay start (relay-global, then relay-bc* by ascending
# region ID) is retired: one public-mirror process mirrors every region,
# so there is no thundering-herd / overlapping-codegen concern to
# serialize.
#
# Behavior:
#   1. systemctl start public-mirror.service (idempotent if already active).
#   2. Poll GET /v1/mirrors until every reported mirror has
#      connectivity=live, or until timeout.
#   3. Non-zero exit on timeout or unreachable endpoint after timeout.
#
# The old relay-bc* / relay-global / relay-fleet-sequencer units are
# retired — do not start them. Prefer this script (or
# `systemctl start public-mirror.service` directly).
#
# Env knobs (defaults shown):
#   MIRRORS_URL=http://127.0.0.1:3000/v1/mirrors
#   FLEET_READY_SECS=600          overall wait budget
#   FLEET_POLL_SECS=5             poll interval
#   FLEET_CURL_TIMEOUT=4          per-fetch timeout
#   FLEET_MIN_MIRRORS=1           require at least this many mirrors
#                                 before treating an all-live snapshot
#                                 as success (guards empty early responses)
#
# Requires: curl, python3, systemctl. No write side effects beyond
# `systemctl start`.

set -u

MIRRORS_URL="${MIRRORS_URL:-http://127.0.0.1:3030/v1/mirrors}"
READY_SECS="${FLEET_READY_SECS:-600}"
POLL_SECS="${FLEET_POLL_SECS:-5}"
CURL_TIMEOUT="${FLEET_CURL_TIMEOUT:-4}"
MIN_MIRRORS="${FLEET_MIN_MIRRORS:-1}"
UNIT=public-mirror.service

log() { echo "relay-fleet-start: $*"; }

# Returns 0 if /v1/mirrors reports >= MIN_MIRRORS entries and every one
# is connectivity=live. Prints a short status summary on stdout.
mirrors_all_live() {
    json=$(curl -sS --max-time "$CURL_TIMEOUT" "$MIRRORS_URL" 2>/dev/null || true)
    if [ -z "$json" ]; then
        echo "unreachable"
        return 1
    fi
    printf '%s' "$json" | MIN_MIRRORS="$MIN_MIRRORS" python3 -c '
import json, os, sys
min_n = int(os.environ.get("MIN_MIRRORS") or "1")
try:
    d = json.load(sys.stdin)
except Exception:
    print("parse_error")
    raise SystemExit(1)
mirrors = d.get("mirrors") or []
n = len(mirrors)
if n < min_n:
    print("waiting count=%d need>=%d" % (n, min_n))
    raise SystemExit(1)
not_live = []
for m in mirrors:
    conn = m.get("connectivity") or "?"
    db = m.get("database") or "?"
    if conn != "live":
        not_live.append("%s=%s" % (db, conn))
if not_live:
    # Cap the summary so the log line stays readable.
    shown = not_live[:6]
    extra = "" if len(not_live) <= 6 else " (+%d more)" % (len(not_live) - 6)
    print("partial live=%d/%d pending=%s%s" % (
        n - len(not_live), n, ",".join(shown), extra))
    raise SystemExit(1)
print("all %d mirrors live" % n)
raise SystemExit(0)
'
}

# --- main ---

log "starting $UNIT (legacy relay-bc* / relay-global units are retired)"
systemctl start "$UNIT" 2>&1 | sed 's/^/  /'
rc=$?
if [ "$rc" -ne 0 ]; then
    log "ERROR: systemctl start $UNIT failed (exit $rc)"
    exit 1
fi

log "waiting up to ${READY_SECS}s for all mirrors live at $MIRRORS_URL (min_mirrors=$MIN_MIRRORS)…"
elapsed=0
last_status=""
while [ "$elapsed" -lt "$READY_SECS" ]; do
    status=$(mirrors_all_live 2>/dev/null) && {
        log "ready after ${elapsed}s: $status"
        exit 0
    }
    status=${status:-unreachable}
    if [ "$status" != "$last_status" ]; then
        log "  ${elapsed}s: $status"
        last_status=$status
    fi
    sleep "$POLL_SECS"
    elapsed=$((elapsed + POLL_SECS))
done

log "TIMEOUT after ${READY_SECS}s (last: ${last_status:-unknown})"
exit 1
