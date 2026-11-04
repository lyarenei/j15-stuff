# Valetudo vs J15 Pro Ultra firmware: SETTING (type 0x02) commands, excluding 0x9C

Firmware: `dumps/x2/usr/navi/manager_node` (sha256 049e9d56…50da). Valetudo: Hypfer/Valetudo 06cfc72, `backend/lib/robots/midea` and `backend/lib/msmart`.

**Frame offsets** (confirmed from `MSmartPacket.js` and `RespIotCmd<int>` @0x824820). `CIotFrame::GetUINT8Value(n)` indexes the whole frame:
- 0..9: header (byte 1 = length)
- 10: 0xAA
- 11: flags byte (Valetudo always sends 0x01)
- 12: cmd
- 13: first payload byte (Valetudo `buildPayload(cmd, [p0,…])` puts p0 at 13)

Responses are `[aa 01 cmd result]`, so Valetudo's `response.payload[3]` is the result byte. Flags bit 4 (0x10) switches MsgSource from 2 to 5. Valetudo never sets it, so every Valetudo write is handled as "source 2". With source 2, some handlers play sounds or skip the status push.

Data tables are std::map initialisers decoded from rodata. Addresses are given as `init@code / data@rodata`.

## (a) Command table

| cmd | Firmware handler meaning and payload (byte offsets from 13) | Valetudo usage (J15PU) | Match? |
|---|---|---|---|
| 0x01 work status | `[0]` → identity map 0..10 (data 0xad3428): 1 Recharge, 2/5/9 Pause, 3/6 Resume, 4 StartAutoClean, 7 Stop, 10 FastMapExplore. 0 and 8 do nothing but still return OK. Handler @0x8186f0 | BasicControlV2: 4 start, 6 resume, 7 stop, 5 pause, 1 home. MappingPassV2: 10 | yes |
| 0x02 manual | `[0]` dir → ManualDirectionDecoder (data 0xad2648): 0→4(stop), 1→1, 2→8, 3→2, 4→3, 5..7 identity, 0xff→0. `[1]` → SetManualCtrlMode. Unknown dir: logged, then the command is still issued with dir 0. @0x7fcdc0 | dir 0/1/3/4, mode 1 (cruise) | yes (dir 2 unused) |
| 0x03 segment clean | see [room-order-investigation.md](../room-order-investigation.md) | — | (covered there) |
| 0x05 zone clean | `[0]` count (0 → error 1). Then 10-byte entries: `[id][L u16le][T][R][B][iterations]`. A zone with any coordinate >800 is **silently dropped** and the command still returns OK. @0x80d2a0 | same layout, ≤5 zones, iterations 1–3 | layout yes (see M10) |
| 0x20 virtual walls | `[0]` count, then 9-byte entries `[id(ignored)][x1][y1][x2][y2]` u16le. Stack buffer holds 32 walls and the count is not bounds-checked. @0x7fd480 | same, ≤10 walls | yes |
| 0x21 restricted zones | `[0]` count, then 10-byte entries `[type][id(ignored)][minx][miny][maxx][maxy]`. Type map (data 0xac8c80): 0→1, 1→2, 2→3; unknown → 1. Buffer holds 32 zones. @0x7ff6f0 | type 0 regular, 1 no-mop, ≤10+10 | yes (type 2 unused) |
| 0x22 | **"save-map" switch** (persistent-map toggle) plus a 0x04_0x21 push. @0x814aa0 | LEGACY_MULTI. Only V1 caps use it; none are registered on the J15PU | n/a (see M13) |
| 0x24 map mgmt | `[0]` op, `[1]` mapId. op 1 use/load (also PushEmptyPath + PushEmptyAreaCleanParam), 2 delete, 3 save, 5 stash, 6 recover backup. Other ops: "Unsupport". @0x808d60 | MapResetV2: 2 = delete. SegmentRenameV2: 1 = reload current map | yes |
| 0x26 join | reads only `[1]`,`[2]` (two room ids); the count byte `[0]` is ignored. Result is sent via UpTo0x02_0x26, same `[aa 01 26 res]` format. @0x807ac0 | `[2, a, b]` | yes |
| 0x27 split | `[0..7]` x1,y1,x2,y2 u16le, `[8]` room id. @0x807e70 | same | yes |
| 0x2D valid map ids | `[0]` bitset → SetMapHouseIDSet. @0x8082e0 | `[0]` on reset | yes (5-min check documented in Valetudo) |
| 0x31 floor type | `[0]` count, then `[roomId][material]` pairs. GroundMaterialTypeDecoder (data 0xad27a8) is identity 0..4. Unknown material: logged, stored as 0, returns OK. @0x813a80 | 0 generic, 2 wood, 3 tile | yes (1 and 4 not offered) |
| 0x50 fan | `[0]` → MotorSpeedDecoder (init 0x5d9de0): 0→0, 4→1 quiet, 1→2 soft, 2→3 standard, 3→4 strong, 5→5 max. Calls SetMotorSpeed(type 2). A value not in the map throws `std::out_of_range`, with no error reply. @0x819470 | MIN 4, LOW 1, MED 2, HIGH 3 | yes |
| 0x51 water | `[0]` → WaterSpeedDecoder (data 0xad26d0): identity 0..3 and 100..130. A value not in the map is **ignored but still returns OK**. Status side uses InfiniteWaterSpeedEncoder (data 0xad2688): internal 0→100, 1→105, 2→120, 3→130, 100..130 identity. @0x819620 | 101/108/115/122/130 | values yes (see M4) |
| 0x52 | "carpet-detect" setting key. @0x815350 | not on J15PU (V2 cap not registered) | n/a |
| 0x56 dock intervals | `[0]` type: 1 = dust-collect interval, 2 = self-clean interval. `[1]` value, not validated. Any other type → error 1. @0x8198e0 | `(1, 0/1/3)` auto-empty, `(2, 0/1/3/5)` self-clean | yes |
| 0x58 operation mode | `[0]` must be in {0,1,2,3,5,6} (init 0x5ccd6c), else error 1. Then SetSweepMode (@0x97bf70): 3 = vacuum-then-mop (two steps); 5 = "[AiClean]", coerced to 0; 6 = single step with mop enabled; 4 is rejected. @0x7fc840 | 0..3 | partial (M3) |
| 0x59 mop dock settings | `[0..4]` copied raw into GlobalConfig+7..+0xb as (mode, gen_area, gen_wash, cus_area, cus_wash); no validation. SetMopWashParam (@0x782e30): if mode==0 it uses the general pair, otherwise the custom pair. `area` → MiddleBackStation::SetGobackInterval (0 is invalid; vacuum target is 2×area). `wash` → SetMopMiddleWashMode. With source 2 (bit 4 clear) it **plays /oem/sound/408.mp3**. @0x7fe350 | quirks rewrite gen_area (5/10/15/20/25) or gen_wash (2/3/4) and pass the other fields through | partial (M2) |
| 0x5A station action | `[0]` mode, `[1]` sets. sets=0: StopMopClean **and** StopCollectDust. sets=1: mode 1 StartMopClean; mode 2 prep event + StartCollectDust; mode 3 prep event + StartMopClean; mode 4 PushStationCtrlEvent(2,…). sets>1 → error. CSetStationCleanMode @0x77a270 | (2,1) empty, (1,1) wash, (0,0) stop | yes |
| 0x5C mop dry | `[0]` 1 start, 0 stop, other → error. @0x7fe740 | 1/0 | yes |
| 0x5E carpet | If frame length > 15, byte 15 is a carpet id (per-carpet strategy, SaveCarpetCleanStrategy). Otherwise global: `[0]` behavior via map (init 0x5cd224) 0↔1, 2↔3 (a value not in 0..3 → "invalid clean param", error 1); `[1]` bits: b0 "carpet-setting-sweep-first", b1 "carpet-setting-precisely", b2 "carpet-setting-boost", b3 "carpet-setting-ai-aviod". GET 0x03_0xAB encodes the inverse (init 0x5cc820). @0x819a20 | `[behavior, bitfield]`, 15-byte frame → global | yes (bit3 label, M6) |
| 0x63 stairless | `[0]` raw → setting "cliff-sensor"; always OK. @0x814690 | 1 = sensors off, 0 = on | consistent (polarity not verified) |
| 0x92 DND | flags bit 4 clear: `[0]` enabled (!=0), `[1]` start h, `[2]` start m, `[3]` end h, `[4]` end m. Bit 4 set: only `enabled`. Always OK. Pushes 0x04_0x91. If DND is now silent and flag @+0x13d is set → SetChildLockMode(1). @0x804db0 | same 5 bytes | yes |
| 0x93 volume | `[0]` → "volume" key, no range check. **Sends RespIotCmd(0x93, 0)**; if the value equals the current one, logs "volume is same" and still replies. @0x81b5f0 (resp 0x81b6ec/0x81b9ac) | value, fire-and-forget ("robot never acknowledges") | yes (M8) |
| 0x9B mop dry mode | `[0]` 0..7 accepted (>7 → error). SetMopDryMode → "mop-smart-dry-mode". Table (init 0x710940, data 0xb5b210) gives mode → (method, seconds): 0 (2, 21600), 1 (1, 10800), 2 (1, 3600), 3 (1, 6000), 4 (2, 10800), 5 (1, 7200), 6 (1, 10800), 7 (2, 21600). @0x7ffe10 | 5 "2h", 6 "3h", 7 "cold" | partial (M1) |
| 0xC5 hot wash | `[0]` 0..2 → SetStationHotWaterWashMode (>2 → error 1). CStationCtrl::SetStationHotWashMode (@0xa4c900) **turns 1 into 2** when station flag +0x377 is set. @0x7fee60 | 0 cold, 1 hot, 2 warm | values yes (M7) |
| 0xC7 auto-empty duration | `[0]` 1..3 → "collect-dust-mode", else error. @0x814ef0 | 1/2/3 short/med/long | yes |
| 0xC9 cleaning settings | `[0]` sub-id must be in {0,1,4,6,7} (init 0x5ccf14). Others are silently OK with no effect. Sub 0: route via kRouteTypeDecoder (data 0xad27d0) 0→2, 1→1, 2→3. Sub 1: cut-hair level 0..2. Sub 4: collect-suction 0..1. Sub 6: cut-hair super 0..1 ("cuthair-super-switch"). Sub 7: turbidity re-mop 0..1. @0x8157b0 | (0, route 0/1/2), (1, 0..2), (4, 0..1), (6, 0..1) | yes |

## (b) Mismatches

| # | Area | Valetudo says/does | Firmware actually does | Impact | Evidence | Confidence |
|---|---|---|---|---|---|---|
| M1 | Mop drying time (0x9B) | Offers only 5 = 2h, 6 = 3h, 7 = "cold". The getter throws "Received invalid value" for anything else. | Accepts 0..7. Per the table: 0 = method 2, 6h; 1 = method 1, 3h; 2 = method 1, 1h; 3 = method 1, 100 min; 4 = method 2, 3h; 5 = m1 2h; 6 = m1 3h; 7 = m2 6h. Method 2 is presumably cold air, since Valetudo's "cold" = 7 uses it. | If the app or firmware default leaves modes 0–4 set, Valetudo's drying-time control errors on read. The 1h, 100-min and cold 3h presets cannot be selected. Mode 1 duplicates 6 (3h); it might be the temperature-adaptive "smart" mode (manager.json `MopHotDry.TemperatureXX_YYTime`). | fw 0x7ffe10, 0x710940, data 0xb5b210; `MideaMopDockMopDryingTimeControlCapability.js:22-29` | table confirmed; hot/cold labels likely |
| M2 | Mop-dock wash frequency / intensity quirks (0x59) | Quirks change only `general_backwash_area` / `general_cleaning_mode` and pass `mode` through unchanged. | SetMopWashParam uses the **custom** pair when `mode` != 0, so Valetudo's change is stored but has no effect in that case. Every 0x59 write from Valetudo also plays voice prompt 408.mp3, because the flags byte has bit 4 clear (source ≠ 5). | User changes the wash frequency or intensity and nothing changes, if the app ever set custom mode. An unexpected voice prompt plays on each change. | fw 0x7fe350, 0x782e30; `MideaQuirkFactory.js:547-553, 622-628` | confirmed (code); meaning of mode≠0 ("custom") likely |
| M3 | Operation mode (0x58) | Presets 0..3. On success it updates `station_work_status` instead of `mopMode`. | Also accepts 5 ("AiClean", which SetSweepMode coerces to vacuum&mop) and 6 (single-step mode, mop enabled, VacuumMopMode 0). Rejects 4 with error. | If the app selects mode 5 or 6, Valetudo logs "unknown mopMode" and shows no mode. Separately, Valetudo's own optimistic state update is a no-op, so the UI lags until the next poll. | fw 0x7fc840, init 0x5ccd6c, 0x97bf70; `MideaOperationModeControlCapabilityV2.js:35`, `MideaValetudoRobot.js:1170-1175` | confirmed (code); meaning of 5/6 speculative |
| M4 | Water grade (0x51) | 5 presets 101..130. `parseAndUpdateState` re-sends the nearest preset whenever the reported value is >100 and not a preset. | 31 levels (100..130) plus legacy 0..3 are accepted. Internal 0 is reported as 100 (InfiniteWaterSpeedEncoder). A value not in the table is ignored, yet the reply is still OK (result 0). | A finer level set in the app is silently overwritten by Valetudo on the next status poll. Level 100 (likely the lowest/"off" step) is shown as unknown. Valetudo cannot tell that a rejected value was dropped. | fw 0x819620, data 0xad26d0/0xad2688; `MideaModernValetudoRobot.js:98-120`, `MideaValetudoRobot.js:1183-1189` | confirmed (code); meaning of 100 speculative |
| M5 | Fan speed (0x50) | MIN/LOW/MEDIUM/HIGH = 4/1/2/3; MAX 5 commented out. | Same enum: quiet/soft/standard/strong/max. Actual suction depends on operation mode (data-V15Overseas.json `chassis.suction`): vacuum&mop 180/240/450/585/1500, vacuum-only 240/450/585/900/1500. An out-of-map value throws `map::at` with no error reply. | "High" during vacuum+mop gives the same suction (585) as "Medium" in vacuum-only. Not a bug, but the presets are not absolute. | fw 0x819470, init 0x5d9de0; `MideaValetudoRobot.js:1157-1168` | confirmed |
| M6 | Carpet bit 3 quirk (0x5E) | "Increased Carpet Avoidance: stay further away from carpets". | Bit 3 is stored as `carpet-setting-ai-aviod`, which suggests AI/camera-based carpet avoidance rather than a distance margin. Bits 0..2 match (sweep-first, precisely = deep, boost). The behavior byte uses a 0↔1, 2↔3 remap, applied symmetrically on GET. | The label/description may be wrong. Functionally the round-trip is consistent. | fw 0x819a20 (key strings), init 0x5cd224/0x5cc820; `MideaQuirkFactory.js` INCREASED_CARPET_AVOIDANCE | speculative |
| M7 | Mop wash temperature (0xC5) | 0 cold, 1 hot, 2 warm. | 0..2 accepted. CStationCtrl::SetStationHotWashMode turns 1 into 2 when station flag +0x377 is set, so "hot" can silently become mode 2 (whatever 2 is). HeatWaterMode names were not recovered. | "Hot" may read back as "warm" on some docks. | fw 0x7fee60, 0xa4c900; `MideaMopDockMopWashTemperatureControlCapability.js:25-29, 40-44` | likely (promotion confirmed; enum meaning unverified) |
| M8 | Speaker volume (0x93) | Fire-and-forget; comment says "the robot never acknowledges this". | The handler always sends RespIotCmd(2, 0x93, 0) (two reply paths). No range check. | The missing ack is probably lost in iot_node/transport, not manager_node. Valetudo could await and verify. | fw 0x81b5f0 (bl RespIotCmd @0x81b6ec, 0x81b9ac); `MideaSpeakerVolumeControlCapabilityV2.js:52` | likely |
| M9 | Station stop (0x5A 0,0) | MopDockCleanManualTrigger.stopCleaning sends (0,0) "mode ignored". | (0,0) calls both StopMopClean **and** StopCollectDust. | Stopping a mop wash also aborts a running auto-empty. Minor. | fw 0x77a270; `MideaMopDockCleanManualTriggerCapability.js` | confirmed |
| M10 | Zone cleaning (0x05) | Sends converted coordinates and assumes success. | Any zone with a coordinate >800 is silently dropped and the reply is still OK. If none survive, StartAreaClean gets an empty list. | Zones near or outside the map edge vanish without error. | fw 0x80d2a0 (`< 0x321` checks) | confirmed |
| M11 | Floor material (0x31) | 0 generic, 2 wood, 3 tile. | 0..4 valid. 1 and 4 exist (names not recovered). Unknown values are stored as 0 and the reply is OK. | Materials 1 and 4 set by the app show as "unknown material" in Valetudo's map parser. | fw 0x813a80, data 0xad27a8; `MideaMapParser.js:941-945` | confirmed (existence); meaning unknown |
| M12 | Segment rename (0x24 op 1) | Uses "load map" to force a re-read. | op 1 "use map" also issues PushEmptyPath and PushEmptyAreaCleanParam. | Renaming may clear the displayed path and active-zone state. | fw 0x808d60 | likely |
| M13 | LEGACY_MULTI (0x22) | Named LEGACY_MULTI (multi-subcommand). | On this firmware 0x22 is the "save-map" toggle (`[0]` = switch). | None today: no registered J15PU capability sends it. A V1 capability on this robot would toggle persistent maps instead. | fw 0x814aa0; `MSmartConst.js` | confirmed |
| M14 | Manual control (0x02) | Directions stop/forward/left/right only. | Direction 2 maps to internal 8 (probably backward). 5..7 are also valid. | A backward move is available but not exposed. | fw 0x7fcdc0, data 0xad2648 | speculative (meaning) |
| M15 | Error reporting in general | Several caps check `payload[3]`. | Some handlers return 0 while ignoring input: 0x51 out-of-table, 0x31 bad material, 0xC9 sub 2/3/5, 0x01 values 0/8, 0x63, 0x92, 0x59. 0x50 has no error path at all; it throws. | Valetudo success checks are not reliable for these. | handlers above | confirmed |

Checked and found consistent: 0x01, 0x02 (used values), 0x20, 0x21, 0x26, 0x27, 0x2D, 0x56, 0x5C, 0x63 (round-trip), 0x92, 0xC7, 0xC9.

## (c) Firmware SETTING commands Valetudo never sends (J15PU)

| cmd | What it does (handler evidence) |
|---|---|
| 0x04 | StartGoToPoint (x, y): go to a point |
| 0x06 | Schedules: Add/Remove/Enable/Disable CleanPlan |
| 0x07, 0x08 | Small handlers with no named callees (unresolved) |
| 0x09 | StartSpecialCruiseView (patrol points) |
| 0x0A | StartSnapOrRecord (camera snapshot/record) |
| 0x0D | ClearWarning |
| 0x23 | "bIfSavedMap" flag |
| 0x25 | AutoSegmentRoomAndSaveMap / LockRoomMap |
| 0x28 | SetMutiHouseSwitch (multi-floor) |
| 0x29 | Start clean with a new house type (StartAutoClean variant) |
| 0x2A | SetRoomType (RoomTypeDecoder) |
| 0x2B | SetRoomInfo (per-room fan/water/etc.; GetDefaultFanSpeed) |
| 0x2E | SetCruisePoints |
| 0x2F | Bridge/threshold-crossing settings (SetBridgeSetting, StartCheckBridge) |
| 0x32 | SaveCarpetZone (manual carpet areas) |
| 0x33 | SetThreshold / SetDeleteThreshold ("door sill type") |
| 0x34 | SetCurtain / SetDeleteCurtain |
| 0x52 | "carpet-detect" toggle |
| 0x53, 0x55, 0x91, 0x94, 0x95, 0x97 | Generic "check:%d" setters via vtable (unresolved) |
| 0x54 | SetWSElectroWaterEnable (electrolysed water) |
| 0x57 | ResetCollectDustNum (bitfield) |
| 0x5B | SetStationSelfCleanStart/Stop (manual dock self-clean; Valetudo's comment calls this "0x5A mode 3") |
| 0x5D | "beautify_map_grade" (replies with cmd 0x5C, a firmware copy-paste) |
| 0x5F | ResetBatteryData / TriggerLevelCaliGyro |
| 0x60, 0x61 | SetMotorSpeed for the other motor types (likely side and roll brush). Both reply as 0x50 |
| 0x62 | McuSwitchMode (peripheral type/action) |
| 0x90 | ResetAll (factory reset) |
| 0x96 | SaveLogFile |
| 0x98 | OTA start (child-lock save) |
| 0x99 | StartMopClean / StopMopClean (older station wash path) |
| 0x9D | ReportEssentialInfo / SetNetworkState |
| 0x9E | PlaySound /oem/sound/N.mp3 |
| 0x9F | ProcStationKeyEvent (emulate a dock key) |
| 0xA0 | SetLDSReboot / SetRobotReset |
| 0xA3 | SetTargetReminderSetting |
| 0xA4 | ExitDocker |
| 0xC1 | Mop auto-dry thread ("p auto dry") |
| 0xC2 | Station work mode / test mode |
| 0xC3, 0xC4 | Map upload result acks (cloud) |
| 0xC6 | Status push only |
| 0xC8 | SetReportSoundMode / special tests |
| 0xCD, 0xCF | Exhibition-mode device control / info |
| 0xD0 | Voice-assistant TLV (VoiceStartAutoClean / CallClean, skip-clean) |
| 0xD2 | "global-carpet-strategy" |

## (d) Open questions / not covered
- **0x03 (segment cleanup):** not re-analysed here; see [room-order-investigation.md](../room-order-investigation.md).
- **0x9C:** excluded, see [toggles-0x9c.md](toggles-0x9c.md).
- **Internal enum names** not recovered for: HeatWaterMode (0xC5), DryMopMethod 1/2, ground material 1 and 4, ForbiddenZoneType 3, RouteType 1/2/3, carpet strategy internal 0..3 (which value means avoid / cross / lift / ignore in planner), SweepMopMode 6, CleanStopType. Valetudo's labels for these are inherited, not verified against firmware.
- **0x63 polarity:** "cliff-sensor" = 1 meaning "no-cliff mode" is inferred from `EnableMcuNoCliffSensorMode`. The consumer of the setting key was not traced.
- **0x59 mode semantics:** that mode≠0 is the app's "custom" setting, and what MopMiddleWashMode 2/3/4 does inside StationConfigs, were not decoded.
- **Uncaught `map::at`:** whether a `std::out_of_range` thrown inside a handler (0x50, 0x02 and others) is caught by the dispatcher or aborts manager_node was not verified.
- **0x5A modes 3/4** and the 0x53/55/91/94/95/97 vtable targets were not resolved.
- **Static analysis only:** the iot debug logs in dumps/logs contain no SETTING handler traces (debug level off), so nothing above was checked at runtime.
