#!/bin/sh
# relay-staleness-monitor.sh — warn when a live public-mirror region goes
# silent (transactions_processed stops advancing).
#
# Watches GET /v1/mirrors on the single public-mirror listen (default
# http://127.0.0.1:3000/v1/mirrors). If a mirror stays connectivity=live
# but its transactions_processed counter does not increase for a
# configurable window (default 10 minutes), log a warning.
#
# Do NOT auto-restart public-mirror by default. Restart is host-operator
# discretion: one process serves all regions, so a restart would drop
# every mirror at once. Operators may restart manually after confirming
# the stall is real (journalctl -u public-mirror, /v1/mirrors, etc.).
#
# Long-running daemon. Simple poll loop — no per-region systemd units
# (the old relay-bc* fleet is retired).
#
# Env knobs (defaults shown):
#   MIRRORS_URL=http://127.0.0.1:3000/v1/mirrors
#   STALENESS_POLL_SECS=60          poll interval
#   STALENESS_WINDOW_SECS=600       no-progress window before warning (10m)
#   STALENESS_CURL_TIMEOUT=4        /v1/mirrors fetch timeout
#   STALENESS_STATE_DIR=/var/lib/relay-staleness
#
# Requires: curl, python3.
# Unit: relay-staleness-monitor.service (host-managed).
# Logs to stdout/journald under prefix "relay-staleness:".

set -u

MIRRORS_URL="${MIRRORS_URL:-http://127.0.0.1:3000/v1/mirrors}"
POLL_SECS="${STALENESS_POLL_SECS:-60}"
WINDOW_SECS="${STALENESS_WINDOW_SECS:-600}"
CURL_TIMEOUT="${STALENESS_CURL_TIMEOUT:-4}"
STATE_DIR="${STALENESS_STATE_DIR:-/var/lib/relay-staleness}"

log() { echo "relay-staleness: $*"; }

mkdir -p "$STATE_DIR"

now_epoch() { date +%s; }

# Fetch /v1/mirrors and emit one TSV line per mirror:
#   database<TAB>connectivity<TAB>transactions_processed
# Empty output on fetch/parse failure.
snapshot_mirrors() {
    json=$(curl -sS --max-time "$CURL_TIMEOUT" "$MIRRORS_URL" 2>/dev/null || true)
    [ -n "$json" ] || return 0
    printf '%s' "$json" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
for m in d.get("mirrors") or []:
    db = m.get("database") or ""
    if not db:
        continue
    conn = m.get("connectivity") or ""
    tx = m.get("transactions_processed")
    tx = 0 if tx is None else int(tx)
    # Sanitize db for later use as a filename component: keep alnum, dash, underscore.
    safe = "".join(c if (c.isalnum() or c in "-_") else "_" for c in db)
    print("%s\t%s\t%d\t%s" % (db, conn, tx, safe))
'
}

# State files under STATE_DIR:
#   <safe>.tx      last observed transactions_processed
#   <safe>.progress  epoch when tx last increased (or when first seen live)
#   <safe>.warned    present while a stall warning is active (cleared on progress)

# --- main loop ---

log "monitor started: poll=${POLL_SECS}s window=${WINDOW_SECS}s url=$MIRRORS_URL state=$STATE_DIR"
log "auto-restart disabled — public-mirror restart is host-operator discretion (one process serves all regions)"

while :; do
    snap=$(snapshot_mirrors)
    now=$(now_epoch)

    if [ -z "$snap" ]; then
        log "cycle: /v1/mirrors unreachable or empty — skipping"
        sleep "$POLL_SECS"
        continue
    fi

    printf '%s\n' "$snap" | while IFS="$(printf '\t')" read -r db conn tx safe; do
        [ -n "$db" ] || continue
        txfile="$STATE_DIR/$safe.tx"
        progfile="$STATE_DIR/$safe.progress"
        warnfile="$STATE_DIR/$safe.warned"

        if [ "$conn" != "live" ]; then
            # Not live — reset progress tracking; connectivity issues are
            # not this monitor's job (public-mirror reconnects on its own).
            rm -f "$txfile" "$progfile" "$warnfile"
            continue
        fi

        last_tx=""
        [ -e "$txfile" ] && last_tx=$(cat "$txfile" 2>/dev/null || true)

        if [ -z "$last_tx" ]; then
            echo "$tx" > "$txfile"
            echo "$now" > "$progfile"
            rm -f "$warnfile"
            continue
        fi

        case "$last_tx" in *[!0-9]*) last_tx=0 ;; esac

        if [ "$tx" -gt "$last_tx" ]; then
            echo "$tx" > "$txfile"
            echo "$now" > "$progfile"
            if [ -e "$warnfile" ]; then
                log "RECOVERED $db: transactions_processed advancing again (now=$tx)"
            fi
            rm -f "$warnfile"
            continue
        fi

        # tx did not increase (equal or somehow lower — still count as stall).
        echo "$tx" > "$txfile"
        last_prog=$(cat "$progfile" 2>/dev/null || echo "$now")
        case "$last_prog" in *[!0-9]*) last_prog=$now ;; esac
        stalled=$(( now - last_prog ))

        if [ "$stalled" -ge "$WINDOW_SECS" ]; then
            if [ ! -e "$warnfile" ]; then
                log "WARNING $db: live but transactions_processed stuck at $tx for ${stalled}s (window=${WINDOW_SECS}s)"
                log "  restart is host-operator discretion — one public-mirror process serves all regions; do not auto-restart"
                echo "$now" > "$warnfile"
            fi
            # Subsequent cycles stay quiet until progress resumes (RECOVERED).
        fi
    done

    sleep "$POLL_SECS"
done
