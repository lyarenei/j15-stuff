#!/bin/sh
# Runs on the robot. Checks each stage of the camera pipeline and says where
# it breaks. See docs/camera-troubleshooting.md for what the results mean.

UBUS="ubus -s /tmp/ubus.sock"
fail=0

ok()   { echo "  [ OK ] $*"; }
bad()  { echo "  [FAIL] $*"; fail=1; }
info() { echo "  [info] $*"; }

echo "1. Sensor driver (I2C bus 2)"
for d in /sys/bus/i2c/devices/2-0030 /sys/bus/i2c/devices/2-003c; do
    [ -e "$d" ] || continue
    name=$(cat "$d/name")
    if [ -e "$d/driver" ]; then
        ok "$name bound to a driver"
        bound=1
    else
        info "$name declared but no driver bound"
    fi
done
[ -n "$bound" ] || bad "no camera sensor driver bound (sensor did not answer at boot)"

echo "2. Sensor probe messages (boot log)"
msgs=$(dmesg | grep -iE 'sc035hgs|ov02b10' | grep -iE 'Detected|Unexpected sensor id')
if [ -z "$msgs" ]; then
    info "no probe messages; boot log has scrolled out of dmesg (reboot and re-run)"
else
    echo "$msgs" | sed 's/^/         /'
    echo "$msgs" | grep -q 'Detected' && ok "sensor answered with its chip ID"
fi

echo "3. Media graph"
if media-ctl -d /dev/media0 -p 2>/dev/null | grep -q 'subtype Sensor'; then
    ok "sensor entity linked into /dev/media0"
else
    bad "no sensor entity in /dev/media0"
fi

echo "4. video_node capture"
if pidof video_node >/dev/null; then
    ok "video_node running"
else
    bad "video_node not running"
fi
log=/userdata/logs/app/video/video.INFO
if [ -f "$log" ]; then
    n=$(grep -cE 'start_capture failed|Could not get buffers' "$log")
    [ "$n" -eq 0 ] && ok "no capture errors in video log" || bad "$n capture errors in $log"
fi

echo "5. Control interface"
if $UBUS list media.engine.control >/dev/null 2>&1; then
    ok "ubus object media.engine.control present"
else
    bad "ubus object media.engine.control missing"
fi

echo
if [ "$fail" -eq 0 ]; then
    echo "Camera pipeline looks healthy."
else
    echo "Camera pipeline has problems; see docs/camera-troubleshooting.md."
fi
exit "$fail"
