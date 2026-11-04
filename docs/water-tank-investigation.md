# Investigation: dock water tank monitoring

**Status:** research done (static analysis and existing logs). Nothing built
yet. Started 2026-11-04.

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
  refilled. The firmware gives us a reset signal for free: a tank's
  "installed" bit goes `1 → 0 → 1` when it's taken out and put back.
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
| `is_wash_sink_installed` | always 1 | **clean tank fitted** (see below) |
| `is_wash_sink_full` | always 0 | unknown, probably unused |
| `is_sewage_installed` | always 1 | dirty tank fitted |
| `is_sewage_full` | always 0 | **dirty tank full** |
| `is_sewage_abnormal` | always 0 | dirty tank fault |
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
  (`wash_sink_installed`). So "wash sink" is the clean water tank.
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

## Possible approaches

1. **Estimate levels with an on-robot monitor** (separate component, like
   the room-order patch):
   - subscribe to `mcu-publish-water-station-info` (or tail the `data` /
     `manager` logs);
   - reset the clean counter when `wash_sink_installed` goes `0 → 1`, and
     the dirty counter when `sewage_installed` goes `0 → 1`;
   - add usage per mop wash (wash count, or pump run time from
     `supply_station_status` / `pump_station_status` transitions);
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

- Per-wash water usage and its variance (needs logs from a full mopping job:
  `supply_station_status`, `pump_station_status`, `water_pump_flow` and the
  `[STATION]` manager lines).
- The `WaterStation` struct layout on the IPC topic.
- What the firmware does when a mopping job starts with `sewage_full = 1`.
- Whether `is_wash_sink_full` or `turbidity_value` is ever non-default on
  this dock.
