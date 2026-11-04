#!/bin/sh
# Runs on the robot. Keeps a patched copy of manager_node bind-mounted over
# /usr/navi/manager_node, so a room clean follows the selected order
# (see docs/room-order-investigation.md). Started at boot from
# /oem/_root_postboot.sh by install.sh.
#
#   roomorder.sh [apply]   mount the patched copy, restart manager_node (default, boot)
#   roomorder.sh prepare   create the patched copy from the robot's own binary
#   roomorder.sh remove    unmount, restart manager_node so the stock binary runs
#   roomorder.sh status    show the state
#
# manager_node is not started by hand. /usr/bin/track watches it, and when it
# dies, runs "cd /usr/navi && ./stop* ; ./start*", which restarts ALL nodes
# (docs/modifying-firmware.md). So a restart here means: kill manager_node and
# wait for track to bring the whole stack back.

ACTION=${1:-apply}
DIR=${DIR:-/userdata/roomorder}
PATCHED=${PATCHED:-$DIR/manager_node}
TARGET=${TARGET:-/usr/navi/manager_node}
LOG=${LOG:-/tmp/roomorder.log}
HOOK=${HOOK:-/oem/_root_postboot.sh}
MANAGER_PID=${MANAGER_PID:-/var/run/manager.pid}

# manager_node of the firmware this patch was written for.
ORIG_SHA=049e9d56d2c0dee98209871deb74fa31006b3bcd730e8b8abaf2d072215b50da
# The same file with the 4 bytes at OFFSET replaced (sha256 of the result).
PATCHED_SHA=c91f58059e761194c8196bde2bd82dc348a9935427f241ff773b3fac6e477620
OFFSET=$((0x47d8e8))
ORIG_BYTES="60070034"      # cbz w0, 0x87d9d4
PATCH_BYTES='\037\040\003\325'   # 1f 20 03 d5 = nop, in octal for printf
PATCH_HEX="1f2003d5"

WAIT_UP=${WAIT_UP:-180}       # seconds to wait for manager_node at boot
WAIT_RESTART=${WAIT_RESTART:-240}   # seconds to wait for track's full restart
MIN_FREE_KB=${MIN_FREE_KB:-20480}

log() {
    # /tmp is RAM; keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 65536 ]; then
        mv "$LOG" "$LOG.old"
    fi
    echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"
    echo "$*"
}

sha_of() { sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

bytes_at() {
    # 4 bytes at OFFSET of $1 as hex, e.g. 60070034
    dd if="$1" bs=1 skip=$OFFSET count=4 2>/dev/null | od -An -tx1 | sed 's/ //g'
}

is_mounted() { grep -q " $TARGET " /proc/mounts; }

manager_pid() { pidof manager_node 2>/dev/null | cut -d' ' -f1; }

# sha256 of the executable a running process was started from.
running_sha() {
    [ -n "$1" ] && [ -e "/proc/$1/exe" ] && sha_of "/proc/$1/exe"
}

# Detach the bind mount. Lazy, because a running manager_node keeps it busy.
unmount_all() {
    n=0
    while is_mounted && [ $n -lt 5 ]; do
        umount -l "$TARGET" 2>/dev/null
        n=$((n + 1))
    done
    ! is_mounted
}

# Kill manager_node and wait until track has restarted it from the file whose
# sha256 is $1. Returns non-zero on timeout.
restart_manager() {
    want=$1
    if [ -e /oem/midea_autorun ]; then
        log "debug mode (/oem/midea_autorun exists): track doesn't restart nodes; not restarting"
        return 2
    fi
    old=$(manager_pid)
    if [ -n "$old" ] && [ "$(running_sha "$old")" = "$want" ]; then
        log "manager_node (pid $old) already runs the wanted binary"
        return 0
    fi
    log "killing manager_node (pid ${old:-none}); track restarts all nodes, this takes a while"
    [ -n "$old" ] && kill -9 "$old" 2>/dev/null
    i=0
    while [ $i -lt "$WAIT_RESTART" ]; do
        sleep 2
        i=$((i + 2))
        pid=$(manager_pid)
        if [ -n "$pid" ] && [ "$pid" != "$old" ]; then
            if [ "$(running_sha "$pid")" = "$want" ]; then
                log "manager_node restarted (pid $pid) after ${i}s"
                return 0
            fi
            log "manager_node restarted (pid $pid) with an unexpected binary"
            return 1
        fi
    done
    log "manager_node did not come back within ${WAIT_RESTART}s"
    return 1
}

prepare() {
    [ "$(uname -m)" = aarch64 ] || { log "error: unexpected architecture $(uname -m)"; return 1; }
    if is_mounted; then
        # The stock file is hidden under the mount; the patched copy is the proof.
        log "error: $TARGET is already a mount point, run '$0 remove' first"
        return 1
    fi
    got=$(sha_of "$TARGET")
    if [ "$got" != "$ORIG_SHA" ]; then
        log "error: $TARGET has sha256 ${got:-unreadable}, expected $ORIG_SHA (other firmware version?), refusing"
        return 1
    fi
    b=$(bytes_at "$TARGET")
    if [ "$b" != "$ORIG_BYTES" ]; then
        log "error: bytes at 0x47d8e8 are '$b', expected $ORIG_BYTES, refusing"
        return 1
    fi
    mkdir -p "$DIR" || return 1
    free=$(df -k "$DIR" | tail -n 1 | awk '{print $(NF-2)}')
    if [ -n "$free" ] && [ "$free" -lt "$MIN_FREE_KB" ] 2>/dev/null; then
        log "error: only $free kB free in $DIR, need $MIN_FREE_KB kB"
        return 1
    fi
    rm -f "$PATCHED.new"
    cp "$TARGET" "$PATCHED.new" || { rm -f "$PATCHED.new"; log "error: copy failed (disk full?)"; return 1; }
    printf "$PATCH_BYTES" | dd of="$PATCHED.new" bs=1 seek=$OFFSET conv=notrunc 2>/dev/null
    b=$(bytes_at "$PATCHED.new")
    got=$(sha_of "$PATCHED.new")
    if [ "$b" != "$PATCH_HEX" ] || [ "$got" != "$PATCHED_SHA" ]; then
        rm -f "$PATCHED.new"
        log "error: patched copy is wrong (bytes '$b', sha256 '$got', expected $PATCH_HEX / $PATCHED_SHA)"
        return 1
    fi
    chmod 755 "$PATCHED.new"
    sync
    mv "$PATCHED.new" "$PATCHED" || return 1
    log "created $PATCHED ($PATCHED_SHA)"
}

apply() {
    # Wait for the stack that start-dushu launched, so track has settled and
    # we don't race its first scan of the pid files.
    waited=0
    while [ -z "$(manager_pid)" ] && [ $waited -lt "$WAIT_UP" ]; do
        sleep 2
        waited=$((waited + 2))
    done
    [ -n "$(manager_pid)" ] || { log "manager_node isn't running after ${WAIT_UP}s, giving up"; return 1; }
    # Give the stack time to finish booting before the restart.
    up=$(cut -d. -f1 /proc/uptime)
    [ "$up" -lt 90 ] 2>/dev/null && sleep $((90 - up))

    if is_mounted; then
        log "$TARGET is already mounted"
    else
        got=$(sha_of "$TARGET")
        if [ "$got" != "$ORIG_SHA" ]; then
            log "$TARGET has sha256 ${got:-unreadable}, not the firmware this was made for ($ORIG_SHA); skipping (firmware updated?)"
            return 1
        fi
        if [ "$(sha_of "$PATCHED")" != "$PATCHED_SHA" ]; then
            log "$PATCHED is missing or has an unexpected sha256; run ./install.sh roomorder-install again"
            return 1
        fi
        mount --bind "$PATCHED" "$TARGET" || { log "mount --bind failed"; return 1; }
        if [ "$(sha_of "$TARGET")" != "$PATCHED_SHA" ]; then
            log "mount didn't expose the patched file, unmounting"
            unmount_all
            return 1
        fi
        log "mounted $PATCHED over $TARGET"
    fi

    restart_manager "$PATCHED_SHA"
    rc=$?
    if [ $rc -eq 1 ]; then
        log "rolling back: unmounting the patched binary"
        unmount_all
        return 1
    fi
    return $rc
}

remove() {
    unmount_all || { log "error: could not unmount $TARGET"; return 1; }
    log "unmounted $TARGET"
    restart_manager "$ORIG_SHA"
}

status() {
    if is_mounted; then echo "mount: active ($TARGET)"; else echo "mount: not active"; fi
    cur=$(sha_of "$TARGET")
    if [ "$cur" = "$PATCHED_SHA" ]; then s="patched"
    elif [ "$cur" = "$ORIG_SHA" ]; then s="stock"
    else s="unknown firmware"; fi
    echo "$TARGET: $cur ($s)"
    echo "stock sha256:   $ORIG_SHA"
    echo "patched sha256: $PATCHED_SHA"
    if [ -f "$PATCHED" ]; then
        p=$(sha_of "$PATCHED")
        [ "$p" = "$PATCHED_SHA" ] && echo "patched copy: ok ($PATCHED)" || echo "patched copy: WRONG sha256 $p"
    else
        echo "patched copy: missing"
    fi
    grep -q 'j15-roomorder$' "$HOOK" 2>/dev/null && echo "boot hook: installed" || echo "boot hook: missing"
    pid=$(manager_pid)
    if [ -n "$pid" ]; then
        r=$(running_sha "$pid")
        if [ "$r" = "$PATCHED_SHA" ]; then s="patched"
        elif [ "$r" = "$ORIG_SHA" ]; then s="stock"
        else s="unknown"; fi
        echo "manager_node: running (pid $pid, $s binary)"
    else
        echo "manager_node: not running"
    fi
    echo "--- last log lines ---"
    tail -n 10 "$LOG" 2>/dev/null || echo "(no log)"
}

case $ACTION in
apply) apply ;;
prepare) prepare ;;
remove) remove ;;
status) status ;;
*) echo "usage: $0 [apply|prepare|remove|status]" >&2; exit 2 ;;
esac
