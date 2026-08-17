#!/bin/sh
# wait-cache-ready.sh — poll a relay-cache /cache-health endpoint until it
# reports {"ready": true} (all regions ready, no memory pressure).
#
# usage: wait-cache-ready.sh <url> [timeout-secs] [interval-secs]
# exit 0 = ready; 1 = timeout. Prints the last body on success.

set -eu
URL="${1:?usage: wait-cache-ready.sh <url> [timeout] [interval]}"
TIMEOUT="${2:-600}"
INTERVAL="${3:-5}"

exec python3 - "$URL" "$TIMEOUT" "$INTERVAL" <<'PY'
import json
import sys
import time
import urllib.request

url, timeout, interval = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
deadline = time.monotonic() + timeout

while time.monotonic() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=10) as r:
            body = json.load(r)
        ready = body.get("ready") and all(
            x.get("ready") for x in body.get("regions", [{}]))
        n = len(body.get("regions", []))
        print("{} ready={} regions={}/ready".format(
            time.strftime("%H:%M:%S"), body.get("ready"), n), flush=True)
        if ready:
            print(json.dumps(body)[:400], flush=True)
            sys.exit(0)
    except Exception as e:  # noqa: BLE001 - polling loop
        print("{} poll failed: {}".format(time.strftime("%H:%M:%S"), e), flush=True)
    time.sleep(interval)

print("TIMEOUT after {}s waiting for cache ready on {}".format(
    timeout, url), file=sys.stderr)
sys.exit(1)
PY
