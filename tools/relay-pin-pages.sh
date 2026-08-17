#!/bin/sh
# relay-pin-pages.sh — pin an executable and its shared libraries into RAM
# (vmtouch mlock) so the pinned process takes no file-backed page faults at
# runtime.
#
# Why (2026-08-17, spacetimedb-bitcraft-mirror/MULTI-MIRROR-UPSTREAM-RESETS.md
# attempt #4): the host's legacy ~3 MB/s HDDs starve lazy text-page faults
# behind writeback drains — reads completed at 0.00 MB/s during the stall
# waves, stalling Future::poll 20–56 s past the upstream pong deadline.
# Pinning removes the disk from the runtime read path entirely.
#
# The systemd unit sets PIN_BINARY. vmtouch stays in the foreground holding
# the mlock for as long as the unit runs; stop/disable the unit to unpin.
# A redeployed binary is a NEW inode — restart the pin unit after each
# deploy (tools/deploy.sh does this for both mirror components).
#
# Requires: vmtouch (apt install vmtouch) on the host.
BIN="${PIN_BINARY:?PIN_BINARY must be set by the unit}"
# ldd output has two shapes: "lib => /path (addr)" and "/path (addr)" for
# the loader itself.
set -- "$BIN" $(ldd "$BIN" 2>/dev/null | sed -n -e 's/.* => \(\/[^ ]*\) (.*/\1/p' -e 's/^\(\/[^ ]*\) (.*)/\1/p' | sort -u)
exec /usr/bin/vmtouch -q -l "$@"
