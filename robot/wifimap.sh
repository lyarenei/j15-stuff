#!/bin/sh
# Runs on the robot. Records the Wi-Fi signal strength together with the
# robot's position while it cleans, by following the planner log, and keeps the
# samples in /userdata/wifimap/job-*.csv. Started at boot from
# /oem/_root_postboot.sh by install.sh. The recorder is in wifimap.awk;
# `wifimap.sh prune` deletes the oldest job files beyond MAX_JOBS.

CONF=${CONF:-/userdata/wifimap.conf}
LOG=${LOG:-/tmp/wifimap.log}
AWK_PROG=${AWK_PROG:-/userdata/wifimap.awk}
DIR=${DIR:-/userdata/wifimap}
PLANNER_LOG=${PLANNER_LOG:-/userdata/logs/app/planner/planner.INFO}
WIRELESS=${WIRELESS:-/proc/net/wireless}
IFACE=${IFACE:-wlan0}
IW_CMD=${IW_CMD:-iw dev $IFACE link}
FIFO=${FIFO:-/tmp/wifimap.fifo}
INTERVAL_S=1
JOB_GAP_S=900
BSSID_EVERY_S=10
MAX_JOBS=100
FLUSH_S=30
[ -f "$CONF" ] && . "$CONF"

if [ "$1" = prune ]; then
    n=0
    for f in "$DIR"/job-*.csv; do [ -e "$f" ] && n=$((n + 1)); done
    for f in "$DIR"/job-*.csv; do
        [ "$n" -gt "$MAX_JOBS" ] || break
        rm -f "$f"
        n=$((n - 1))
    done
    exit 0
fi

# The stock busybox has this as an applet but no link for it.
command -v wc >/dev/null 2>&1 || wc() { busybox wc "$@"; }

echo $$ > "${PIDFILE:-/tmp/wifimap.pid}"

log() {
    # /tmp is RAM; keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
        mv "$LOG" "$LOG.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

finish() {
    log "stopping"
    kill $tail_pid 2>/dev/null
    # EOF makes awk close the job file.
    exec 3>&-
    wait $awk_pid
    rm -f "$FIFO" "${PIDFILE:-/tmp/wifimap.pid}"
    exit 0
}

while [ ! -d "$(dirname "$PLANNER_LOG")" ]; do
    sleep 5
done

mkdir -p "$DIR"
rm -f "$FIFO"
mkfifo "$FIFO"
log "started"

trap finish TERM INT HUP

awk -f "$AWK_PROG" \
    -v DIR="$DIR" -v WIRELESS="$WIRELESS" -v IFACE="$IFACE" -v IW_CMD="$IW_CMD" \
    -v PRUNE_CMD="CONF='$CONF' DIR='$DIR' sh '$0' prune" \
    -v INTERVAL_S="$INTERVAL_S" -v JOB_GAP_S="$JOB_GAP_S" \
    -v BSSID_EVERY_S="$BSSID_EVERY_S" -v FLUSH_S="$FLUSH_S" \
    < "$FIFO" 2>> "$LOG" &
awk_pid=$!
exec 3> "$FIFO"

tail -q -n 0 -F "$PLANNER_LOG" >&3 2>/dev/null &
tail_pid=$!

wait "$awk_pid"
log "awk exited, stopping"
finish
