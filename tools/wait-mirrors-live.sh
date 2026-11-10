#!/bin/sh
# wait-mirrors-live.sh — poll a public-mirror /v1/mirrors endpoint until the
# expected number of databases report connectivity=live with
# tables_live == tables_total.
#
# usage: wait-mirrors-live.sh <url> <expected-count> [timeout-secs] [interval-secs]
# exit 0 = all live; 1 = timeout. Prints one status line per poll.

set -eu
URL="${1:?usage: wait-mirrors-live.sh <url> <expected> [timeout] [interval]}"
EXPECTED="${2:?usage: wait-mirrors-live.sh <url> <expected> [timeout] [interval]}"
TIMEOUT="${3:-3600}"
INTERVAL="${4:-10}"

exec python3 - "$URL" "$EXPECTED" "$TIMEOUT" "$INTERVAL" <<'PY'
import json
import sys
import time
import urllib.request

url, expected, timeout, interval = (
    sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), int(sys.argv[4]))
deadline = time.monotonic() + timeout

def fetch():
    with urllib.request.urlopen(url, timeout=10) as r:
        return json.load(r).get("mirrors", [])

while time.monotonic() < deadline:
    try:
        mirrors = fetch()
        done = [m for m in mirrors
                if m.get("connectivity") == "live"
                and m.get("tables_live") == m.get("tables_total")]
        detail = " ".join(
            "{}:{}".format(
                m.get("database", "?").removeprefix("idc-").removeprefix("bitcraft-live-"),
                m.get("connectivity", "?")
                if m.get("connectivity") == "live"
                else "{}({}/{})".format(m.get("connectivity", "?"),
                                        m.get("tables_live", 0),
                                        m.get("tables_total", 0)))
            for m in mirrors)
        print("{} {}/{} live | {}".format(
            time.strftime("%H:%M:%S"), len(done), expected, detail), flush=True)
        if len(mirrors) >= expected and len(done) >= expected:
            sys.exit(0)
    except Exception as e:  # noqa: BLE001 - polling loop
        print("{} poll failed: {}".format(time.strftime("%H:%M:%S"), e), flush=True)
    time.sleep(interval)

print("TIMEOUT after {}s waiting for {} mirrors on {}".format(
    timeout, expected, url), file=sys.stderr)
sys.exit(1)
PY
