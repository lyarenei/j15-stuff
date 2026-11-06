# Investigation: dock water tank monitoring

**Status:** measured on a real mopping job (2026-11-06); the estimator,
`tankwatch`, is built (see [tankwatch](#tankwatch)) but not yet installed or
tested on the robot. Started 2026-11-04.

## Goal

Warn before the dock's clean water tank runs empty or the dirty water tank
fills up, and possibly refuse to start a mopping job when it would run out
midway.

## Summary

- **The dock has no level sensors.** It reports only binary states: whether
  each tank is fitted, and a "full" bit for the dirty tank. An empty clean
  tank is only detected **while a wash is running**, when the dock fails to
  draw water.
- **Valetudo already shows these states**, both in its UI (Dock panel) and
  in Home Assistant (MQTT autodiscovery): `Freshwater` (`ok` / `empty` /
  `missing`) and `Wastewater` (`ok` / `full`). The values come from the
  robot's `station_error_code`, so they change only once the firmware has
  raised an error, which is too late for an early warning.
- A "nearly full / nearly empty" warning therefore has to be an
  **estimate**: count water used since the tank was last emptied or
  refilled.
- **Clean water use can be measured.** The dock has a flow meter on its
  clean water supply (`water_pump_flow`), and `data_node` logs every change
  of it. See [Measurements](#measurements-2026-11-06).
- **Reset signals:** taking the dirty tank out flips `sensor_status` byte 2
  bit 4 (logged as `is_sewage_abnormal`). Taking the clean tank out changes
  nothing at all, so the clean counter needs a manual reset. The earlier
  assumption that `is_wash_sink_installed` is the clean tank was wrong.
- The dock data is published on the IPC topic
  `/tmp/mcu-publish-water-station-info`, so a small on-robot program could
  subscribe to it the same way `camstream` subscribes to `camera_stream`.

## Valetudo side

Valetudo `master` (`06cfc72d`, 2026-11-01):

- `MideaModernValetudoRobot.getModelDetails()` lists
  `supportedDockComponents: [WATER_TANK_CLEAN, WATER_TANK_DIRTY, DUSTBAG]`,
  and the J15 Pro Ultra inherits it.
- `MideaValetudoRobot.parseAndUpdateState()` derives the tank states from
  `station_error_code` (`BEightParser`: `payload[35]` of the status DTO):

  | `station_error_code` | Component | Value |
  |---|---|---|
  | 105 | clean tank | `missing` |
  | 106 | clean tank | `empty` |
  | 152 | dirty tank | `full` |
  | anything else | both | `ok` |

  A missing dirty tank isn't mapped (it stays `ok`).
- `DockComponentStateMqttHandle` publishes each component under
  `<prefix>/<id>/DockComponentStateAttribute/<type>`, with a Home Assistant
  sensor named `<Freshwater|Wastewater> Dock Component` (entity category
  *diagnostic*).
- `MSmartDockStatusDTO` (`dust_collection_count`, `fluid_1_ok`,
  `fluid_2_ok`) is parsed but ignored (`// FIXME: what to do with this?`).
- Valetudo has no "level" concept for dock components; the enum is only
  `ok, missing, empty, full, unknown`.

## Firmware side

### What the dock reports

`data_node` talks to the dock over BLE (`device_node::BleStation`) and logs a
full dump about every 10 minutes (`[Data] group[0] print`). The dock fields
seen in `/userdata/logs/app/data/` (2026-11-02, 147 dumps, robot idle on the
dock most of the day):

| Field | Seen | Meaning |
|---|---|---|
| `is_wash_sink_installed` | always 1 | *not* the clean tank (unchanged when it's removed); probably the wash tray |
| `is_wash_sink_full` | always 0 | unknown, probably unused |
| `is_sewage_installed` | always 1 | dirty tank fitted |
| `is_sewage_full` | always 0 | **dirty tank full** |
| `is_sewage_abnormal` | 0, 1 while the dirty tank is out | **dirty tank removed** (see [Measurements](#measurements-2026-11-06)) |
| `turbidity_value` | always 65535 | dirty-water turbidity meter; 65535 = no reading (not fitted or off) |
| `clean_box_water_level` | always 0 | 3-bit value, *not* a tank level (see below) |
| `supply_station_status`, `pump_station_status` | 255 idle | clean water supply and dirty water pump state machines |
| `water_pump_flow`, `pressure`, `vacuum_degree` | 0 | idle |

### `sensor_status` bitfield

The flags come from a 24-bit `sensor_status` (`clean_robot::MCU::SenSta`).
`BleStation::_printStationSensor` (`data_node` `0x77b790`) unpacks it in the
same order as the log:

| Byte | Bit | Field |
|---|---|---|
| 0 | 0 | `is_wash_sink_installed` |
| 0 | 1 | `is_wash_sink_full` |
| 0 | 2 | `is_sewage_installed` |
| 0 | 5 | `is_sewage_full` |
| 0 | 6 | `is_robot_full` |
| 0 | 7 | `is_lift_module_arrive` |
| 1 | 4 | `is_auto_plumb_installed` |
| 1 | 5 | `is_filter_install` |
| 1 | 6 | `is_fluid` |
| 1 | 7 | `is_agent` |
| 2 | 0 | `is_dust_bag_installed` |
| 2 | 1 | `is_dust_box_closed` |
| 2 | 2 | `is_dust_bag_full` |
| 2 | 3 | `is_dust_jam` |
| 2 | 4 | `is_sewage_abnormal` |
| 2 | 5 | `is_plumb_clean_full` |
| 2 | 6 | `is_self_clean_up` |
| 2 | 7 | `is_duct_switch_arrive` |

Check against the log: `8585221` = `0x830005` gives exactly the 1s logged
(clean tank, dirty tank, dust bag, dust box closed, duct switch).
`12779525` = `0xC30005` adds `is_self_clean_up`.

### How `manager_node` uses them

`StationErrorHandle` (`manager_node`) clears station errors when the matching
bit changes:

- `_needClearWaterTankNotExitError` (`0xa8b290`) watches **bit 0**
  (`wash_sink_installed`). This suggested that "wash sink" is the clean
  water tank, but removing the clean tank doesn't change bit 0 (see
  [Measurements](#measurements-2026-11-06)), so the error name is
  misleading or the bit means the wash tray.
- `_needClearDirtyWaterTankFullError` (`0xa8baa0`) watches **bit 5**
  (`sewage_full`).

An empty clean tank has no sensor bit. `CStationCtrl::_cleanWaterTankLackWaterProc`
(`0xa4ea80`) handles `kWaterTankLackWater`, which is raised when the dock
can't draw water during a wash. It pauses the mop wash, retries
("`unclog_water_pipe_cnt_`"), and gives up after the retry limit. Related
log strings: `[SELF_CLEAN] Err kWaterTankLackWater`,
`[PLUMB] drain clean water done. status=kWaterTankLackWater`.

`IsWaterLevelMemsLow` (`0xa4d3c0`) decompiles to an empty body (only the
stack guard remains): either stubbed out in this build or a hardware
feature this dock doesn't have.

`clean_box_water_level` is compared with the robot's own water box level
in `CStationCtrl::MopCleanCloseChargeMos` (`0xa53e20`, log
`water_box_level sta[%d] robot[%d]`) to pick the next mop-wash step. That
makes it a wash water-amount setting or the robot's onboard box, not the
dock tank. Not fully confirmed.

### Consequence for the user

The dirty tank's full bit is read continuously, so a full dirty tank is
known before a job starts. The clean tank's emptiness is discovered only at
the first mop wash during the job. Whether the firmware refuses to start a
mopping job with the dirty tank already full hasn't been tested.

### IPC

`MCUNanoStub::PubWaterStationData(const MCU::WaterStation&)` in `data_node`
publishes the dock struct on `mcu-publish-water-station-info`
(`/tmp/mcu-publish-water-station-info`). `manager_node` subscribes to it. The
`WaterStation` struct layout hasn't been decoded yet. `sensor_status` sits at
offset 4 (the `StationErrorHandle` functions read `+4`).

## Measurements (2026-11-06)

One mopping job on the user's robot, clean tank full and dirty tank empty
at the start. Logs collected with `./install.sh collect-logs` (persistlog
kept the whole job); raw logs are not committed.

The robot's clock is **UTC** (one hour behind CET), so log times are an
hour earlier than wall-clock times.

### Event lines

`data_node` logs every change of a dock field, not just the 5-minute
`group[0] print` dumps:

- `_procStationWashData - <field>:<old>-><new>` (`water_pump_flow`,
  `supply_station_status`, `pump_station_status`,
  `supply_water_robot_status`, `heating_water_status`, `sensor_status`, ...)
- `_printStationSensor - <bit name>:<old>-><new>`
- `_sendWashModuleCmd - [STA]Send supply water task to water sta, supply
  mode=N, overtime=<s>, ...`, `... Send pump water task ... pump mode=N,
  overtime=<s>`, `... Send task to water sta, cmd=3, switch=1, overtime=<s>`
  (refill the robot's onboard tank), `... Send heat water mode ...`
- `_procStationBaseData - arrive_status:0->1` (robot docked)

Status values: `1` running, `2` finished, `255` idle after a run, `0`
idle.

### One mop wash

Each return to the dock ran the same sequence (times are requested
durations):

1. supply mode 1, 13 s (flow ≈ 275), with heating for warm/hot wash;
2. refill the robot's onboard tank, 30 s (50 s on the first visit), via
   the air valve (`air_value_current` rises, `water_pump_flow` stays 0);
3. supply mode 2, 2 s (flow 0 or 13);
4. dirty pump mode 2, 55-85 s, while supply mode 1 runs again for
   39-85 s (flow ≈ 275);
5. supply mode 2, 12-15 s (flow mostly 0, short blips of 13), with more
   dirty pump runs of 25-65 s.

The last visit has no robot refill and ends with mop drying (`dry mode=1,
overtime=900`; `fun_current` is the drying fan).

### Totals for the job

| Signal | Total |
|---|---|
| `water_pump_flow` integrated over time | 69,730 unit·s (2,600-20,700 per step) |
| clean supply pump running | 347 s in 15 runs |
| robot onboard tank refill | 110 s in 3 runs |
| dirty pump running | 645 s in 14 runs |

Measured by the user after the job: **≈ 1.5 L** to top the clean tank back
up, **≈ 0.9 L** in the dirty tank. Capacities: clean 4 L, dirty 3.4 L.

Reading: if `water_pump_flow` is in mL/min, the integral is 1.16 L, and the
remaining ≈ 0.34 L would be the robot refills (≈ 3 mL/s), which the flow
meter doesn't see. One job can't separate the two terms; a second job with
a different number of washes would. The single-factor fallback is
1.5 L / 69,730 = 0.0215 mL per unit·s. Dirty water: 0.9 L / 645 s
≈ 1.4 mL/s of dirty pump time, or ≈ 0.6 × the clean water used.

This job used ≈ 38% of the clean tank and ≈ 26% of the dirty tank, so the
clean tank runs out first (after about 2.5 jobs like this one).

### Tank removal

| Wall clock (CET) | Log (UTC) | Action | Logged |
|---|---|---|---|
| 18:42-18:46 | 17:42-17:46 | clean tank out and back | **nothing** (no `sensor_status` change, no manager error) |
| 18:46:30-18:48:30 | 17:46:38-17:48:29 | dirty tank out and back | `sensor_status` `12779525 → 13828101 → 12779525` = byte 2 bit 4 (`is_sewage_abnormal`) `0 → 1 → 0` |

`is_sewage_installed` (byte 0 bit 2) stayed 1 the whole time. The same bit
4 toggle also appears at 15:25:06-15:25:32 UTC, just before the job
started.

## tankwatch

`robot/tankwatch.sh` follows the `data` log (`data.INFO`) and the `manager`
log with `tail -n 0 -F` and feeds the lines to `robot/tankwatch.awk`, which
keeps two running totals and writes them to `/userdata/tankwatch/state.json`
(integers only, written atomically; `version`, `updated`, and per tank
`used_ml`, `capacity_ml`, `remaining_pct`, `low`, `reset`). The dirty
tank's `remaining_pct` is the space left. The file is rewritten at the end
of a pump or refill run, when the flow returns to 0, and after any reset,
full or empty event, not on every flow change, because it lives on flash.
The totals are read back from it at start, so they survive reboots.

`./install.sh tankwatch-uninstall` renames `state.json` to
`state.json.uninstalled` (the calibration log stays) so that a patched
Valetudo, which registers the tank consumables only if `state.json` exists at
its start, no longer shows frozen levels; they disappear after Valetudo's next
restart. `tankwatch-install` creates a fresh `state.json` when there is none
and does not restore the renamed file. Both actions print
`./install.sh valetudo-restart <ip>` when the installed Valetudo is the patched
build; they do not restart it themselves.

### Model

```
clean_used_ml += flow_integral * FLOW_ML_PER_UNIT_S + refill_seconds * REFILL_ML_PER_S
dirty_used_ml += dirty_pump_seconds * DIRTY_ML_PER_PUMP_S
```

- `water_pump_flow:A->B` is a step function: the value holds until the next
  change. Time comes from the log line timestamps (UTC, midnight wrap
  handled), not from the clock.
- `supply_water_robot_status` is the robot refill and `pump_station_status`
  the dirty pump; each counts while its value is 1.
- A `regiser success` line means `data_node` restarted: running pumps and
  the flow are treated as stopped.

Constants (`/userdata/tankwatch.conf`, kept across reinstalls), all from
the single measured job:

| Constant | Value | Source |
|---|---|---|
| `CLEAN_CAPACITY_ML` / `DIRTY_CAPACITY_ML` | 4000 / 3400 | tank sizes |
| `FLOW_ML_PER_UNIT_S` | 0.016667 | `water_pump_flow` read as mL/min: 69,730 unit·s gives 1,162 mL |
| `REFILL_ML_PER_S` | 3.1 | the remaining ≈ 340 mL of the measured 1.5 L over 110 s of refill; **a fit to one job**, not measured separately |
| `DIRTY_ML_PER_PUMP_S` | 1.4 | 0.9 L over 645 s of dirty pump |
| `LOW_PCT` | 20 | `low` is true when `remaining_pct` is below it |

Replaying the job log (`tools/tankwatch-replay.sh log/tank/data-all.log`)
gives clean ≈ 1,503 mL and dirty ≈ 903 mL, which is what the constants were
fitted to, so it only checks the parser. The refill and flow terms still
need a second job to be separated (see Open questions).

### Resets and calibration

- **Dirty tank put back** (`is_sewage_abnormal:1->0`): dirty counter to 0.
- **Dock says dirty tank full** (`is_sewage_full:0->1`): dirty counter set to
  the capacity. The estimate before clamping is appended to
  `/userdata/tankwatch/calibration.log` (timestamp, `dirty_full`,
  `est_used_ml`), so drift of the constants shows up there.
- **Clean tank empty**: a manager log line containing `kWaterTankLackWater`
  sets the clean counter to the capacity and logs `clean_empty` with the
  estimate the same way, at most once per 10 minutes. **This trigger has
  never been observed** (no job has run the tank dry); it is implemented
  from the string seen in the firmware. Strings like
  `[PLUMB] drain clean water done. status=kWaterTankLackWater` suggest the
  name may also appear in lines that are not an empty tank, in which case
  the counter would jump to empty wrongly; check the first real hit.
- **Manual reset** (clean tank refilled; removing it isn't reported): create
  `/tmp/tankwatch.reset-clean` or `/tmp/tankwatch.reset-dirty` (that is what
  Valetudo does), or run `/userdata/tankwatch.sh reset clean|dirty` on the
  robot. The daemon sets that counter to 0, `reset` to now, deletes the flag
  and writes the state. The flags are checked on log input at most once a
  second; the logs are quiet when the robot is idle, so while a flag is
  pending the daemon feeds itself a line every second.

### Limits

- Events are only seen while the daemon runs. A restart (or a reboot, or a
  `data_node` crash that happens while the daemon is down) misses whatever
  the dock did in between, including a tank removal.
- A pump or refill run that was in progress when the daemon stopped is
  dropped.
- `tankwatch.awk` uses only POSIX awk, so the same file runs with the
  robot's busybox awk and macOS awk.

## Possible approaches

1. **Estimate levels with an on-robot monitor** (separate component, like
   the room-order patch):
   - subscribe to `mcu-publish-water-station-info` (or tail the `data` /
     `manager` logs);
   - reset the dirty counter when `sensor_status` byte 2 bit 4 goes
     `1 → 0` (dirty tank put back); the clean counter needs a manual reset,
     since removing the clean tank isn't reported;
   - add clean water from the `water_pump_flow` integral plus robot refill
     time, and dirty water from dirty pump run time;
   - calibrate against tank capacity by running until the real
     `empty` / `full` errors fire;
   - publish the estimates to MQTT for Home Assistant, next to Valetudo's
     binary sensors.
2. **Refuse a mopping job when the estimate is too low or high.** Options:
   a Home Assistant automation that blocks or warns before its own
   scheduled starts (no robot changes); or intercepting job starts on the
   robot, which needs a `manager_node` hook and would also block starts from
   the Valetudo UI. The second is much more invasive.

## Open questions

- The unit of `water_pump_flow` (mL/min fits the first job), and how much
  clean water a robot refill uses. A second measured job separates the two.
- Whether the robot refill draws from the clean tank at all.
- Whether the clean tank's absence is detected anywhere except during a
  wash (error 105 in `station_error_code`).
- The `WaterStation` struct layout on the IPC topic (not needed if the
  estimator reads the log lines).
- What the firmware does when a mopping job starts with `sewage_full = 1`.
- Whether `is_wash_sink_full` or `turbidity_value` is ever non-default on
  this dock.
