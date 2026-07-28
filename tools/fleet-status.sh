#!/bin/sh
# fleet-status.sh — print a one-line-per-mirror status table from the
# public-mirror process on this host.
#
# Polls GET /v1/mirrors on the single public-mirror listen
# (default http://127.0.0.1:3000/v1/mirrors). Override with MIRRORS_URL.
# The old per-unit relay-bc* / relay-global dashboard scrapes are retired
# — one process serves every region.
#
# Columns: database, connectivity, tables_live/tables_total,
# transactions_processed, next_attempt_eta_secs.
#
# Exit status (one-shot mode only):
#   0  every mirror is connectivity=live AND tables_live==tables_total
#   1  endpoint unreachable, empty fleet, or any mirror not fully live
#      (unless --allow-partial, which always exits 0 after printing)
#
# Usage:
#   ./tools/fleet-status.sh                # one-shot table
#   ./tools/fleet-status.sh --allow-partial
#   ./tools/fleet-status.sh -w             # repeat every 5s until Ctrl-C
#   MIRRORS_URL=http://127.0.0.1:3000/v1/mirrors ./tools/fleet-status.sh
#
# Requires: curl, python3. No write side effects.

set -eu

INTERVAL="${FLEET_INTERVAL:-5}"
MIRRORS_URL="${MIRRORS_URL:-http://127.0.0.1:3000/v1/mirrors}"
CURL_TIMEOUT="${FLEET_CURL_TIMEOUT:-4}"
ALLOW_PARTIAL=0
WATCH=0

for arg in "$@"; do
    case "$arg" in
        -w|--watch)         WATCH=1 ;;
        --allow-partial)    ALLOW_PARTIAL=1 ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "fleet-status: unknown argument: $arg" >&2
            echo "Usage: $0 [-w|--watch] [--allow-partial]" >&2
            exit 2
            ;;
    esac
done

# Fetch /v1/mirrors, print the table, exit 0/1 based on readiness.
# When ALLOW_PARTIAL=1, always exit 0 after printing (used by -w).
emit() {
    json=$(curl -sS --max-time "$CURL_TIMEOUT" "$MIRRORS_URL" 2>/dev/null || true)
    printf '%s' "${json:-}" | ALLOW_PARTIAL="$ALLOW_PARTIAL" python3 -c '
import json, os, sys

allow = os.environ.get("ALLOW_PARTIAL") == "1"

print("%-28s %-14s %12s %22s %10s" % (
    "DATABASE", "CONNECTIVITY", "TABLES", "TX_PROCESSED", "ETA_SECS"))

raw = sys.stdin.read()
if not raw.strip():
    print("%-28s %-14s %12s %22s %10s" % ("-", "unreachable", "-", "-", "-"))
    raise SystemExit(0 if allow else 1)

try:
    d = json.loads(raw)
except Exception:
    print("%-28s %-14s %12s %22s %10s" % ("-", "parse_error", "-", "-", "-"))
    raise SystemExit(0 if allow else 1)

mirrors = d.get("mirrors") or []
if not mirrors:
    print("%-28s %-14s %12s %22s %10s" % ("-", "empty", "-", "-", "-"))
    raise SystemExit(0 if allow else 1)

partial = 0
for m in mirrors:
    db = m.get("database") or "?"
    conn = m.get("connectivity") or "?"
    live = int(m.get("tables_live") or 0)
    total = int(m.get("tables_total") or 0)
    tx = m.get("transactions_processed")
    tx = 0 if tx is None else int(tx)
    eta = m.get("next_attempt_eta_secs")
    eta_s = "-" if eta is None else str(eta)
    print("%-28s %-14s %12s %22s %10s" % (
        db, conn, "%d/%d" % (live, total), tx, eta_s))
    if conn != "live" or live != total:
        partial += 1

raise SystemExit(0 if (allow or partial == 0) else 1)
'
}

if [ "$WATCH" = "1" ]; then
    while :; do
        clear 2>/dev/null || true
        echo "public-mirror fleet status — $(date '+%Y-%m-%d %H:%M:%S')  (refresh ${INTERVAL}s, Ctrl-C to quit)"
        echo "source: $MIRRORS_URL"
        echo
        # Watch mode always allows partial so the loop keeps going.
        ALLOW_PARTIAL=1 emit || true
        sleep "$INTERVAL"
    done
else
    emit
fi
