#!/bin/sh
# switch-to-bitcraft-mirror.sh — the no-deliberation FULL SWAP:
# stop the ENTIRE current stack (all 14 public-mirror@ instances), power up
# the one-process bitcraft-mirror, flip nginx to it.
#
# Outage: the public WS band is down for green's seed (~6–10 min; the cache
# API keeps serving stale data from blue's relay-cache until the flip).
# Rollback re-seeds the old fleet progressively (~15–45 min) — accepted.
#
# Prerequisite (once, already done 2026-08-16):
#   cutover-to-bitcraft-mirror.sh --prepare-only --apply
#
# Usage:
#   switch-to-bitcraft-mirror.sh            # dry-run (prints every command)
#   switch-to-bitcraft-mirror.sh --apply    # execute the swap
#
# Roll back:
#   rollback-from-bitcraft-mirror.sh --apply
#
# If green fails mid-seed: re-run this script (idempotent) or roll back.
#
# For the blue/green variant with a warm standby and seconds-level rollback
# during a soak window, call cutover-to-bitcraft-mirror.sh directly
# (with or without --warm-regions) — see DEPLOY.md.

set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
exec "$HERE/cutover-to-bitcraft-mirror.sh" --no-warm-standby "$@"
