#!/bin/sh
# rollback-regions-from-public-mirror.sh — reverse a partial cutover: restore
# named regions to the relay-bc* fleet (nginx + systemd + cache/coordinator).
#
# Dry-run by default. With --apply:
#   1. Re-enables relay-bcN for each region
#   2. Restores nginx :300N upstream to the matching loopback relay frontend
#   3. Optionally removes public-mirror cutover systemd drop-ins
#   4. Restarts relay-coordinator + relay-cache
#
# Pair with cutover-regions-to-public-mirror.sh (same --regions list reverses
# a forward cutover when --mirror-upstream matches what cutover used).
#
# Trial example (undo regions 7/8 cutover to :3030):
#   ./tools/rollback-regions-from-public-mirror.sh \
#       --regions 7,8 \
#       --mirror-upstream 127.0.0.1:3030
#   ./tools/rollback-regions-from-public-mirror.sh --apply \
#       --regions 7,8 \
#       --mirror-upstream 127.0.0.1:3030
#
# Keep drop-ins when other regions still use public-mirror (advanced):
#   ./tools/rollback-regions-from-public-mirror.sh --apply \
#       --regions 8 --mirror-upstream 127.0.0.1:3030 --keep-dropins
#   (relay-cache still prefers mirror rows from /v1/mirrors — remove rolled-
#   back DBs from the mirror process or re-run cutover for the remaining set.)
#
# Usage:
#   ./tools/rollback-regions-from-public-mirror.sh [options]
#   ./tools/rollback-regions-from-public-mirror.sh --apply [options]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT}/tools/relay-env.local.sh" 2>/dev/null || true

APPLY=0
REGIONS=""
MIRROR_UPSTREAM="${MIRROR_UPSTREAM:-127.0.0.1:3030}"
CLEAR_DROPINS=1
WAIT_READY=0
WAIT_TIMEOUT="${ROLLBACK_WAIT_TIMEOUT:-600}"
SSH="${RELAY_SSH:-debian@relay.bitcraftsync.app}"
NGINX_SITE="/etc/nginx/sites-available/relay-frontends"
CACHE_DROPIN="/etc/systemd/system/relay-cache.service.d/public-mirror-cutover.conf"
COORD_DROPIN="/etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --regions) REGIONS="$2"; shift 2 ;;
        --mirror-upstream) MIRROR_UPSTREAM="$2"; shift 2 ;;
        --keep-dropins) CLEAR_DROPINS=0; shift ;;
        --clear-dropins) CLEAR_DROPINS=1; shift ;;
        --wait) WAIT_READY=1; shift ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,32p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$REGIONS" ]; then
    echo "error: --regions required (e.g. --regions 7,8)" >&2
    exit 2
fi

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "$@"
    else
        echo "DRY-RUN ssh $SSH $*"
    fi
}

echo "== rollback regions $REGIONS to relay-bc* fleet =="
echo "   mirror_upstream (nginx restore from)=$MIRROR_UPSTREAM"
echo "   clear_dropins=$CLEAR_DROPINS  wait_ready=$WAIT_READY"
echo

echo "== 1/5: start relay-bc units =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    run_remote "sudo systemctl enable relay-bc${r}.service 2>/dev/null || true; \
        sudo systemctl start relay-bc${r}.service"
done

if [ "$WAIT_READY" -eq 1 ]; then
    echo "== 2/5: wait for relay /metrics ready (timeout ${WAIT_TIMEOUT}s) =="
    for r in $(echo "$REGIONS" | tr ',' ' '); do
        dash=$((3100 + r))
        if [ "$APPLY" -eq 1 ]; then
            ssh "$SSH" "python3 - ${dash} ${WAIT_TIMEOUT}" <<'PY'
import json, sys, time, urllib.request
port = int(sys.argv[1])
timeout = int(sys.argv[2])
url = f"http://127.0.0.1:{port}/metrics"
deadline = time.time() + timeout
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=3) as resp:
            body = json.load(resp)
        up = lambda k: (body.get(k) or {}).get("state") == "up"
        if up("upstream") and up("local_stdb") and body.get("initial_subscribe_complete"):
            print(f"ready: dashboard :{port}")
            sys.exit(0)
    except Exception as e:
        print(f"waiting :{port} ... {e}", file=sys.stderr)
    time.sleep(5)
print(f"timeout waiting for relay dashboard :{port}", file=sys.stderr)
sys.exit(1)
PY
        else
            echo "DRY-RUN wait for relay dashboard :${dash}"
        fi
    done
else
    echo "== 2/5: skip relay ready wait (pass --wait to block until /metrics live) =="
fi

echo "== 3/5: restore nginx :300N → loopback relay for rolled-back regions =="
REGIONS_CSV="$REGIONS"
if [ "$APPLY" -eq 1 ]; then
    ssh "$SSH" "sudo REGIONS='${REGIONS_CSV}' UPSTREAM='${MIRROR_UPSTREAM}' SITE='${NGINX_SITE}' python3" <<'PY'
import os, re, sys

regions = [int(x) for x in os.environ["REGIONS"].split(",") if x.strip()]
upstream = os.environ["UPSTREAM"].strip()
path = os.environ["SITE"]

with open(path, encoding="utf-8") as f:
    content = f.read()

def restore_block(block, port, upstream):
    if not re.search(rf"listen\s+[^;]*:{port}\b", block):
        return block
    esc = re.escape(upstream)
    block, n = re.subn(
        rf"proxy_pass\s+http://{esc}\s*;",
        f"proxy_pass http://127.0.0.1:{port};",
        block,
        count=1,
    )
    if n:
        return block
    if re.search(r"proxy_pass\s+http://127\.0\.0\.1:\$server_port\s*;", block):
        return block
    return re.sub(
        r"(location\s+/\s*\{[^}]*?)proxy_pass\s+http://[^;]+;",
        rf"\1proxy_pass http://127.0.0.1:{port};",
        block,
        count=1,
        flags=re.DOTALL,
    )

out = []
i = 0
while i < len(content):
    m = re.search(r"server\s*\{", content[i:])
    if not m:
        out.append(content[i:])
        break
    start = i + m.start()
    out.append(content[i:start])
    depth = 0
    j = start
    while j < len(content):
        ch = content[j]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                block = content[start : j + 1]
                for r in regions:
                    block = restore_block(block, 3000 + r, upstream)
                out.append(block)
                i = j + 1
                break
        j += 1
    else:
        out.append(content[start:])
        break

new_content = "".join(out)
if new_content == content:
    print("warning: nginx site unchanged (already relay upstream?)", file=sys.stderr)
with open(path, "w", encoding="utf-8") as f:
    f.write(new_content)
for r in regions:
    print(f"nginx: restored :{3000 + r} → 127.0.0.1:{3000 + r}")
PY
else
    echo "DRY-RUN nginx restore for regions ${REGIONS_CSV} (upstream ${MIRROR_UPSTREAM})"
fi

run_remote "sudo cp ${NGINX_SITE} /etc/nginx/sites-enabled/relay-frontends && \
    sudo nginx -t && sudo nginx -s reload"

echo "== 4/5: systemd drop-ins =="
if [ "$CLEAR_DROPINS" -eq 1 ]; then
    run_remote "sudo rm -f ${CACHE_DROPIN} ${COORD_DROPIN}"
    echo "   removed cutover drop-ins (cache/coordinator back to base unit env)"
else
    echo "   kept cutover drop-ins (--keep-dropins)"
    echo "   note: relay-cache still ingests any DB listed on /v1/mirrors"
fi

echo "== 5/5: restart relay-coordinator + relay-cache =="
run_remote "sudo systemctl daemon-reload && sudo systemctl restart relay-coordinator relay-cache"

echo
echo "Done. Verify:"
echo "  systemctl is-active relay-bc7 relay-bc8   # your regions"
echo "  curl -s http://127.0.0.1:8089/cache-health | python3 -m json.tool"
echo "  curl -s http://127.0.0.1:8082/health | python3 -m json.tool"
echo
echo "Re-cutover later:"
echo "  ./tools/cutover-regions-to-public-mirror.sh --apply --regions ${REGIONS} ..."
