# Valetudo vs firmware: mismatches

**Status:** static analysis, nothing tested on the robot (it's currently
inoperable). Done 2026-11-04.

This compares Valetudo's Midea driver (Hypfer/Valetudo `06cfc72`,
2026-11-01, `backend/lib/robots/midea` and `backend/lib/msmart`) with what
the J15 Pro Ultra firmware actually does (binaries in
[research-workflow.md](research-workflow.md#binaries-examined), mainly
`manager_node`). The protocol between them is MSmart: type 2 = SETTING,
type 3 = ACTION (query), type 4 = EVENT (pushed by the robot).

The work was split into five areas. Each has a detailed report with byte
maps, addresses and Valetudo file:line references:

| Area | Report |
|---|---|
| `SET_VARIOUS_TOGGLES` (0x9C): every toggle id | [valetudo-comparison/toggles-0x9c.md](valetudo-comparison/toggles-0x9c.md) |
| Status packet (GET_STATUS reply and STATUS event) | [valetudo-comparison/status-packet.md](valetudo-comparison/status-packet.md) |
| All other SETTING commands | [valetudo-comparison/settings-commands.md](valetudo-comparison/settings-commands.md) |
| Queries, events, robot and dock error codes | [valetudo-comparison/queries-events-errors.md](valetudo-comparison/queries-events-errors.md) |
| Features and model fit | [valetudo-comparison/features.md](valetudo-comparison/features.md) |

## Summary

- **The plumbing is right.** On the J15 Pro Ultra path every command id,
  payload layout, status offset and readback Valetudo uses matches the
  firmware. Nothing Valetudo sends is out of range.
- **The problems are meanings.** Labels that describe something else, enums
  that don't cover all firmware values, error codes with the wrong text or
  severity, and a status byte whose meaning changes with the robot state.
- **Valetudo trusts every reply.** Many firmware handlers report an error
  (or silently ignore bad input while replying OK), and Valetudo doesn't
  check either case for toggles.
- **The firmware can do a lot more** than Valetudo exposes (around 28 toggles,
  per-room settings, schedules, go-to-point, carpet zones, and more).

Most items below are fixed or worked around by the patched Valetudo build,
see [valetudo-patches.md](valetudo-patches.md#patches).

## Safety note: cliff sensors

Not a Valetudo bug, but found during this work. Every status frame in the
saved logs (2026-09-27 to 2026-11-02) has the stored `cliff-sensor`
setting = 1. The 0x63 (`SET_STAIRLESS_MODE`) handler stores the value
unchanged, the planner logs it as `disale_cliff_sensor` (sic), and Valetudo's
"Cliff Sensors" quirk sends 1 for "off". So the stored setting says the
cliff sensors were **disabled**. Check the quirk before running the robot
near stairs. Details: [status-packet.md](valetudo-comparison/status-packet.md#d-open-questions),
question 1.

## All mismatches

Ranked roughly by how much a user would notice. Confidence: **confirmed** =
read directly from code or data tables; **likely** = strong evidence, one
step inferred; **speculative** = plausible, not proven. "Report" points to
the detailed report and its mismatch number.

### Behaviour and labels

| # | Area | Valetudo | Firmware | Impact | Confidence | Report |
|---|---|---|---|---|---|---|
| 1 | "Collision-avoidant navigation" (0x9C `0x31`) | A switch for gentler, collision-avoiding driving | Edge deep vacuum: shorter back-off at inner corners plus corner manoeuvres, so the robot gets *closer* to walls. Applied only in vacuum-only mode | The label is roughly the opposite of the behaviour | confirmed | toggles M1, [corner doc](corner-cleaning-investigation.md) |
| 2 | AI obstacle classification quirk (0x9C `0x15`) | off = 0, high = 1, normal = 2 | Mapped through `{0→2, 1→0, 2→1}` into planner avoidance mode `SUPER=0, SMART=1, NORMAL=2`. "off" selects NORMAL avoidance, "normal" selects SMART | "off" doesn't turn anything off | mapping confirmed, mode meanings likely | toggles M2 |
| 3 | Work status 3 | DOCKED | `GoingHomePause`, and the fallback for unmapped states (0, 5, VoiceInteraction) | A robot paused on its way home shows as docked | confirmed | status M1 |
| 4 | Dock status (status byte 36) | Always the dock state | Depends on the robot state: dock state when on the station, relocation reason when relocating, sleep reason (49–53) when asleep, 0 otherwise | Dock shows PAUSE whenever the robot sleeps, IDLE in all other off-dock states | confirmed | status M3 |
| 5 | Mop drying time (0x9B) | Modes 5 (2 h), 6 (3 h), 7 (cold); getter throws on anything else | Modes 0–7: 6 h, 3 h, 1 h, 100 min, 3 h, 2 h, 3 h, 6 h (methods 2,1,1,1,2,1,1,2; method 2 probably unheated) | A mode set by the app or the default makes the control error out; 1 h and 100 min can't be chosen | confirmed (table), method meaning likely | settings M1, features M4 |
| 6 | Mop wash frequency / intensity quirks (0x59) | Edit only the "general" pair | The "custom" pair is used whenever the mode byte isn't 0. Every write also plays voice prompt `408.mp3` | Change may have no effect; unexpected voice prompt | confirmed (code), "custom" meaning likely | settings M2 |
| 7 | Water grade (0x51) | 5 presets; re-sends the nearest preset whenever it sees another value | 31 levels (100–130) plus legacy 0–3 | Any finer level set in the app is overwritten on the next poll; 100 shows as unknown | confirmed | settings M4, status M8 |
| 8 | Operation mode (0x58) | 0–3 | Also 5 ("AiClean", vacuum and mop) and 6 (single step, mop on); 4 rejected. Valetudo also updates the wrong field after a change | Modes 5/6 from the app show as no mode; UI lags until the next poll | confirmed (code), 5/6 meaning speculative | settings M3 |
| 9 | Fan, water, operation mode in status | Treated as what the robot is doing now | The saved defaults (GlobalConfig) | Per-room or in-progress values don't show | confirmed | status M7 |
| 10 | "Increased Carpet Avoidance" quirk (0x5E bit 3) | Stay further away from carpets | Stored as `carpet-setting-ai-aviod`: camera-detected carpets added to the avoidance map | Description probably wrong | likely | settings M6, features M7 |
| 11 | Mop wash temperature (0xC5) | 0 cold, 1 hot, 2 warm | On some docks 1 is silently turned into 2 | "Hot" may read back as "warm" | likely | settings M7 |
| 12 | "Mop twist" (0x9C `0x2e`) | Mop twist | Gap deep cleaning (mopping only). The real tail swing can't be switched on this firmware (`0x16` unsupported) | Name only | confirmed | toggles M3, features M2 |
| 13 | Clean route "quick" | One clean only | No automatic reset found; quick route also defers wall-follow switches | The "one clean" hint may be wrong | speculative | features M8 |
| 14 | Carpet sensor mode | Writes "avoid" as 3, reads 0 as avoid too | Enum not fully decoded | Possible read/write asymmetry | likely | features M6 |
| 15 | Fan speed | Absolute presets | Suction depends on operation mode ("high" with mop = "medium" without) | Not a bug; presets aren't absolute | confirmed | settings M5 |

### Values and units

| # | Area | Valetudo | Firmware | Impact | Confidence | Report |
|---|---|---|---|---|---|---|
| 16 | Area / time high bits | `(hi << 8) + lo` | `lo = v % 255`, `hi = v / 255` | +1 per 255 (300 m² reads 301). Exact area is in bytes 39–40 (u16 BE), which Valetudo ignores | confirmed | status M2 |
| 17 | Volume | Reads byte 11 | Byte 11 forced to 0 during DND silence | Volume shows 0 at night; a read-modify-write could save 0 | confirmed | status M6 |
| 18 | Fan levels 0 and 5 | Not in the table | Can be reported | Logged as unknown, state not updated | confirmed (reachability unverified) | status M9 |
| 19 | Floor material | 0 generic, 2 wood, 3 tile | 0–4 valid | 1 and 4 (set in the app) show as unknown | confirmed (range), meaning unknown | settings M11, features M9 |
| 20 | Zone cleaning (0x05) | Assumes success | Zones with any coordinate > 800 are dropped, reply still OK | Zones near the map edge vanish silently | confirmed | settings M10 |
| 21 | Status byte 15 | uv / wifi / voice / command source / device error bits | Always `0x01` | `uv_switch` always true, `device_error` always false | confirmed | status M10 |
| 22 | Dead status bits | `tail_sweep_clean`, `station_v2`, `personal_clean_prefer`, `dustDrag*`, `dustedTimes` | Never written | Always false/0 on this firmware | confirmed | status M11 |

### Errors and replies

| # | Area | Valetudo | Firmware | Impact | Confidence | Report |
|---|---|---|---|---|---|---|
| 23 | Error 1-22 | "Water tank missing", transient warning | Main board ↔ motor controller UART failure | Serious fault shown as a mild warning | confirmed | errors M3 |
| 24 | Error 1-21 | "Sterilization module fault" | LDS UART link failure | Wrong subsystem | confirmed | errors M2 |
| 25 | Error 1-23 | "Wipe chip error" | Internal motor controller error | Wrong message | confirmed | errors M4 |
| 26 | Error 1-24 | "LDS temperature" | Relocalisation failed | Wrong message and severity | confirmed | errors M5 |
| 27 | Error 1-20 | "Robot stuck" | Vibrating mop fault | Wrong subsystem | likely | errors M6 |
| 28 | Error 1-81 | "Virtual restrictions" | Bumper keeps triggering | Wrong message | confirmed | errors M8 |
| 29 | Errors 1-19, 1-83, 1-43 | Dock without power, wheel drop, charging | Docking failed, cliff sensor stop, raised in a wash-sink branch | Slightly off | likely / confirmed / speculative | errors M7, M9, M17 |
| 30 | Unknown robot codes | "Unknown error" | 1-25..30 (low battery needs dock, dust full, water box empty, turnplate, water bin missing, turnplate chip), 1-86, 1-95, 1-165, 1-168..172 | Real faults show as unknown | confirmed | errors M10 |
| 31 | Dock code 100 | "Dock communication error" | CollectDust | Any dock code puts the robot in ERROR, so dust collection may show as an error | likely | errors M11 |
| 32 | Dock codes 103 / 104 | Unknown (only 152 = wastewater) | Dirty water full / dirty tank missing | Full or missing wastewater tank may show as unknown error | likely | errors M12 |
| 33 | Dock codes 111, 112, 148 + ~16 unmapped | Tray not installed, tray full, air motor | Wash tray full, robot full, duct switch error | Wrong or missing messages | likely | errors M13, M14 |
| 34 | Dustbag codes 11/12/13 | Dustbag missing/full | Status only carries dock codes 100–219 | Dead code | confirmed | status M5, errors M15 |
| 35 | Toggle replies (0x9C) | Never checked | Error reply for unknown id, bad value or unsupported case | Failed toggles look successful until the next poll | likely | toggles M4 |
| 36 | Replies in general | `payload[3]` checked by some capabilities | Several handlers reply OK while ignoring input (0x51, 0x31, 0xC9, 0x01, 0x63, 0x92, 0x59); 0x50 throws instead of replying | Success checks aren't reliable | confirmed | settings M15 |
| 37 | Error event 0x04 0xA3 | Ignored | Pushed on every fault change | Errors appear only at the next status update | likely | errors M16 |
| 38 | Volume reply (0x93) | "Robot never acknowledges" | manager_node always replies | The ack is lost elsewhere (iot_node?) | likely | settings M8 |

### Other, low impact

| # | Area | Note | Confidence | Report |
|---|---|---|---|---|
| 39 | 0x9C `0x0f` = 0 | Also turns AI avoidance off. Valetudo never sends 0 | confirmed | toggles M7 |
| 40 | Status field names | `furniture_identify` = big-object detect, `frequent_auto_empty` = middle go-back dust, `obstacle_image_upload` = live photo; `ai_obstacle_switch` and `ai_avoidance_switch` are the same setting | confirmed | toggles M8, status M12–M14 |
| 41 | Dock state names | 5 = MopHotDry, 8 = ERP (low power), 9 = SelfClean (Valetudo comments say rag air drying, sleep in station, auto clean) | likely | status M4 |
| 42 | Segment clean (0x03) | Per-room fan/water bytes are ignored; only id, count and the first room's mode are read | confirmed | features M3 |
| 43 | Station stop (0x5A 0,0) | Also aborts a running auto-empty | confirmed | settings M9 |
| 44 | Segment rename | Reloading the map (0x24 op 1) also clears the path and active zones | likely | settings M12 |
| 45 | 0x22 | Is the save-map toggle, not LEGACY_MULTI. Not sent on the Pro Ultra | confirmed | settings M13 |
| 46 | Manual control | Direction 2 (probably backward) unused | speculative | settings M14 |
| 47 | Wi-Fi scan | Registered for Max Ultra only; the Pro Ultra has the same tools | likely | features M11 |
| 48 | Capabilities per model | Hard-coded per SN8 class; the firmware is one image and decides features from the MCU robot type and dock type, also reported by ACTION 0x59 (unread) | confirmed | features M5 |
| 49 | 0x03 0x30 (active segments) | No handler, no reply. Only the Max Ultra class sends it | confirmed (firmware side) | errors M1 |
| 50 | Other models | 0x9C `0x07` and `0x16` (J12 Ultra only) don't work on this firmware | confirmed for this firmware | toggles M5, M6 |

## Features Valetudo doesn't expose

The ones most relevant to cleaning:

| Feature | How it's set |
|---|---|
| Per-room fan, water, route (and probably the room `cleanSeq` from [room-order-investigation.md](room-order-investigation.md)) | SETTING `0x2B` → `CCentralController::SetRoomInfo` (layout partly decoded) |
| Criss-cross ("pound sign") pattern, zigzag to end | 0x9C `0x18`, `0x27` |
| AI carpet avoidance, carpet evade, per-carpet strategy, global carpet strategy | 0x9C `0x22`, `0x07`/`0x23`; SETTING `0x32`, `0xD2` |
| Curtain and threshold detection / map editing | 0x9C `0x3b`; SETTING `0x33`, `0x34` |
| Big-object recognition, fall-down detection, stain detection | 0x9C `0x32`, `0x34`, `0x3e`, `0x39` |
| Stuck-spot marking, narrow-zone recharge, cross bridge | 0x9C `0x24`, `0x1d`, `0x0a` |
| Continuous clean, child lock following DND | 0x9C `0x00`, `0x02` |
| Detergent / softener injection | 0x9C `0x04`, `0x05` |
| Dock self-clean trigger, reset dust counter | SETTING `0x5B`, `0x57` |
| Go to point, schedules, multi-floor maps, room types | SETTING `0x04`, `0x06`, `0x28`/`0x29`, `0x2A` |

Useful data Valetudo ignores: dock connected (status byte 33 bit 1), dock
self-cleaning (byte 50 bit 5), exact area (bytes 39–40), persistent warnings
(byte 64), dock position push (event 0x04 0x20), dock work progress (0x04
0xA8), mop-dock settings changed (0x04 0x95), room-order switch (0x04 0x28),
capability bits (ACTION 0x59). Full lists are in the detailed reports.

Don't expose casually: 0x9C `0x11` (SLAM version, reboots the LDS), `0x13`
(telnet), `0x3c` (adb pull), SETTING `0x90` (factory reset).

## Open questions

- What the planner's avoidance modes NORMAL / SMART / SUPER do (#2).
- How the planner acts on `disable_cliff_sensor`, and whether the user ever
  turned the sensors off (safety note).
- Carpet strategy enum values (#10, #14), mop drying method 1 vs 2 (#5), hot
  wash modes (#11), floor materials 1 and 4 (#19).
- Whether `iot_node_msmart` rewrites any byte between `manager_node` and
  Valetudo. All checks here are against `manager_node`.
- Whether an uncaught `std::out_of_range` (0x50 with a bad value) crashes
  `manager_node`.
- The full `0x2B` per-room layout.

## Method

Five parallel static analyses. Each read the Valetudo source and the
firmware handlers (`CIotCommunicationHandler::handleIotMsg0x<type>_0x<cmd>`
and `UpToIotMsg*` in `manager_node`, decoded with `llvm-objdump`, Python
reads of `std::map` initialiser tables, and Ghidra through REA), and checked
against frames in the saved manager logs where they exist (111 status
frames, a few queries and events). The error tables were spot-checked by
hand (`ErrInfo` records `{u64 code, u8 type, u8 desc, char *name}` at file
offset `0x6a73f8`).
