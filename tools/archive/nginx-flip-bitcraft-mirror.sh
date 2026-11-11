#!/bin/sh
# nginx-flip-bitcraft-mirror.sh — point nginx at the one-process
# bitcraft-mirror (up) or back at the per-instance public-mirror fleet (down).
#
# Edits every nginx config file containing the known proxy_pass lines
# (WS band 3000–3025 and the cache backend), taking a timestamped backup of
# each file first. Refuses to reload if `nginx -t` fails, restoring the
# backups it just took.
#
# usage: sudo nginx-flip-bitcraft-mirror.sh up|down
#
# up:   proxy_pass http://127.0.0.1:$server_port  →  http://127.0.0.1:3100
#       proxy_pass http://127.0.0.1:8089          →  http://127.0.0.1:8090
# down: the reverse.
#
# The rollback script restores the byte-faithful copies from its backup
# bundle instead; this helper is the quick manual lever.

set -eu
DIRECTION="${1:?usage: sudo nginx-flip-bitcraft-mirror.sh up|down}"
GREEN_WS_PORT="${GREEN_WS_PORT:-3100}"
GREEN_CACHE_PORT="${GREEN_CACHE_PORT:-8090}"
BLUE_CACHE_PORT="${BLUE_CACHE_PORT:-8089}"

files=$(grep -rl \
    -e 'proxy_pass http://127.0.0.1:$server_port' \
    -e "proxy_pass http://127.0.0.1:${GREEN_WS_PORT}" \
    -e "proxy_pass http://127.0.0.1:${GREEN_CACHE_PORT}" \
    -e "proxy_pass http://127.0.0.1:${BLUE_CACHE_PORT}" \
    /etc/nginx/sites-enabled /etc/nginx/sites-available /etc/nginx/conf.d \
    2>/dev/null | grep -v '\.bak' | sort -u || true)
if [ -z "$files" ]; then
    echo "nginx-flip: no nginx config with known proxy_pass lines found" >&2
    exit 1
fi

TS=$(date +%Y%m%d-%H%M%S)
for f in $files; do
    cp "$f" "$f.bak-flip-$TS"
    case "$DIRECTION" in
        up)
            sed -i "s|proxy_pass http://127.0.0.1:\$server_port;|proxy_pass http://127.0.0.1:${GREEN_WS_PORT};|g" "$f"
            sed -i "s|proxy_pass http://127.0.0.1:${BLUE_CACHE_PORT};|proxy_pass http://127.0.0.1:${GREEN_CACHE_PORT};|g" "$f"
            ;;
        down)
            sed -i "s|proxy_pass http://127.0.0.1:${GREEN_WS_PORT};|proxy_pass http://127.0.0.1:\$server_port;|g" "$f"
            sed -i "s|proxy_pass http://127.0.0.1:${GREEN_CACHE_PORT};|proxy_pass http://127.0.0.1:${BLUE_CACHE_PORT};|g" "$f"
            ;;
        *)
            echo "nginx-flip: unknown direction: $DIRECTION" >&2
            exit 2
            ;;
    esac
done

if ! nginx -t; then
    echo "nginx-flip: nginx -t FAILED — restoring backups" >&2
    for f in $files; do
        cp "$f.bak-flip-$TS" "$f"
    done
    exit 1
fi

nginx -s reload
echo "nginx flipped ${DIRECTION}: $files"
