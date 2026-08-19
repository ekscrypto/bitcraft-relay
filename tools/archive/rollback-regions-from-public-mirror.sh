#!/bin/sh
# rollback-regions-from-public-mirror.sh — reverse a partial cutover: restore
# named regions to the relay-bc* fleet (systemd + cache/coordinator).
#
# Dry-run by default. With --apply:
#   1. Stops public-mirror@bitcraft-live-N for each region
#   2. Re-enables relay-bcN for each region
#   3. Optionally restores nginx (shared-upstream cutovers only)
#   4. Removes public-mirror cutover systemd drop-ins (unless --keep-dropins)
#   5. Restarts relay-coordinator + relay-cache
#
# Production native-port rollback (default):
#   ./tools/rollback-regions-from-public-mirror.sh --apply --regions 7,8 --wait
#
# Shared-upstream rollback (when cutover used --shared-upstream):
#   ./tools/rollback-regions-from-public-mirror.sh --apply --regions 7,8 \
#       --shared-upstream 127.0.0.1:3030 --wait
#
# Usage:
#   ./tools/rollback-regions-from-public-mirror.sh [options]
#   ./tools/rollback-regions-from-public-mirror.sh --apply [options]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT}/../tools/relay-env.local.sh" 2>/dev/null || true

APPLY=0
REGIONS=""
NATIVE_PORTS=1
MIRROR_UPSTREAM=""
CLEAR_DROPINS=1
WAIT_READY=0
WAIT_TIMEOUT="${ROLLBACK_WAIT_TIMEOUT:-600}"
SSH="${RELAY_SSH:-${RELAY_SSH_USER:-debian}@${RELAY_HOST:-relay.bitcraftsync.app}}"
NGINX_SITE="/etc/nginx/sites-available/relay-frontends"
CACHE_DROPIN="/etc/systemd/system/relay-cache.service.d/public-mirror-cutover.conf"
COORD_DROPIN="/etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --regions) REGIONS="$2"; shift 2 ;;
        --native-ports) NATIVE_PORTS=1; shift ;;
        --shared-upstream) NATIVE_PORTS=0; MIRROR_UPSTREAM="$2"; shift 2 ;;
        --mirror-upstream) MIRROR_UPSTREAM="$2"; NATIVE_PORTS=0; shift 2 ;;
        --keep-dropins) CLEAR_DROPINS=0; shift ;;
        --clear-dropins) CLEAR_DROPINS=1; shift ;;
        --wait) WAIT_READY=1; shift ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,22p' "$0"
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
echo "   mode=$([ "$NATIVE_PORTS" -eq 1 ] && echo native-ports || echo shared-upstream)"
echo "   clear_dropins=$CLEAR_DROPINS  wait_ready=$WAIT_READY"
echo

echo "== 1/6: stop public-mirror@ units =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    db="bitcraft-live-${r}"
    run_remote "sudo systemctl disable --now public-mirror@${db}.service 2>/dev/null || true"
done

echo "== 2/6: start relay-bc units =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    run_remote "sudo systemctl enable relay-bc${r}.service 2>/dev/null || true; \
        sudo systemctl start relay-bc${r}.service"
done

if [ "$WAIT_READY" -eq 1 ]; then
    echo "== 3/6: wait for relay /metrics ready (timeout ${WAIT_TIMEOUT}s) =="
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
    echo "== 3/6: skip relay ready wait (pass --wait to block until /metrics live) =="
fi

if [ "$NATIVE_PORTS" -eq 0 ]; then
    echo "== 4/6: restore nginx :300N → loopback relay for rolled-back regions =="
    REGIONS_CSV="$REGIONS"
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "sudo REGIONS='${REGIONS_CSV}' UPSTREAM='${MIRROR_UPSTREAM}' SITE='${NGINX_SITE}' python3" <<'PY'
import os, re

regions = [int(x) for x in os.environ["REGIONS"].split(",") if x.strip()]
upstream = os.environ["UPSTREAM"].strip()
path = os.environ["SITE"]

with open(path, encoding="utf-8") as f:
    content = f.read()

map_header = "# public-mirror cutover upstream map (managed by cutover-regions-to-public-mirror.sh)"
map_re = re.compile(
    map_header.replace("(", r"\(").replace(")", r"\)")
    + r"\nmap \$server_port \$relay_upstream_port \{([^}]*)\}\n+",
    re.MULTILINE,
)

m = map_re.search(content)
if m:
    remaining = {}
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("default"):
            continue
        parts = line.rstrip(";").split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            remaining[int(parts[0])] = parts[1]
    for r in regions:
        remaining.pop(3000 + r, None)
    if remaining:
        lines = [f"    {port} {dest};" for port, dest in sorted(remaining.items())]
        lines.append("    default $server_port;")
        map_block = map_header + "\nmap $server_port $relay_upstream_port {\n" + "\n".join(lines) + "\n}\n\n"
        content = map_re.sub(map_block, content, count=1)
    else:
        content = map_re.sub("", content, count=1)
        content = re.sub(
            r"proxy_pass\s+http://127\.0\.0\.1:\$relay_upstream_port\s*;",
            "proxy_pass http://127.0.0.1:$server_port;",
            content,
            count=1,
        )

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
for r in regions:
    print(f"nginx: restored :{3000 + r} → loopback relay (127.0.0.1:{3000 + r})")
PY
    else
        echo "DRY-RUN nginx restore for regions ${REGIONS_CSV}"
    fi
    run_remote "sudo cp ${NGINX_SITE} /etc/nginx/sites-enabled/relay-frontends && \
        sudo nginx -t && sudo nginx -s reload"
else
    echo "== 4/6: nginx unchanged (native ports) =="
fi

echo "== 5/6: systemd drop-ins =="
if [ "$CLEAR_DROPINS" -eq 1 ]; then
    run_remote "sudo rm -f ${CACHE_DROPIN} ${COORD_DROPIN}"
    echo "   removed cutover drop-ins (cache/coordinator back to base unit env)"
else
    echo "   kept cutover drop-ins (--keep-dropins)"
    echo "   note: relay-cache still ingests any DB listed on /v1/mirrors"
fi

echo "== 6/6: restart relay-coordinator + relay-cache =="
run_remote "sudo systemctl daemon-reload && sudo systemctl restart relay-coordinator relay-cache"

echo
echo "Done. Verify:"
echo "  systemctl is-active relay-bc7 relay-bc8   # your regions"
echo "  curl -s http://127.0.0.1:8089/cache-health | python3 -m json.tool"
echo "  curl -s http://127.0.0.1:8082/health | python3 -m json.tool"
echo
echo "Re-cutover later:"
echo "  ./tools/cutover-regions-to-public-mirror.sh --apply --regions ${REGIONS}"
