#!/usr/bin/env bash
# Installs camstream on a rooted Midea J15 over SSH. Run from your computer.
#
#   ./install.sh install   <robot-ip> [ssh options]   copy files, add boot hook, start
#   ./install.sh uninstall <robot-ip> [ssh options]   stop, remove files and boot hook
#   ./install.sh restart   <robot-ip> [ssh options]   restart (e.g. after editing the config)
#   ./install.sh status    <robot-ip> [ssh options]   show whether it is running
#   ./install.sh check     <robot-ip> [ssh options]   run the camera pipeline diagnostic
#   ./install.sh collect-logs <robot-ip> [ssh options]  save robot logs + dmesg to a local .tar
#
# Anything after the robot address is passed to ssh unchanged, e.g.
#   ./install.sh install 192.168.1.50 -i ~/.ssh/robot -p 2222

set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HOOK=/oem/_root_postboot.sh
MARKER="# j15-camstream"

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
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
    remote 'dmesg > /tmp/dmesg-now.txt; tar -cf - /userdata/logs/app /tmp/dmesg-now.txt 2>/dev/null; rm -f /tmp/dmesg-now.txt' > "$out"
    echo "Saved $out ($(du -h "$out" | cut -f1)). It contains device logs; don't share it publicly."
    ;;
*)
    usage 2
    ;;
esac
