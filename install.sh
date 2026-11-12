#!/usr/bin/env bash
# Installs camstream, persistlog, tankwatch, wifimap, roomorder, obstaclegap and a patched Valetudo on a rooted Midea J15 over SSH. Run from your computer.
#
#   ./install.sh install   <robot-ip> [ssh options]   camstream: copy files, add boot hook, start
#   ./install.sh uninstall <robot-ip> [ssh options]   camstream: stop, remove files and boot hook
#   ./install.sh restart   <robot-ip> [ssh options]   camstream: restart (e.g. after editing config)
#   ./install.sh status    <robot-ip> [ssh options]   camstream: show whether it is running
#   ./install.sh check     <robot-ip> [ssh options]   run the camera pipeline diagnostic
#   ./install.sh collect-logs <robot-ip> [ssh options]  save robot logs + dmesg to a local .tar
#   ./install.sh persistlog-install   <robot-ip> [ssh options]  keep vendor logs across reboots
#   ./install.sh persistlog-uninstall <robot-ip> [ssh options]  stop and remove (saved logs are kept)
#   ./install.sh persistlog-status    <robot-ip> [ssh options]  show state and saved boots
#   ./install.sh tankwatch-install    <robot-ip> [ssh options]  estimate the dock's water tank levels
#   ./install.sh tankwatch-uninstall  <robot-ip> [ssh options]  stop and remove (state is renamed, calibration log is kept)
#   ./install.sh tankwatch-status     <robot-ip> [ssh options]  show state and recent log
#   ./install.sh wifimap-install      <robot-ip> [ssh options]  record Wi-Fi signal strength by position while cleaning
#   ./install.sh wifimap-uninstall    <robot-ip> [ssh options]  stop and remove (recorded samples are kept)
#   ./install.sh wifimap-status       <robot-ip> [ssh options]  show recorded jobs and the current signal
#   ./install.sh roomorder-install    <robot-ip> [ssh options]  clean rooms in the selected order (patches manager_node)
#   ./install.sh roomorder-uninstall  <robot-ip> [ssh options]  restore the stock manager_node
#   ./install.sh roomorder-status     <robot-ip> [ssh options]  show whether the patch is active
#   ./install.sh obstaclegap-install   <robot-ip> [ssh options]  turn away from recognised objects at 270 mm, not 350 (patches planner_node)
#   ./install.sh obstaclegap-uninstall <robot-ip> [ssh options]  restore the stock planner_node
#   ./install.sh obstaclegap-status    <robot-ip> [ssh options]  show whether the patch is active
#   ./install.sh valetudo-install     <robot-ip> [ssh options]  replace Valetudo with build/valetudo-aarch64
#   ./install.sh valetudo-uninstall   <robot-ip> [ssh options]  restore the stock Valetudo binary
#   ./install.sh valetudo-status      <robot-ip> [ssh options]  show whether the patched build is installed
#   ./install.sh valetudo-restart     <robot-ip> [ssh options]  restart Valetudo (keeps its environment and config path)
#
# Anything after the robot address is passed to ssh unchanged, e.g.
#   ./install.sh install 192.168.1.50 -i ~/.ssh/robot -p 2222

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=/oem/_root_postboot.sh
MARKER="# j15-camstream"
PL_MARKER="# j15-persistlog"
TW_MARKER="# j15-tankwatch"
WM_MARKER="# j15-wifimap"
RO_MARKER="# j15-roomorder"
OG_MARKER="# j15-obstaclegap"

usage() {
    sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

case ${1:-} in -h|--help) usage 0 ;; esac
[ $# -ge 2 ] || usage 2
ACTION=$1
ROBOT=$2
shift 2
SSH_ARGS=("$@")

case $ROBOT in
-*)
    echo "error: robot address must come before ssh options (got '$ROBOT')" >&2
    usage 2
    ;;
esac

# User options go first: for repeated -o options ssh keeps the first value,
# so a user's -o ConnectTimeout=... overrides the default below.
# (${arr[@]+...} keeps bash 3.2 on macOS happy with set -u and an empty array.)
remote() {
    ssh ${SSH_ARGS[@]+"${SSH_ARGS[@]}"} -o ConnectTimeout=10 "root@$ROBOT" "$@"
}

# dropbear on the robot often has no scp/sftp, so files go over plain ssh.
push() { remote "cat > '$2.new' && chmod $3 '$2.new' && mv '$2.new' '$2'" < "$1"; }

sha256_local() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

stop_remote() {
    remote 'sh -s' <<'EOF'
if [ -f /tmp/camstream.pid ]; then
    kill "$(cat /tmp/camstream.pid)" 2>/dev/null
    rm -f /tmp/camstream.pid
fi
killall camstream 2>/dev/null
true
EOF
}

stop_persistlog() {
    remote 'sh -s' <<'EOF'
if [ -f /tmp/persistlog.pid ]; then
    pid=$(cat /tmp/persistlog.pid)
    kill "$pid" 2>/dev/null
    # It does a final sync on TERM; wait for that so a new instance doesn't overlap.
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    rm -f /tmp/persistlog.pid
fi
command -v pkill >/dev/null 2>&1 && pkill -f /userdata/persistlog.sh 2>/dev/null
true
EOF
}

stop_tankwatch() {
    remote 'sh -s' <<'EOF'
if [ -f /tmp/tankwatch.pid ]; then
    pid=$(cat /tmp/tankwatch.pid)
    kill "$pid" 2>/dev/null
    # It writes the state on TERM; wait for that so a new instance doesn't overlap.
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    rm -f /tmp/tankwatch.pid
fi
true
EOF
}

stop_wifimap() {
    remote 'sh -s' <<'EOF'
if [ -f /tmp/wifimap.pid ]; then
    pid=$(cat /tmp/wifimap.pid)
    kill "$pid" 2>/dev/null
    # It closes the job file on TERM; wait for that so a new instance doesn't overlap.
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    rm -f /tmp/wifimap.pid
fi
true
EOF
}

tankwatch_valetudo_note() {
    if remote 'sh -s' <<'EOF'
[ -f /userdata/valetudo.stock ] && [ "$(sha256sum /userdata/valetudo | cut -d' ' -f1)" != "$(sha256sum /userdata/valetudo.stock | cut -d' ' -f1)" ]
EOF
    then
        echo
        echo "The installed Valetudo is the patched build; it $1 after a restart:"
        echo "  ./install.sh valetudo-restart $ROBOT"
    fi
    return 0
}

# Shell functions run on the robot. The running Valetudo's VALETUDO_* environment
# is captured before it is stopped, so a manual start keeps the same config path.
VT_FUNCS=$(cat <<'EOF'
# The stock busybox has tr and nohup as applets but no links for them.
command -v tr >/dev/null 2>&1 || tr() { busybox tr "$@"; }
NOHUP=nohup
command -v nohup >/dev/null 2>&1 || NOHUP="busybox nohup"
VT=/userdata/valetudo
STATE=/userdata/valetudo.patched
vt_pid() { pidof valetudo | cut -d' ' -f1; }
vt_capture() {
    : > /tmp/valetudo.env
    pid=$(vt_pid)
    [ -n "$pid" ] && tr '\0' '\n' < "/proc/$pid/environ" | grep '^VALETUDO_' > /tmp/valetudo.env
    CFG=$(sed -n 's/^VALETUDO_CONFIG_PATH=//p' /tmp/valetudo.env)
    if [ -z "$CFG" ]; then
        for f in /userdata/valetudo_config.json /userdata/valetudo/valetudo_config.json /data/valetudo_config.json; do
            [ -f "$f" ] && CFG=$f && break
        done
    fi
    # Valetudo wasn't running: start it with the config path it would get at boot.
    [ -n "$CFG" ] && ! grep -q '^VALETUDO_CONFIG_PATH=' /tmp/valetudo.env \
        && echo "VALETUDO_CONFIG_PATH=$CFG" >> /tmp/valetudo.env
    true
}
vt_stop() {
    pid=$(vt_pid)
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    i=0
    while kill -0 "$pid" 2>/dev/null && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
    kill -9 "$pid" 2>/dev/null
    true
}
vt_start() {
    i=0
    while [ -z "$(vt_pid)" ] && [ $i -lt 15 ]; do sleep 1; i=$((i + 1)); done
    if [ -n "$(vt_pid)" ]; then
        echo "  Valetudo restarted by the robot (pid $(vt_pid))"
        return 0
    fi
    echo "  not restarted by the robot, starting it manually"
    set --
    while IFS= read -r l; do set -- "$@" "$l"; done < /tmp/valetudo.env
    env ${1+"$@"} $NOHUP "$VT" >/tmp/valetudo.log 2>&1 </dev/null &
    sleep 3
    if [ -n "$(vt_pid)" ]; then echo "  started (pid $(vt_pid))"; else echo "  error: Valetudo did not start, see /tmp/valetudo.log" >&2; return 1; fi
}
vt_updater() {
    [ -f "$CFG" ] && sed -i "/\"updater\"/,/\"enabled\"/ s/\"enabled\": *[a-z]*/\"enabled\": $1/" "$CFG"
}
vt_updater_state() {
    [ -f "$CFG" ] && sed -n '/"updater"/,/"enabled"/ s/.*"enabled": *\([a-z]*\).*/\1/p' "$CFG" | head -n 1
}
EOF
)

on_robot() { { printf '%s\n' "$VT_FUNCS"; cat; } | remote 'sh -s'; }

start_remote() {
    remote '/userdata/camstream.sh >/dev/null 2>&1 </dev/null &'
}

preflight() {
    echo "Checking robot at $ROBOT..."
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -e /usr/lib/libsample_plugin.so ] || err "/usr/lib/libsample_plugin.so missing (not a Midea J15 firmware?)"
[ -e /usr/navi/video_node ] || err "/usr/navi/video_node missing (not a Midea J15 firmware?)"
ubus -s /tmp/ubus.sock list media.engine.control >/dev/null 2>&1 \
    || err "ubus object media.engine.control not found (is video_node running?)"
[ -d /userdata ] || err "/userdata missing"
echo "  ok: $(grep -m1 Hardware /proc/cpuinfo | cut -d: -f2 | sed 's/^ //')"
EOF
}

case $ACTION in
install)
    if [ ! -x "$HERE/build/camstream" ]; then
        echo "build/camstream not found, building..."
        make -C "$HERE" build/camstream
    fi
    preflight
    stop_remote
    echo "Copying files..."
    push "$HERE/build/camstream" /userdata/camstream 755
    push "$HERE/robot/camstream.sh" /userdata/camstream.sh 755
    push "$HERE/robot/camera-check.sh" /userdata/camera-check.sh 755
    if remote '[ -f /userdata/camstream.conf ]'; then
        echo "  keeping existing /userdata/camstream.conf"
    else
        push "$HERE/robot/camstream.conf" /userdata/camstream.conf 644
    fi
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$MARKER\$' $HOOK || echo '/userdata/camstream.sh >/dev/null 2>&1 &  $MARKER' >> $HOOK
chmod +x $HOOK
EOF
    start_remote
    sleep 2
    port=$(remote '. /userdata/camstream.conf; echo "$PORT"')
    echo
    echo "Installed. Test with:"
    echo "  ffplay -fflags nobuffer -f h264 tcp://$ROBOT:$port"
    ;;
uninstall)
    stop_remote
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$MARKER\$/d' $HOOK
rm -f /userdata/camstream /userdata/camstream.sh /userdata/camstream.conf \
      /userdata/camera-check.sh /tmp/camstream.log /tmp/camstream.log.old
EOF
    echo "Uninstalled."
    ;;
restart)
    stop_remote
    start_remote
    echo "Restarted."
    ;;
status)
    remote 'sh -s' <<'EOF'
PORT=8555
[ -f /userdata/camstream.conf ] && . /userdata/camstream.conf
if pidof camstream >/dev/null; then
    echo "camstream: running (pid $(pidof camstream))"
else
    echo "camstream: not running"
fi
netstat -ltn 2>/dev/null | grep -q ":$PORT " && echo "listening: tcp/$PORT" || echo "listening: no"
grep -q 'j15-camstream$' /oem/_root_postboot.sh 2>/dev/null && echo "boot hook: installed" || echo "boot hook: missing"
echo "--- last log lines ---"
tail -n 10 /tmp/camstream.log 2>/dev/null || echo "(no log)"
EOF
    ;;
check)
    push "$HERE/robot/camera-check.sh" /tmp/camera-check.sh 755
    remote /tmp/camera-check.sh || true
    ;;
collect-logs)
    # /userdata/logs is RAM-backed and lost at reboot, so grab it first.
    out="j15-logs-$(date +%Y%m%d-%H%M%S).tar"
    echo "Collecting logs into $out..."
    remote 'dmesg > /tmp/dmesg-now.txt; set -- /userdata/logs/app /tmp/dmesg-now.txt; [ -d /userdata/persist-logs ] && set -- "$@" /userdata/persist-logs; tar -cf - "$@" 2>/dev/null; rm -f /tmp/dmesg-now.txt' > "$out"
    echo "Saved $out ($(du -h "$out" | cut -f1)). It contains device logs; don't share it publicly."
    ;;
persistlog-install)
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -d /userdata ] || err "/userdata missing"
EOF
    stop_persistlog
    echo "Copying files..."
    push "$HERE/robot/persistlog.sh" /userdata/persistlog.sh 755
    if remote '[ -f /userdata/persistlog.conf ]'; then
        echo "  keeping existing /userdata/persistlog.conf"
    else
        push "$HERE/robot/persistlog.conf" /userdata/persistlog.conf 644
    fi
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$PL_MARKER\$' $HOOK || echo '/userdata/persistlog.sh >/dev/null 2>&1 &  $PL_MARKER' >> $HOOK
chmod +x $HOOK
EOF
    remote '/userdata/persistlog.sh >/dev/null 2>&1 </dev/null &'
    echo
    echo "Installed. Logs are saved to /userdata/persist-logs; see ./install.sh persistlog-status $ROBOT"
    ;;
persistlog-uninstall)
    stop_persistlog
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$PL_MARKER\$/d' $HOOK
rm -rf /userdata/persistlog.sh /userdata/persistlog.conf /tmp/persistlog.* /tmp/persistlog-state
EOF
    echo "Uninstalled. The saved logs in /userdata/persist-logs were kept."
    echo "Remove them with:  ssh root@$ROBOT rm -rf /userdata/persist-logs"
    ;;
persistlog-status)
    remote 'sh -s' <<'EOF'
if [ -f /tmp/persistlog.pid ] && kill -0 "$(cat /tmp/persistlog.pid)" 2>/dev/null; then
    echo "persistlog: running (pid $(cat /tmp/persistlog.pid))"
else
    echo "persistlog: not running"
fi
grep -q 'j15-persistlog$' /oem/_root_postboot.sh 2>/dev/null && echo "boot hook: installed" || echo "boot hook: missing"
echo "store: $(du -sh /userdata/persist-logs 2>/dev/null | cut -f1)"
ls -d /userdata/persist-logs/boot-* 2>/dev/null
echo "--- last log lines ---"
tail -n 10 /tmp/persistlog.log 2>/dev/null || echo "(no log)"
EOF
    ;;
tankwatch-install)
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -d /userdata ] || err "/userdata missing"
EOF
    stop_tankwatch
    echo "Copying files..."
    push "$HERE/robot/tankwatch.sh" /userdata/tankwatch.sh 755
    push "$HERE/robot/tankwatch.awk" /userdata/tankwatch.awk 644
    if remote '[ -f /userdata/tankwatch.conf ]'; then
        echo "  keeping existing /userdata/tankwatch.conf"
    else
        push "$HERE/robot/tankwatch.conf" /userdata/tankwatch.conf 644
    fi
    remote "sh -s" <<'EOF'
mkdir -p /userdata/tankwatch
if [ ! -f /userdata/tankwatch/state.json ]; then
    now=$(date +%s)
    printf '{"version":1,"updated":%s,"clean":{"used_ml":0,"capacity_ml":4000,"remaining_pct":100,"low":false,"reset":%s},"dirty":{"used_ml":0,"capacity_ml":3400,"remaining_pct":100,"low":false,"reset":%s}}\n' \
        "$now" "$now" "$now" > /userdata/tankwatch/state.json
fi
EOF
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$TW_MARKER\$' $HOOK || echo '/userdata/tankwatch.sh >/dev/null 2>&1 &  $TW_MARKER' >> $HOOK
chmod +x $HOOK
EOF
    remote '/userdata/tankwatch.sh >/dev/null 2>&1 </dev/null &'
    echo
    echo "Installed. The estimates are in /userdata/tankwatch/state.json; see ./install.sh tankwatch-status $ROBOT"
    echo "A first install assumes the clean tank is full and the dirty tank empty."
    echo "After refilling or emptying a tank, reset it with:"
    echo "  ssh root@$ROBOT /userdata/tankwatch.sh reset clean|dirty"
    tankwatch_valetudo_note "shows the tank levels"
    ;;
tankwatch-uninstall)
    stop_tankwatch
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$TW_MARKER\$/d' $HOOK
rm -rf /userdata/tankwatch.sh /userdata/tankwatch.awk /userdata/tankwatch.conf /tmp/tankwatch.*
[ -f /userdata/tankwatch/state.json ] && mv /userdata/tankwatch/state.json /userdata/tankwatch/state.json.uninstalled
true
EOF
    echo "Uninstalled. The calibration log in /userdata/tankwatch was kept, and the state"
    echo "was renamed to state.json.uninstalled so that Valetudo stops showing it."
    echo "Remove them with:  ssh root@$ROBOT rm -rf /userdata/tankwatch"
    tankwatch_valetudo_note "stops showing the tank levels"
    ;;
tankwatch-status)
    remote 'sh -s' <<'EOF'
if [ -f /tmp/tankwatch.pid ] && kill -0 "$(cat /tmp/tankwatch.pid)" 2>/dev/null; then
    echo "tankwatch: running (pid $(cat /tmp/tankwatch.pid))"
else
    echo "tankwatch: not running"
fi
grep -q 'j15-tankwatch$' /oem/_root_postboot.sh 2>/dev/null && echo "boot hook: installed" || echo "boot hook: missing"
echo "--- state ---"
cat /userdata/tankwatch/state.json 2>/dev/null || echo "(no state)"
echo "--- calibration log ---"
tail -n 10 /userdata/tankwatch/calibration.log 2>/dev/null || echo "(none yet)"
echo "--- last log lines ---"
tail -n 10 /tmp/tankwatch.log 2>/dev/null || echo "(no log)"
EOF
    ;;
wifimap-install)
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -d /userdata ] || err "/userdata missing"
[ -e /proc/net/wireless ] || err "/proc/net/wireless missing"
EOF
    stop_wifimap
    echo "Copying files..."
    push "$HERE/robot/wifimap.sh" /userdata/wifimap.sh 755
    push "$HERE/robot/wifimap.awk" /userdata/wifimap.awk 644
    if remote '[ -f /userdata/wifimap.conf ]'; then
        echo "  keeping existing /userdata/wifimap.conf"
    else
        push "$HERE/robot/wifimap.conf" /userdata/wifimap.conf 644
    fi
    remote 'mkdir -p /userdata/wifimap'
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$WM_MARKER\$' $HOOK || echo '/userdata/wifimap.sh >/dev/null 2>&1 &  $WM_MARKER' >> $HOOK
chmod +x $HOOK
EOF
    remote '/userdata/wifimap.sh >/dev/null 2>&1 </dev/null &'
    echo
    echo "Installed. Samples are recorded while the robot cleans, into /userdata/wifimap;"
    echo "see ./install.sh wifimap-status $ROBOT. Draw the heatmap with:"
    echo "  tools/wifimap.py $ROBOT"
    ;;
wifimap-uninstall)
    stop_wifimap
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$WM_MARKER\$/d' $HOOK
rm -rf /userdata/wifimap.sh /userdata/wifimap.awk /userdata/wifimap.conf /tmp/wifimap.*
true
EOF
    echo "Uninstalled. The recorded samples in /userdata/wifimap were kept."
    echo "Remove them with:  ssh root@$ROBOT rm -rf /userdata/wifimap"
    ;;
wifimap-status)
    remote 'sh -s' <<'EOF'
if [ -f /tmp/wifimap.pid ] && kill -0 "$(cat /tmp/wifimap.pid)" 2>/dev/null; then
    echo "wifimap: running (pid $(cat /tmp/wifimap.pid))"
else
    echo "wifimap: not running"
fi
grep -q 'j15-wifimap$' /oem/_root_postboot.sh 2>/dev/null && echo "boot hook: installed" || echo "boot hook: missing"
echo "jobs: $(ls /userdata/wifimap/job-*.csv 2>/dev/null | grep -c .) files, $(du -sh /userdata/wifimap 2>/dev/null | cut -f1)"
newest=$(ls /userdata/wifimap/job-*.csv 2>/dev/null | tail -n 1)
[ -n "$newest" ] && echo "newest: $newest, last sample: $(tail -n 1 "$newest")"
echo "signal now: $(grep wlan0: /proc/net/wireless 2>/dev/null | awk '{sub(/\.$/, "", $4); print $4}') dBm"
echo "--- last log lines ---"
tail -n 10 /tmp/wifimap.log 2>/dev/null || echo "(no log)"
EOF
    ;;
roomorder-install)
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -d /userdata ] || err "/userdata missing"
[ -e /usr/navi/manager_node ] || err "/usr/navi/manager_node missing (not a Midea J15 firmware?)"
[ -e /usr/bin/track ] || err "/usr/bin/track missing (not a Midea J15 firmware?)"
[ -e /oem/midea_autorun ] && err "vendor debug mode is active (/oem/midea_autorun); /usr/bin/track won't restart manager_node then"
true
EOF
    echo "Copying files..."
    remote 'mkdir -p /userdata/roomorder'
    push "$HERE/robot/roomorder.sh" /userdata/roomorder/roomorder.sh 755
    echo "Creating the patched copy on the robot (checks the firmware version first)..."
    remote '/userdata/roomorder/roomorder.sh prepare' || { echo "Nothing was changed on the running system." >&2; exit 1; }
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$RO_MARKER\$' $HOOK || echo '/userdata/roomorder/roomorder.sh >/dev/null 2>&1 &  $RO_MARKER' >> $HOOK
chmod +x $HOOK
EOF
    echo "Applying: this restarts ALL robot nodes (about a minute), don't run it during a clean..."
    remote '/userdata/roomorder/roomorder.sh apply </dev/null' || {
        echo "error: applying failed, see: ./install.sh roomorder-status $ROBOT" >&2
        exit 1
    }
    echo
    echo "Installed. Check with ./install.sh roomorder-status $ROBOT"
    ;;
roomorder-uninstall)
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$RO_MARKER\$/d' $HOOK
true
EOF
    echo "Restoring the stock manager_node: this restarts ALL robot nodes (about a minute)..."
    if remote '[ -x /userdata/roomorder/roomorder.sh ]'; then
        remote '/userdata/roomorder/roomorder.sh remove </dev/null' || {
            echo "error: restore failed; the patched files were kept. See: ./install.sh roomorder-status $ROBOT" >&2
            exit 1
        }
    else
        remote 'while grep -q " /usr/navi/manager_node " /proc/mounts; do umount -l /usr/navi/manager_node || break; done; killall -9 manager_node 2>/dev/null; true'
    fi
    remote 'rm -rf /userdata/roomorder /tmp/roomorder.log /tmp/roomorder.log.old'
    echo "Uninstalled."
    ;;
roomorder-status)
    if remote '[ -x /userdata/roomorder/roomorder.sh ]'; then
        remote '/userdata/roomorder/roomorder.sh status'
    else
        echo "roomorder: not installed"
        remote 'grep -q " /usr/navi/manager_node " /proc/mounts && echo "warning: /usr/navi/manager_node is mounted over"; grep -q "j15-roomorder\$" /oem/_root_postboot.sh 2>/dev/null && echo "warning: boot hook present"; true'
    fi
    ;;
obstaclegap-install)
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -d /userdata ] || err "/userdata missing"
[ -e /usr/navi/planner_node ] || err "/usr/navi/planner_node missing (not a Midea J15 firmware?)"
[ -e /usr/bin/track ] || err "/usr/bin/track missing (not a Midea J15 firmware?)"
[ -e /oem/midea_autorun ] && err "vendor debug mode is active (/oem/midea_autorun); /usr/bin/track won't restart planner_node then"
true
EOF
    echo "Copying files..."
    remote 'mkdir -p /userdata/obstaclegap'
    push "$HERE/robot/obstaclegap.sh" /userdata/obstaclegap/obstaclegap.sh 755
    echo "Creating the patched copy on the robot (checks the firmware version first)..."
    remote '/userdata/obstaclegap/obstaclegap.sh prepare' || { echo "Nothing was changed on the running system." >&2; exit 1; }
    echo "Adding boot hook to $HOOK..."
    remote "sh -s" <<EOF
[ -f $HOOK ] || printf '#!/bin/sh\n' > $HOOK
grep -q '$OG_MARKER\$' $HOOK || echo '/userdata/obstaclegap/obstaclegap.sh >/dev/null 2>&1 &  $OG_MARKER' >> $HOOK
chmod +x $HOOK
EOF
    echo "Applying: this restarts ALL robot nodes (about a minute), don't run it during a clean..."
    remote '/userdata/obstaclegap/obstaclegap.sh apply </dev/null' || {
        echo "error: applying failed, see: ./install.sh obstaclegap-status $ROBOT" >&2
        exit 1
    }
    echo
    echo "Installed. Check with ./install.sh obstaclegap-status $ROBOT"
    ;;
obstaclegap-uninstall)
    remote "sh -s" <<EOF
[ -f $HOOK ] && sed -i '/$OG_MARKER\$/d' $HOOK
true
EOF
    echo "Restoring the stock planner_node: this restarts ALL robot nodes (about a minute)..."
    if remote '[ -x /userdata/obstaclegap/obstaclegap.sh ]'; then
        remote '/userdata/obstaclegap/obstaclegap.sh remove </dev/null' || {
            echo "error: restore failed; the patched files were kept. See: ./install.sh obstaclegap-status $ROBOT" >&2
            exit 1
        }
    else
        remote 'while grep -q " /usr/navi/planner_node " /proc/mounts; do umount -l /usr/navi/planner_node || break; done; killall -9 planner_node 2>/dev/null; true'
    fi
    remote 'rm -rf /userdata/obstaclegap /tmp/obstaclegap.log /tmp/obstaclegap.log.old'
    echo "Uninstalled."
    ;;
obstaclegap-status)
    if remote '[ -x /userdata/obstaclegap/obstaclegap.sh ]'; then
        remote '/userdata/obstaclegap/obstaclegap.sh status'
    else
        echo "obstaclegap: not installed"
        remote 'grep -q " /usr/navi/planner_node " /proc/mounts && echo "warning: /usr/navi/planner_node is mounted over"; grep -q "j15-obstaclegap\$" /oem/_root_postboot.sh 2>/dev/null && echo "warning: boot hook present"; true'
    fi
    ;;
valetudo-install)
    if [ ! -f "$HERE/build/valetudo-aarch64" ]; then
        echo "build/valetudo-aarch64 not found, building..."
        "$HERE/valetudo/build.sh"
    fi
    remote 'sh -s' <<'EOF'
err() { echo "  error: $*" >&2; exit 1; }
[ "$(uname -m)" = aarch64 ] || err "unexpected architecture $(uname -m)"
[ -e /usr/lib/libsample_plugin.so ] || err "/usr/lib/libsample_plugin.so missing (not a Midea J15 firmware?)"
[ -d /userdata ] || err "/userdata missing"
[ -f /userdata/valetudo ] || err "/userdata/valetudo missing (is Valetudo installed?)"
EOF
    # Backup (a full copy) + upload (another copy) + headroom.
    need_kb=$(( ($(wc -c < "$HERE/build/valetudo-aarch64") * 2) / 1024 + 10240 ))
    { echo "NEED_KB=$need_kb"; cat <<'EOF'
free_kb=$(df -k /userdata | tail -n 1 | awk '{print $(NF-2)}')
if [ -z "$free_kb" ] || [ "$free_kb" -lt "$NEED_KB" ] 2>/dev/null; then
    echo "  error: /userdata has ${free_kb:-unknown} kB free, need $NEED_KB kB (2x the binary + 10 MB). Free some space and retry." >&2
    exit 1
fi
echo "  /userdata free space ok (${free_kb} kB free, ${NEED_KB} kB needed)"
EOF
    } | remote 'sh -s'
    echo "Backing up the stock binary..."
    on_robot <<'EOF'
if [ -f /userdata/valetudo.stock ]; then
    echo "  keeping existing /userdata/valetudo.stock"
else
    cp /userdata/valetudo /userdata/valetudo.stock.new && sync && mv /userdata/valetudo.stock.new /userdata/valetudo.stock \
        && echo "  saved /userdata/valetudo.stock ($(sha256sum /userdata/valetudo.stock | cut -d' ' -f1))" \
        || { rm -f /userdata/valetudo.stock.new; echo "  error: backup failed (disk full?)" >&2; exit 1; }
fi
EOF
    echo "Copying the patched build..."
    push "$HERE/build/valetudo-aarch64" /userdata/valetudo.patched.new 755
    want=$(sha256_local "$HERE/build/valetudo-aarch64")
    got=$(remote 'sha256sum /userdata/valetudo.patched.new' | cut -d' ' -f1)
    if [ "$want" != "$got" ]; then
        remote 'rm -f /userdata/valetudo.patched.new'
        echo "error: upload checksum mismatch" >&2
        exit 1
    fi
    echo "Replacing the binary and restarting Valetudo..."
    on_robot <<'EOF'
vt_capture
flipped=0
if [ -z "$CFG" ]; then
    echo "  warning: config file not found, disable the updater in the Valetudo UI yourself" >&2
elif [ "$(vt_updater_state)" = true ]; then
    [ -f "$CFG.pre-patched" ] || cp "$CFG" "$CFG.pre-patched"
    vt_updater false
    flipped=1
fi
[ "$(sed -n 's/^updater_flipped=//p' "$STATE" 2>/dev/null)" = 1 ] && flipped=1
vt_stop
mv /userdata/valetudo.patched.new "$VT"
sync
{ echo "config=$CFG"; echo "updater_flipped=$flipped"; } > "$STATE.new" && mv "$STATE.new" "$STATE"
vt_start || exit 1
[ -z "$CFG" ] || [ "$(vt_updater_state)" = false ] || echo "  warning: updater is still enabled in $CFG" >&2
true
EOF
    echo
    echo "Installed. Check with ./install.sh valetudo-status $ROBOT"
    ;;
valetudo-uninstall)
    on_robot <<'EOF'
if [ ! -f /userdata/valetudo.stock ]; then
    echo "  error: no /userdata/valetudo.stock backup, nothing to restore" >&2
    exit 1
fi
vt_capture
saved=$(sed -n 's/^config=//p' "$STATE" 2>/dev/null)
[ -n "$saved" ] && CFG=$saved
flipped=$(sed -n 's/^updater_flipped=//p' "$STATE" 2>/dev/null)
vt_stop
cp /userdata/valetudo.stock /userdata/valetudo.restore.new && chmod 755 /userdata/valetudo.restore.new \
    && mv /userdata/valetudo.restore.new "$VT" || { echo "  error: restore failed" >&2; exit 1; }
sync
[ "$flipped" = 1 ] && vt_updater true
vt_start || exit 1
rm -f /userdata/valetudo.stock "$STATE" /userdata/valetudo.patched.new
echo "  restored the stock binary"
EOF
    echo "Uninstalled."
    ;;
valetudo-restart)
    on_robot <<'EOF'
vt_capture
vt_stop
vt_start || exit 1
true
EOF
    echo "Restarted."
    ;;
valetudo-status)
    on_robot <<'EOF'
vt_capture
pid=$(vt_pid)
[ -n "$pid" ] && echo "valetudo: running (pid $pid)" || echo "valetudo: not running"
cur=$(sha256sum "$VT" 2>/dev/null | cut -d' ' -f1)
echo "binary sha256: ${cur:-missing}"
if [ -f /userdata/valetudo.stock ]; then
    stock=$(sha256sum /userdata/valetudo.stock | cut -d' ' -f1)
    echo "backup: /userdata/valetudo.stock present ($stock)"
    [ "$cur" = "$stock" ] && echo "build: stock" || echo "build: patched"
else
    echo "backup: none"
    echo "build: stock (never replaced by this installer)"
fi
echo "config: ${CFG:-not found}"
echo "updater enabled: $(vt_updater_state)"
echo "--- last log lines ---"
tail -n 10 /tmp/valetudo.log 2>/dev/null || echo "(no log)"
EOF
    ;;
*)
    usage 2
    ;;
esac
