#!/bin/sh
# Runs on the robot. Estimates the dock's clean and dirty water tank levels by
# following the data_node log (the dock has no level sensors) and keeps them in
# /userdata/tankwatch/state.json. Started at boot from /oem/_root_postboot.sh
# by install.sh. The model is in tankwatch.awk; `tankwatch.sh reset clean|dirty`
# marks a tank as refilled / emptied.

CONF=${CONF:-/userdata/tankwatch.conf}
LOG=${LOG:-/tmp/tankwatch.log}
AWK_PROG=${AWK_PROG:-/userdata/tankwatch.awk}
DIR=${DIR:-/userdata/tankwatch}
DATA_LOG=${DATA_LOG:-/userdata/logs/app/data/data.INFO}
MANAGER_LOG=${MANAGER_LOG:-/userdata/logs/app/manager/manager.INFO}
FLAGS=${FLAGS:-/tmp/tankwatch.reset}
FIFO=${FIFO:-/tmp/tankwatch.fifo}
CLEAN_CAPACITY_ML=4000
DIRTY_CAPACITY_ML=3400
FLOW_ML_PER_UNIT_S=0.016667
REFILL_ML_PER_S=3.1
DIRTY_ML_PER_PUMP_S=1.4
LOW_PCT=20
[ -f "$CONF" ] && . "$CONF"

# The stock busybox has this as an applet but no link for it.
command -v wc >/dev/null 2>&1 || wc() { busybox wc "$@"; }

if [ "$1" = reset ]; then
    case $2 in
    clean|dirty) : > "$FLAGS-$2" ;;
    *) echo "usage: $0 reset clean|dirty" >&2; exit 2 ;;
    esac
    exit 0
fi

echo $$ > "${PIDFILE:-/tmp/tankwatch.pid}"

log() {
    # /tmp is RAM; keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
        mv "$LOG" "$LOG.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

finish() {
    log "stopping"
    kill $tail_pid $tick_pid 2>/dev/null
    # EOF makes awk write the final state.
    exec 3>&-
    wait $awk_pid
    rm -f "$FIFO" "${PIDFILE:-/tmp/tankwatch.pid}"
    exit 0
}

while [ ! -d "$(dirname "$DATA_LOG")" ] || [ ! -d "$(dirname "$MANAGER_LOG")" ]; do
    sleep 5
done

mkdir -p "$DIR"
rm -f "$FIFO"
mkfifo "$FIFO"
log "started"

trap finish TERM INT HUP

awk -f "$AWK_PROG" \
    -v STATE_FILE="$DIR/state.json" -v CAL_LOG="$DIR/calibration.log" \
    -v RESET_CLEAN="$FLAGS-clean" -v RESET_DIRTY="$FLAGS-dirty" \
    -v CLEAN_CAPACITY_ML="$CLEAN_CAPACITY_ML" -v DIRTY_CAPACITY_ML="$DIRTY_CAPACITY_ML" \
    -v FLOW_ML_PER_UNIT_S="$FLOW_ML_PER_UNIT_S" -v REFILL_ML_PER_S="$REFILL_ML_PER_S" \
    -v DIRTY_ML_PER_PUMP_S="$DIRTY_ML_PER_PUMP_S" -v LOW_PCT="$LOW_PCT" \
    < "$FIFO" 2>> "$LOG" &
awk_pid=$!
exec 3> "$FIFO"

# The logs only grow while the robot is active, so while a reset is pending
# feed awk a line every second to get it noticed.
tick() {
    while sleep 1; do
        if [ -e "$FLAGS-clean" ] || [ -e "$FLAGS-dirty" ]; then
            printf '\n#tick\n'
        fi
    done
}
tick >&3 &
tick_pid=$!

tail -q -n 0 -F "$DATA_LOG" "$MANAGER_LOG" >&3 2>/dev/null &
tail_pid=$!

wait "$awk_pid"
log "awk exited, stopping"
finish
