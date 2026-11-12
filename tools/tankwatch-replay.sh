#!/bin/sh
# Feeds data_node log files through robot/tankwatch.awk and prints the final
# state. Uses a temp dir and the conf defaults; no robot needed. Manager logs
# can be passed too; the clean-tank-empty trigger needs them.
#
#   tools/tankwatch-replay.sh data.log [data.log ...]
#
# Exact duplicate lines (from merged logs) are dropped.

[ $# -ge 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/../robot/tankwatch.conf"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat "$@" | awk '!seen[$0]++' | awk -f "$HERE/../robot/tankwatch.awk" \
    -v STATE_FILE="$TMP/state.json" -v CAL_LOG="$TMP/calibration.log" \
    -v RESET_CLEAN="$TMP/reset-clean" -v RESET_DIRTY="$TMP/reset-dirty" \
    -v CLEAN_CAPACITY_ML="$CLEAN_CAPACITY_ML" -v DIRTY_CAPACITY_ML="$DIRTY_CAPACITY_ML" \
    -v FLOW_ML_PER_UNIT_S="$FLOW_ML_PER_UNIT_S" -v REFILL_ML_PER_S="$REFILL_ML_PER_S" \
    -v DIRTY_ML_PER_PUMP_S="$DIRTY_ML_PER_PUMP_S" -v LOW_PCT="$LOW_PCT"

cat "$TMP/state.json"
[ ! -f "$TMP/calibration.log" ] || { echo "calibration log:"; cat "$TMP/calibration.log"; }
