#!/bin/sh
# Runs on the robot. Copies the vendor logs from the RAM-backed /userdata/logs
# to persistent storage so they survive reboots. Started at boot from
# /oem/_root_postboot.sh by install.sh.

CONF=${CONF:-/userdata/persistlog.conf}
LOG=${LOG:-/tmp/persistlog.log}
LOGS=${LOGS:-/userdata/logs}
DATA=${DATA:-/userdata}
PSTORE=${PSTORE:-/sys/fs/pstore}
STATE=${STATE:-/tmp/persistlog-state}
STORE=${STORE:-/userdata/persist-logs}
MAX_MB=64
MIN_FREE_MB=50
INTERVAL=600
EXTRA_LOGS="/tmp/valetudo.log /tmp/camstream.log"
[ -f "$CONF" ] && . "$CONF"

echo $$ > "${PIDFILE:-/tmp/persistlog.pid}"

log() {
    # /tmp is RAM; keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
        mv "$LOG" "$LOG.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
}

copy_atomic() {
    if nice -n 19 cp "$1" "$2.tmp" 2>/dev/null && mv "$2.tmp" "$2"; then
        return 0
    fi
    rm -f "$2.tmp"
    log "copy failed: $1"
    return 1
}

# Gzip a log that is still being written, if it changed.
snapshot() {
    [ -f "$1" ] && [ ! -L "$1" ] || return
    size=$(wc -c < "$1" 2>/dev/null) || return
    key=$STATE/$(echo "$1" | tr -c 'A-Za-z0-9\n' _)
    [ "$(cat "$key" 2>/dev/null)" = "$size" ] && return
    mkdir -p "$(dirname "$2")"
    if nice -n 19 gzip -c "$1" > "$2.tmp" 2>/dev/null && mv "$2.tmp" "$2"; then
        echo "$size" > "$key"
    else
        rm -f "$2.tmp"
    fi
}

snapshot_dmesg() {
    size=$(dmesg 2>/dev/null | wc -c)
    [ "$size" -gt 0 ] || return
    key=$STATE/dmesg
    [ "$(cat "$key" 2>/dev/null)" = "$size" ] && return
    if dmesg 2>/dev/null | nice -n 19 gzip -c > "$BOOT/dmesg.partial.gz.tmp" \
            && mv "$BOOT/dmesg.partial.gz.tmp" "$BOOT/dmesg.partial.gz"; then
        echo "$size" > "$key"
    else
        rm -f "$BOOT/dmesg.partial.gz.tmp"
    fi
}

copy_rotated() {
    for f in "$LOGS"/app/*/*.log.gz; do
        [ -e "$f" ] || continue
        node=$(basename "$(dirname "$f")")
        name=$(basename "$f")
        dest=$BOOT/app/$node/$name
        # Retention may delete copies, so track what was copied instead of testing dest.
        if ! grep -qxF "$node/$name" "$BOOT/.copied" 2>/dev/null; then
            mkdir -p "$BOOT/app/$node"
            copy_atomic "$f" "$dest" || continue
            echo "$node/$name" >> "$BOOT/.copied"
        fi
        # The complete file replaces the snapshot of the same log.
        rm -f "$BOOT/app/$node/${name%.gz}.partial.gz"
    done
}

# logrotate-style names are reused, so name them by content.
copy_ulog() {
    for f in "$LOGS"/app/data/ulog_mcu.ulg-*.gz; do
        [ -e "$f" ] || continue
        sum=$(md5sum "$f" 2>/dev/null | cut -c1-12)
        [ -n "$sum" ] || continue
        grep -qxF "data/ulog_mcu.$sum.gz" "$BOOT/.copied" 2>/dev/null && continue
        mkdir -p "$BOOT/app/data"
        copy_atomic "$f" "$BOOT/app/data/ulog_mcu.$sum.gz" \
            && echo "data/ulog_mcu.$sum.gz" >> "$BOOT/.copied"
    done
}

copy_crash() {
    for f in "$LOGS"/crash/*.txt "$LOGS"/crash/coredump/*-bt-*; do
        [ -f "$f" ] || continue
        dest=$BOOT/crash/$(basename "$f")
        if [ -e "$dest" ] && [ "$(wc -c < "$f")" = "$(wc -c < "$dest")" ]; then
            continue
        fi
        mkdir -p "$BOOT/crash"
        copy_atomic "$f" "$dest"
    done
}

snapshot_active() {
    for f in "$LOGS"/app/*/*.log; do
        [ -e "$f" ] || continue
        node=$(basename "$(dirname "$f")")
        snapshot "$f" "$BOOT/app/$node/$(basename "$f").partial.gz"
    done
    snapshot "$LOGS/app/data/ulog_mcu.ulg" "$BOOT/app/data/ulog_mcu.ulg.partial.gz"
    snapshot "$LOGS/app/planner/tasks_info_log.txt" "$BOOT/app/planner/tasks_info_log.txt.partial.gz"
    for n in system.log dmesg.log; do
        snapshot "$LOGS/system/$n" "$BOOT/system/$n.partial.gz"
    done
    for f in $EXTRA_LOGS; do
        snapshot "$f" "$BOOT/extra/$(basename "$f").partial.gz"
    done
    snapshot_dmesg
}

retention() {
    while [ "$(du -sk "$STORE" 2>/dev/null | cut -f1)" -gt $((MAX_MB * 1024)) ] 2>/dev/null; do
        old=
        n=0
        for d in "$STORE"/boot-*; do
            [ -d "$d" ] || continue
            n=$((n + 1))
            [ "$d" = "$BOOT" ] && continue
            [ -n "$old" ] || old=$d
        done
        if [ "$n" -gt 1 ] && [ -n "$old" ]; then
            log "retention: removing $old"
            rm -rf "$old"
            continue
        fi
        # Copy time is chronological within a boot.
        files=$(find "$BOOT" \( -name '*.log.gz' -o -name 'ulog_mcu.*.gz' \) ! -name '*.partial.gz' 2>/dev/null)
        [ -n "$files" ] || break
        old=$(echo "$files" | xargs ls -tr 2>/dev/null | head -n 1)
        [ -n "$old" ] || break
        log "retention: removing $old"
        rm -f "$old" || break
    done
}

sync_cycle() {
    free_kb=$(df -k "$DATA" 2>/dev/null | awk 'NR==2 {print $4}')
    if [ "${free_kb:-0}" -lt $((MIN_FREE_MB * 1024)) ]; then
        log "low space on $DATA (${free_kb:-?} KB free), not copying"
    else
        mkdir -p "$STATE"
        copy_rotated
        copy_ulog
        copy_crash
        snapshot_active
    fi
    retention
}

finish() {
    [ -z "$nap" ] || kill "$nap" 2>/dev/null
    log "stopping, final sync"
    sync_cycle
    rm -f "${PIDFILE:-/tmp/persistlog.pid}"
    exit 0
}

while [ ! -d "$LOGS/app" ]; do
    sleep 5
done

mkdir -p "$STORE"
boot_id=$(cat "${BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null)
BOOT=
last=$(ls -d "$STORE"/boot-* 2>/dev/null | sort | tail -n 1)
# A restart within the same boot keeps writing to the same directory.
if [ -n "$boot_id" ] && [ -n "$last" ] && grep -qxF "boot_id: $boot_id" "$last/boot-info.txt" 2>/dev/null; then
    BOOT=$last
    log "restarted, continuing in $BOOT"
else
    count=$(cat "$STORE/.bootcount" 2>/dev/null)
    case $count in ''|*[!0-9]*) count=0 ;; esac
    count=$((count + 1))
    echo "$count" > "$STORE/.bootcount"
    BOOT=$STORE/boot-$(printf '%04d' "$count")
    mkdir -p "$BOOT"
    {
        echo "date: $(date)"
        echo "uptime: $(cat /proc/uptime 2>/dev/null)"
        echo "version: $(cat /etc/versionCode 2>/dev/null)"
        echo "boot_id: $boot_id"
    } > "$BOOT/boot-info.txt"
    log "started, writing to $BOOT"

    if [ -n "$(ls -A "$PSTORE" 2>/dev/null)" ]; then
        mkdir -p "$BOOT/pstore-previous-boot"
        cp -R "$PSTORE"/. "$BOOT/pstore-previous-boot/" 2>/dev/null
        log "saved pstore from previous boot"
    fi
fi

nap=
trap finish TERM INT HUP

while true; do
    sync_cycle
    sleep "$INTERVAL" &
    nap=$!
    wait "$nap"
    nap=
done
