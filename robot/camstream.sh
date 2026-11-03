#!/bin/sh
# Runs on the robot. Starts camstream once video_node is up and restarts it
# if it exits. Started at boot from /oem/_root_postboot.sh by install.sh.

CONF=/userdata/camstream.conf
LOG=/tmp/camstream.log
BIND=0.0.0.0
PORT=8555
[ -f "$CONF" ] && . "$CONF"

echo $$ > /tmp/camstream.pid

while [ ! -S /tmp/ubus.sock ] || [ ! -e /dev/shm/camera_stream ]; do
    sleep 5
done

while true; do
    # /tmp is RAM; keep the log small.
    if [ -f "$LOG" ] && [ "$(wc -c < "$LOG")" -gt 262144 ]; then
        mv "$LOG" "$LOG.old"
    fi
    /userdata/camstream -b "$BIND" -p "$PORT" >>"$LOG" 2>&1
    sleep 5
done
