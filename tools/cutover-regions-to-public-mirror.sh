#!/bin/sh
# cutover-regions-to-public-mirror.sh — partial WS + cache cutover for
# named regions from relay-bc* / relay-global to spacetimedb-public-mirror.
#
# Dry-run by default. With --apply:
#   1. Stops relay units for listed regions (frees loopback :300N)
#   2. Appends databases to public-mirror.instances
#   3. Starts public-mirror@DATABASE one at a time; waits for each to go live
#   4. Rebuilds cache/coordinator drop-ins from the full instances file
#   5. Restarts relay-cache + relay-coordinator (sequencer is idempotent)
#
# Production native ports (default):
#   ./tools/cutover-regions-to-public-mirror.sh --apply --regions 7,8
#   ./tools/cutover-regions-to-public-mirror.sh --apply --regions global,3,9
#
# Shared-upstream fan-in (monolithic mirror or trial sidecar — repoints nginx):
#   ./tools/cutover-regions-to-public-mirror.sh --apply --regions 7,8 \
#       --shared-upstream 127.0.0.1:3030 \
#       --mirrors-url http://127.0.0.1:3060/v1/mirrors \
#       --mirror-ws-host 127.0.0.1:3030
#
# Usage:
#   ./tools/cutover-regions-to-public-mirror.sh [options]
#   ./tools/cutover-regions-to-public-mirror.sh --apply [options]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
. "${ROOT}/../tools/relay-env.local.sh" 2>/dev/null || true

APPLY=0
REGIONS=""
NATIVE_PORTS=1
MIRRORS_URL=""
MIRROR_WS_HOST=""
MIRROR_UPSTREAM=""
# Must match spacetimedb-public-mirror MIRROR_STATUS_PORT_OFFSET.
MIRROR_STATUS_PORT_OFFSET=30
SSH="${RELAY_SSH:-${RELAY_SSH_USER:-debian}@${RELAY_HOST:-relay.bitcraftsync.app}}"
RELAY_BITCRAFT_DIR="${RELAY_BITCRAFT_DIR:-/srv/relay/bitcraft-relay}"
INSTANCES_FILE="${RELAY_BITCRAFT_DIR}/tools/public-mirror.instances"
WAIT_TIMEOUT="${CUTOVER_WAIT_TIMEOUT:-3600}"

while [ $# -gt 0 ]; do
    case "$1" in
        --apply) APPLY=1; shift ;;
        --regions) REGIONS="$2"; shift 2 ;;
        --native-ports) NATIVE_PORTS=1; shift ;;
        --shared-upstream) NATIVE_PORTS=0; MIRROR_UPSTREAM="$2"; shift 2 ;;
        --mirrors-url) MIRRORS_URL="$2"; shift 2 ;;
        --mirror-ws-host) MIRROR_WS_HOST="$2"; shift 2 ;;
        --mirror-upstream) MIRROR_UPSTREAM="$2"; shift 2 ;;
        --wait-timeout) WAIT_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,25p' "$0"
            exit 0
            ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

if [ -z "$REGIONS" ]; then
    echo "error: --regions required (e.g. --regions 7,8 or --regions global,3)" >&2
    exit 2
fi

# region token → database name
db_for_region() {
    case "$1" in
        global) echo "bitcraft-live-global" ;;
        *) echo "bitcraft-live-$1" ;;
    esac
}

# region token → legacy relay unit
relay_unit_for_region() {
    case "$1" in
        global) echo "relay-global.service" ;;
        *) echo "relay-bc${1}.service" ;;
    esac
}

# region token → public listen port
port_for_region() {
    case "$1" in
        global) echo 3000 ;;
        *) echo $((3000 + $1)) ;;
    esac
}

if [ "$NATIVE_PORTS" -eq 0 ]; then
    if [ -z "$MIRRORS_URL" ] || [ -z "$MIRROR_WS_HOST" ] || [ -z "$MIRROR_UPSTREAM" ]; then
        echo "error: --shared-upstream mode requires --mirrors-url and --mirror-ws-host" >&2
        exit 2
    fi
fi

run_remote() {
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "$@"
    else
        echo "DRY-RUN ssh $SSH $*"
    fi
}

echo "== cutover regions $REGIONS to public-mirror =="
echo "   mode=$([ "$NATIVE_PORTS" -eq 1 ] && echo native-ports || echo shared-upstream)"
echo "   instances_file=$INSTANCES_FILE"
echo "   nginx upstream=${MIRROR_UPSTREAM:-unchanged (native ports)}"
echo

echo "== 1/6: stop relay units (free loopback :300N) =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    unit=$(relay_unit_for_region "$r")
    run_remote "sudo systemctl disable --now ${unit} 2>/dev/null || true"
done

echo "== 2/6: append databases to public-mirror.instances =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    db=$(db_for_region "$r")
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "sudo env db='$db' file='$INSTANCES_FILE' python3" <<'PY'
import os
from pathlib import Path
db = os.environ["db"]
path = Path(os.environ["file"])
raw = path.read_text(encoding="utf-8") if path.exists() else ""
lines = raw.splitlines()
existing = {
    ln.strip()
    for ln in lines
    if ln.strip() and not ln.strip().startswith("#")
}
if db in existing:
    print(f"instances: {db} already listed")
else:
    with path.open("a", encoding="utf-8") as f:
        if raw and not raw.endswith("\n"):
            f.write("\n")
        f.write(db + "\n")
    print(f"instances: appended {db}")
PY
    else
        echo "DRY-RUN append $db to $INSTANCES_FILE"
    fi
done

echo "== 3/6: start public-mirror@DATABASE sequentially =="
for r in $(echo "$REGIONS" | tr ',' ' '); do
    db=$(db_for_region "$r")
    port=$(port_for_region "$r")
    sidecar=$((port + MIRROR_STATUS_PORT_OFFSET))
    url="http://127.0.0.1:${sidecar}/v1/mirrors"
    run_remote "sudo systemctl start public-mirror@${db}.service"
    echo "   waiting for $db live on $url (timeout ${WAIT_TIMEOUT}s)"
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "python3 - '${db}' '${url}' '${WAIT_TIMEOUT}'" <<'PY'
import json, sys, time, urllib.request
db, url, timeout = sys.argv[1], sys.argv[2], int(sys.argv[3])
deadline = time.time() + timeout
while time.time() < deadline:
    try:
        with urllib.request.urlopen(url, timeout=10) as resp:
            body = json.load(resp)
        for m in body.get("mirrors") or []:
            if m.get("database") != db:
                continue
            conn = m.get("connectivity")
            tl, tt = m.get("tables_live"), m.get("tables_total")
            if conn == "live" and tl == tt and tl is not None:
                print(f"OK {db} {tl}/{tt} on {url}")
                sys.exit(0)
            print(f"waiting {db} conn={conn} tables={tl}/{tt}", file=sys.stderr)
            break
        else:
            print(f"waiting {db} missing from {url}", file=sys.stderr)
    except Exception as e:
        print(f"waiting {db} ... {e}", file=sys.stderr)
    time.sleep(10)
print(f"timeout: {db} not live on {url}", file=sys.stderr)
sys.exit(1)
PY
    else
        echo "DRY-RUN wait for ${db} on ${url}"
    fi
done

if [ "$NATIVE_PORTS" -eq 0 ]; then
    echo "== 4/6: nginx :300N → ${MIRROR_UPSTREAM} for cutover regions =="
    NGINX_SITE="/etc/nginx/sites-available/relay-frontends"
    REGIONS_CSV="$REGIONS"
    if [ "$APPLY" -eq 1 ]; then
        ssh "$SSH" "sudo REGIONS='${REGIONS_CSV}' UPSTREAM='${MIRROR_UPSTREAM}' SITE='${NGINX_SITE}' python3" <<'PY'
import os, re

def port_for(token: str) -> int:
    t = token.strip()
    if t == "global":
        return 3000
    return 3000 + int(t)

regions = [port_for(x) for x in os.environ["REGIONS"].split(",") if x.strip()]
upstream = os.environ["UPSTREAM"].strip()
upstream_port = upstream.rsplit(":", 1)[-1] if ":" in upstream else upstream
path = os.environ["SITE"]

with open(path, encoding="utf-8") as f:
    content = f.read()

map_header = "# public-mirror cutover upstream map (managed by cutover-regions-to-public-mirror.sh)"
map_re = re.compile(
    map_header.replace("(", r"\(").replace(")", r"\)")
    + r"\nmap \$server_port \$relay_upstream_port \{([^}]*)\}\n+",
    re.MULTILINE,
)

existing = {}
m = map_re.search(content)
if m:
    for line in m.group(1).splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("default"):
            continue
        parts = line.rstrip(";").split()
        if len(parts) == 2 and parts[0].isdigit() and parts[1].isdigit():
            existing[int(parts[0])] = parts[1]

for port in regions:
    existing[port] = upstream_port

lines = [f"    {port} {dest};" for port, dest in sorted(existing.items())]
lines.append("    default $server_port;")
map_block = map_header + "\nmap $server_port $relay_upstream_port {\n" + "\n".join(lines) + "\n}\n\n"

if m:
    content = map_re.sub(map_block, content, count=1)
else:
    content = map_block + content

content = re.sub(
    r"proxy_pass\s+http://127\.0\.0\.1:\$server_port\s*;",
    "proxy_pass http://127.0.0.1:$relay_upstream_port;",
    content,
    count=1,
)

with open(path, "w", encoding="utf-8") as f:
    f.write(content)
for port in regions:
    print(f"nginx: :{port} → 127.0.0.1:{upstream_port} via relay_upstream_port map")
PY
    else
        echo "DRY-RUN nginx map cutover for regions ${REGIONS_CSV} → ${MIRROR_UPSTREAM}"
    fi
    run_remote "sudo cp ${NGINX_SITE} /etc/nginx/sites-enabled/relay-frontends && \
        sudo nginx -t && sudo nginx -s reload"
else
    echo "== 4/6: nginx unchanged (native ports — :300N stays on public-mirror@N) =="
fi

echo "== 5/6: rebuild cache/coordinator drop-ins from instances file =="
CACHE_DROPIN="/etc/systemd/system/relay-cache.service.d/public-mirror-cutover.conf"
COORD_DROPIN="/etc/systemd/system/relay-coordinator.service.d/public-mirror-cutover.conf"
if [ "$NATIVE_PORTS" -eq 1 ]; then
    # Build comma-separated sidecar URLs from the full instances file so
    # incremental cutovers keep previously migrated regions.
    if [ "$APPLY" -eq 1 ]; then
        MIRRORS_URL=$(ssh "$SSH" "OFFSET='$MIRROR_STATUS_PORT_OFFSET' FILE='$INSTANCES_FILE' python3" <<'PY'
import os
from pathlib import Path

offset = int(os.environ["OFFSET"])
path = Path(os.environ["FILE"])
urls = []
for line in path.read_text(encoding="utf-8").splitlines():
    db = line.strip()
    if not db or db.startswith("#"):
        continue
    if db == "bitcraft-live-global" or db.endswith("-global"):
        port = 3000
    elif db.startswith("bitcraft-live-"):
        port = 3000 + int(db.split("-")[-1])
    else:
        continue
    urls.append(f"http://127.0.0.1:{port + offset}/v1/mirrors")
print(",".join(urls))
PY
)
        MIRROR_WS_HOST=""
        SCHEMA_DB=$(ssh "$SSH" "FILE='$INSTANCES_FILE' python3" <<'PY'
from pathlib import Path
import os
path = Path(os.environ["FILE"])
for line in path.read_text(encoding="utf-8").splitlines():
    db = line.strip()
    if db and not db.startswith("#"):
        print(db)
        break
PY
)
        case "$SCHEMA_DB" in
            bitcraft-live-global) SCHEMA_PORT=3000 ;;
            bitcraft-live-*) SCHEMA_PORT=$((3000 + ${SCHEMA_DB#bitcraft-live-})) ;;
            *) SCHEMA_PORT=3007 ;;
        esac
    else
        MIRRORS_URL="<from $INSTANCES_FILE>"
        SCHEMA_DB="bitcraft-live-7"
        SCHEMA_PORT=3007
    fi
else
    SCHEMA_DB=$(db_for_region "$(echo "$REGIONS" | cut -d, -f1)")
    SCHEMA_PORT=$(port_for_region "$(echo "$REGIONS" | cut -d, -f1)")
fi

echo "   mirrors_url=$MIRRORS_URL"
echo "   schema=$SCHEMA_DB @ 127.0.0.1:$SCHEMA_PORT"

run_remote "sudo mkdir -p /etc/systemd/system/relay-cache.service.d /etc/systemd/system/relay-coordinator.service.d"
run_remote "printf '%s\n' \
    '[Service]' \
    'Environment=RELAY_CACHE_MIRRORS_URL=${MIRRORS_URL}' \
    'Environment=RELAY_CACHE_MIRROR_WS_HOST=${MIRROR_WS_HOST}' \
    'Environment=RELAY_CACHE_SCHEMA_HOST=127.0.0.1:${SCHEMA_PORT}' \
    'Environment=RELAY_CACHE_SCHEMA_DB=${SCHEMA_DB}' \
    | sudo tee ${CACHE_DROPIN} >/dev/null"
run_remote "printf '%s\n' \
    '[Service]' \
    'Environment=RELAY_MIRRORS_URL=${MIRRORS_URL}' \
    | sudo tee ${COORD_DROPIN} >/dev/null"

echo "== 6/6: reload units + restart relay-cache + relay-coordinator =="
# Coordinator restart re-reads drop-in RELAY_MIRRORS_URL. Sequencer is
# idempotent for already-live instances (poll /v1/mirrors, skip start).
run_remote "sudo systemctl daemon-reload && \
    sudo systemctl restart relay-cache.service relay-coordinator.service"

echo
echo "Done. Verify:"
echo "  systemctl is-active public-mirror@bitcraft-live-7"
echo "  curl -s http://127.0.0.1:8082/health | python3 -m json.tool"
echo "  curl -s http://127.0.0.1:8089/cache-health | python3 -m json.tool"
echo
echo "Rollback:"
echo "  ./tools/rollback-regions-from-public-mirror.sh --apply --regions ${REGIONS} --wait"
