#!/bin/sh
# cutover-telemetry-capture.sh — host-side sampler for bitcraft-mirror
# cutover attempts. Every SAMPLE_SECS it records:
#   - system CPU with the **iowait split** (the CPU-vs-disk question the
#     2026-08-17 attempt-#2 post-mortem could not answer — its capture died),
#   - whole-disk read/write sector counters (/proc/diskstats),
#   - the green process's CPU jiffies and /proc/PID/io read/write bytes
#     (pid re-resolved every sample, so service restarts are followed),
#   - **kernel stacks of D-state (uninterruptible-IO) threads**, while any
#     exist — attempt #4's load 10–14 with runnable 1–3 was exactly this,
#     and the stacks name the blocked syscall (inspect with
#     `grep -A12 '^dstack' telemetry.log`; zero lines in steady state).
#
# Started best-effort by cutover-to-bitcraft-mirror.sh just before green
# launches; safe to also start manually. Pidfile-guarded — deliberately no
# pattern-matching kills, which is how the attempt-#2 capture was lost
# (a `pkill -f` self-matched the ssh session that was restarting it).
#
# Usage (on the host; root for the green process's /proc/PID/io):
#   cutover-telemetry-capture.sh start [OUTDIR]     begin sampling
#   cutover-telemetry-capture.sh stop               stop sampling (pidfile kill)
#   cutover-telemetry-capture.sh status
#   cutover-telemetry-capture.sh summarize [OUTDIR] per-minute CPU/iowait/disk/proc table
#
# Output: OUTDIR/telemetry.log (append across attempts; blocks start with
# `=== <ISO8601 UTC>`). Default OUTDIR=/tmp/cutover-telemetry.

set -eu

SAMPLE_SECS="${SAMPLE_SECS:-5}"
UNIT="${UNIT:-bitcraft-mirror.service}"
DEFAULT_OUT=/tmp/cutover-telemetry

pidfile_alive() {
    [ -f "$1" ] && kill -0 "$(cat "$1")" 2>/dev/null
}

sample_once() {
    log="$1"  # full path to the log file
    echo "=== $(date -u +%FT%TZ)" >>"$log"
    grep '^cpu ' /proc/stat >>"$log"
    cat /proc/loadavg >>"$log"
    awk '$3 ~ /^(sd[a-z]+|vd[a-z]+|nvme[0-9]+n[0-9]+)$/ { r += $6; w += $10 }
         END { print "disk " r " " w }' /proc/diskstats >>"$log"
    pid=$(systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0)
    if [ -n "$pid" ] && [ "$pid" != 0 ] && [ -r "/proc/$pid/stat" ]; then
        awk -v p="$pid" '{ print "proc " p " " $14 " " $15 }' /proc/$pid/stat >>"$log"
        if [ -r "/proc/$pid/io" ]; then
            awk -v p="$pid" '/^read_bytes/ { r = $2 } /^write_bytes/ { w = $2 }
                             END { print "procio " p " " r " " w }' /proc/$pid/io >>"$log"
        fi
    else
        echo "proc 0 0 0" >>"$log"
    fi
    # D-state thread stacks. ps (not /proc/*/stat awk) because comm can
    # contain spaces; /proc/PID/task/TID/stack needs root (we run as root)
    # with the always-readable wchan as corroboration/fallback.
    ps -eLo stat=,pid=,tid=,comm= --no-headers 2>/dev/null \
        | awk '$1 ~ /^D/ { $1 = ""; print }' \
        | while read -r dpid dtid dcomm; do
            echo "dstack $dpid $dtid $dcomm" >>"$log"
            if [ -r "/proc/$dpid/task/$dtid/stack" ]; then
                sed 's/^/  dstack-frame /' "/proc/$dpid/task/$dtid/stack" >>"$log"
            fi
            echo "  dstack-wchan $(cat /proc/$dpid/task/$dtid/wchan 2>/dev/null)" >>"$log"
        done
}

cmd_start() {
    out="${1:-$DEFAULT_OUT}"
    mkdir -p "$out"
    if pidfile_alive "$out/capture.pid"; then
        echo "capture already running (pid $(cat "$out/capture.pid")), logging to $out"
        return 0
    fi
    setsid nohup "$0" sample-loop "$out" "$SAMPLE_SECS" >/dev/null 2>&1 &
    echo $! >"$out/capture.pid"
    sleep 1
    if pidfile_alive "$out/capture.pid"; then
        echo "capture started (pid $(cat "$out/capture.pid")), ${SAMPLE_SECS}s samples -> $out/telemetry.log"
    else
        echo "capture failed to start" >&2
        return 1
    fi
}

cmd_sample_loop() {
    out="$1"; secs="$2"
    log="$out/telemetry.log"
    while :; do
        sample_once "$log" || true
        sleep "$secs"
    done
}

cmd_stop() {
    out="${1:-$DEFAULT_OUT}"
    if pidfile_alive "$out/capture.pid"; then
        kill "$(cat "$out/capture.pid")"
        rm -f "$out/capture.pid"
        echo "capture stopped"
    else
        echo "no capture running"
    fi
}

cmd_status() {
    out="${1:-$DEFAULT_OUT}"
    if pidfile_alive "$out/capture.pid"; then
        echo "running (pid $(cat "$out/capture.pid")), $(wc -l <"$out/telemetry.log" 2>/dev/null || echo 0) lines in $out/telemetry.log"
    else
        echo "not running"
    fi
}

cmd_summarize() {
    out="${1:-$DEFAULT_OUT}"
    python3 - "$out/telemetry.log" <<'PY'
import sys
from datetime import datetime, timezone

HZ = 100  # CLK_TCK on this host class; close enough for percentages.

def parse(path):
    ts = None
    for line in open(path):
        line = line.strip()
        if line.startswith("=== "):
            ts = datetime.strptime(line[4:], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        elif line.startswith("cpu ") and ts:
            yield ts, "cpu", [int(x) for x in line.split()[1:]]
        elif line.startswith("disk ") and ts:
            yield ts, "disk", [int(x) for x in line.split()[1:]]
        elif line.startswith("proc ") and ts:
            yield ts, "proc", [int(x) for x in line.split()[1:]]
        elif line.startswith("procio ") and ts:
            yield ts, "procio", [int(x) for x in line.split()[1:]]

samples = list(parse(sys.argv[1] if len(sys.argv) > 1 else "/tmp/cutover-telemetry/telemetry.log"))
if len(samples) < 2:
    print("not enough samples")
    sys.exit(0)

# Bucket consecutive samples into per-minute rows, computing deltas within each bucket.
buckets = {}
order = []
prev = None
for ts, kind, vals in samples:
    key = ts.strftime("%H:%M")
    if key not in buckets:
        buckets[key] = {"cpu": [], "disk": [], "proc": [], "procio": [], "t": []}
        order.append(key)
    buckets[key][kind].append((ts, vals))

print("%-6s %7s %8s %10s %10s %8s %10s %10s" % (
    "utc", "cpu%", "iowait%", "disk-r-MB/s", "disk-w-MB/s", "proc%", "p-rd-MB/s", "p-wr-MB/s"))
for key in order:
    b = buckets[key]
    def deltas(kind):
        xs = b[kind]
        out = []
        for (t1, v1), (t2, v2) in zip(xs, xs[1:]):
            dt = (t2 - t1).total_seconds()
            if dt > 0:
                out.append(([y - x for x, y in zip(v1, v2)], dt))
        return out

    cpu = iowait = 0.0
    for dv, dt in deltas("cpu"):
        # fields: user nice system idle iowait irq softirq steal guest guest_nice
        nonidle = dv[0] + dv[1] + dv[2] + dv[5] + dv[6] + dv[7]
        total = nonidle + dv[3] + dv[4]
        if total > 0:
            cpu += nonidle / total / dt * 100
            iowait += dv[4] / total / dt * 100
    n = max(len(deltas("cpu")), 1)
    cpu, iowait = cpu / n, iowait / n

    dr = dw = 0.0
    for dv, dt in deltas("disk"):
        dr += dv[0] / 512 / 1024 / dt  # sectors -> MiB/s
        dw += dv[1] / 512 / 1024 / dt
    n = max(len(deltas("disk")), 1)
    dr, dw = dr / n, dw / n

    pc = pr = pw = 0.0
    # Per-pid deltas (pid is vals[0]); the service may restart mid-attempt.
    for kind, scale in (("proc", None), ("procio", None)):
        per_pid = {}
        for t, v in b[kind]:
            per_pid.setdefault(v[0], []).append((t, v))
        tot = cnt = 0
        if kind == "proc":
            for xs in per_pid.values():
                for (t1, v1), (t2, v2) in zip(xs, xs[1:]):
                    dt = (t2 - t1).total_seconds()
                    if dt > 0:
                        tot += (v2[1] - v1[1] + v2[2] - v1[2]) / HZ / dt * 100
                        cnt += 1
            pc = tot / max(cnt, 1)
        else:
            r = w = c = 0
            for xs in per_pid.values():
                for (t1, v1), (t2, v2) in zip(xs, xs[1:]):
                    dt = (t2 - t1).total_seconds()
                    if dt > 0:
                        r += (v2[1] - v1[1]) / 1024 / 1024 / dt
                        w += (v2[2] - v1[2]) / 1024 / 1024 / dt
                        c += 1
            pr, pw = r / max(c, 1), w / max(c, 1)

    print("%-6s %6.0f%% %7.0f%% %10.1f %10.1f %7.0f%% %10.1f %10.1f" % (
        key, cpu, iowait, dr, dw, pc, pr, pw))
PY
}

# Per-interval view: one row per consecutive cpu sample pair. Minute
# averaging (cmd_summarize) hid the 2026-08-17 attempt-#3 iowait onset for
# two analysis rounds — 91-95% spikes sat inside minutes that averaged out
# to "3-13%". Rows with iowait >= 20% get a "<<<" marker so a stalled
# storage window can be spotted by grep.
cmd_summarize_intervals() {
    out="${1:-$DEFAULT_OUT}"
    python3 - "$out/telemetry.log" <<'PY'
import sys
from datetime import datetime, timezone

prev_ts = None
prev = None
print("%-20s %6s %8s %s" % ("utc", "cpu%", "iowait%", ""))
for line in open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/cutover-telemetry/telemetry.log"):
    line = line.strip()
    if line.startswith("=== "):
        ts = datetime.strptime(line[4:24], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
        prev_ts = ts  # sample header; cpu line follows
    elif line.startswith("cpu ") and prev_ts is not None:
        vals = [int(x) for x in line.split()[1:]]
        if prev is not None:
            dv = [y - x for x, y in zip(prev, vals)]
            # fields: user nice system idle iowait irq softirq steal guest guest_nice
            nonidle = dv[0] + dv[1] + dv[2] + dv[5] + dv[6] + dv[7]
            total = nonidle + dv[3] + dv[4]
            if total > 0:
                cpu = nonidle / total * 100
                iow = dv[4] / total * 100
                mark = "  <<<" if iow >= 20.0 else ""
                print("%-20s %5.1f%% %7.1f%%%s" % (prev_ts.strftime("%H:%M:%S"), cpu, iow, mark))
        prev = vals
        prev_ts = None
PY
}

case "${1:-}" in
    start) shift; cmd_start "$@" ;;
    stop) shift; cmd_stop "$@" ;;
    status) shift; cmd_status "$@" ;;
    summarize) shift; cmd_summarize "$@" ;;
    summarize-intervals) shift; cmd_summarize_intervals "$@" ;;
    sample-loop) shift; cmd_sample_loop "$@" ;;  # internal; spawned by start
    *)
        echo "usage: $0 start [OUTDIR]|stop [OUTDIR]|status [OUTDIR]|summarize [OUTDIR]|summarize-intervals [OUTDIR]" >&2
        exit 2
        ;;
esac
