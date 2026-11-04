# STATUS packet: manager_node firmware vs Valetudo (Hypfer/Valetudo 06cfc72)

Firmware: `dumps/x2/usr/navi/manager_node` sha256 049e9d56…50da. Builders:
`CIotCommunicationHandler::handleIotMsg0x03_0x01` @0x815eb0 (ACTION GET_STATUS reply, msgtype 3) and
`UpToIotMsg0x04_0x01` @0x8172f0 (EVENT, msgtype 4). They are byte-for-byte the same builder. The only
differences: msgtype byte, `GetGlobalConfig(arg 1 vs 0)` (dump-to-log flag only), an extra
`GetSlamVersion` log line, and the 0x03 handler then calls `SetUpStatusInterval(GetUpIntervalQuick())`.
No separate shared builder exists. The event fires from `RobotStatusCallback` @0x818b10 and from
`CCStationStatusCallback` @0x818b50 (the latter only when the StationStatus changes).

Offset convention: the firmware writes CIotFrame offset F, where frame[9] is the msgtype and frame[10..12]
is `aa 01 01`. Valetudo `payload[i]` is frame[i+10]. The highest offset written is 0x53, so the payload is
74 bytes (frame len byte 0x54). This matches the 111 logged frames (`[IOT] TcpServer::_Dump` in the saved
manager logs), so all of Valetudo's `length >=` gates pass. `SetBITValue(off,bit,v)` sets `1<<bit`
only when `v==1` (LSB = bit 0). `SetUINT16Value` is little-endian. Bytes that are never written are 0.

Source key:
- RS = `manager::comm::RobotSettings`, copied to IoT `this+0x124` (`_settingCallback` @0x7fae00) and to
  CC `+0xd98`. Names come from `CCentralController::UpdateSetting` @0x791090 and `_LoadSettings` @0x791770.
- SS = `Manager::StationStatus` (12 B), copied to IoT `this+0x160` and sourced from CC `+0xa98`. Names come
  from `_ProcStationStatus` @0x785670 and `WaterStationStatusCallback` @0x9833e0.
- GC = `Manager::GlobalConfig` (`CGlobalConfigSetting+0x60`). Names come from `CGlobalConfigSetting::dump`
  @0x7cc0a0: mop_mode, ?, ?, fan, side_brush, brush, water, washtype, freq, time, freq, time, ele_water,
  dust_interval, self_clean_interval, cut_hair_level, collect_suction_level.
- RSt = `RobotStatus*` at IoT `this+0x100`.

## (a) Payload map

| p[i] (F) | Firmware source | Valetudo field | Match? |
|---|---|---|---|
| 3 (0x0d) | `WorkStatusEncoder[RSt+0x11]`. If the key is missing, writes **3** and logs an error | work_status | offset OK. Enum differs, see (c) |
| 4 (0x0e) | const 0 | function_type | always 0 |
| 5 (0x0f) | `(RSt+0x11 != 9 /*Manual*/) + 1`, so 1 = manual, 2 = otherwise | control_type | OK |
| 6 (0x10) | `ManualDirectionEncoder[RSt+0x20]` (internal 0 maps to 0xff) | move_direction | OK |
| 7 (0x11) | `CleanModeEncoder[RSt+0xf]` {0→0,1→8,2→4,3→11,4→10,7→12,8→17,9→15,10→14} | work_mode | OK (unused) |
| 8 (0x12) | `MotorSpeedEncoder[GC.fan]` {0→0,1→4,2→1,3→2,4→3,5→5}. This is the **configured** fan, not a runtime value | fan_level | OK, see M7 |
| 9 (0x13) | `RSt+0x16 (u16 area) % 255` | work_area low | **divisor mismatch** (M2) |
| 10 (0x14) | `ManagerRuntime+0x129 ? InfiniteWaterSpeedEncoder[GC.water] (default 120) : WaterSpeedEncoder[GC.water] (default 2)` | water_level | OK, see M8 |
| 11 (0x15) | `RSt+0` volume, forced to 0 while `CDNDSetting::IsInSilentState` | voice_level | see M6 |
| 12 (0x16) | not written (0) | — (ignored) | OK |
| 13 (0x17) | `RSt+1` | battery_percent | OK |
| 14 (0x18) | `RSt+0x18 (u16 time) % 255` | work_time low | **divisor mismatch** (M2) |
| 15 (0x19) | const **1** | uv/wifi/voice/command_source/device_error bits | bits are fake (M10) |
| 16 (0x1a) | `this+0xec` = last `UpToIotMsg0x04_0xA3` error_type (sticky) | error_type | OK |
| 17 (0x1b) | `this+0xf0` = last 0xA3 error_desc | error_desc | OK |
| 18 (0x1c) | `RSt+8` | has_mop (b0) / has_vibrate_mop (b1) | likely OK (struct name not verified) |
| 19 (0x1d) | `RSt+9` | carpet_switch | likely OK |
| 20 (0x1e) | const 0 | — | OK |
| 21 (0x1f) | `CleanTypeEncoder[RSt+0x10]` (identity 0,1,2,3,5,6,7; no 4) | cleaning_type | OK |
| 22 (0x20) | `area/255 \| (time/255)<<4` | hi nibbles of area/time | nibble position OK (resolves Valetudo's "[22] vs [23]" TODO). Divisor is 255 (M2) |
| 23 (0x21) | `RSt+0xa` | vibrate_mode | OK |
| 24 (0x22) | `RSt+0xd` | vibrate_switch | OK |
| 25 (0x23) | GC.ele_water | electrolyzed_water | OK |
| 26 (0x24) | SS+9 (CC+0xaa1, read by `SetWSElectroWaterEnable`) | electrolyzed_water_status | OK |
| 27 (0x25) | const 0 | dustDragSwitch/dustDragStatus | always false |
| 28 (0x26) | GC.dust_interval | dustTimes | OK |
| 29 (0x27) | const 0 | dustedTimes | always 0 |
| 30 (0x28) | const 4 | chargeDockType | constant |
| 31-32 | not written | — | — |
| 33 (0x2b) | b0=0, b1=SS+0 (BLE station `heart_beat_status` = dock connected), b2=`IsFluidOK(1)`, b3=`IsFluidOK(2)`, b4=`IsDustBagFull`, b5=`IsDustBagInstalled` | b2 fluid_1_ok, b3 fluid_2_ok, b4 dustbag_full, b5 dustbag_installed | OK. **b1 ignored** |
| 34 (0x2c) | GC.mop_mode (raw) | mopMode | OK (logged value 3 = vacuum-then-mop) |
| 35 (0x2d) | SS+8 station error, **only if 100..219, else 0** | station_error_code | see M5 |
| 36 (0x2e) | **multiplexed** on RSt+0x11: OnStation(15) gives SS+4 WSStatus if <14 else 0; Relocation(10) gives `GetRelocationReason()`; Sleep(4) gives CC+0xb59 sleep reason (49-53); otherwise not written (0) | station_work_status | **semantic mismatch** (M3) |
| 37 (0x2f) | `GetJobState()` | job_state | OK |
| 38 (0x30) | `SweepMode::GetWholeProState()` | whole_process_state | OK |
| 39-40 (0x31-32) | area u16 **big-endian, full precision** | ignored ("unknown") | useful (M2) |
| 41 (0x33) | `GetContinuousCleanMode()` | continuous_clean_mode | OK |
| 42 (0x34) | RS[6] = `save-map` switch (CC+0x786, `SetSaveMapSwitch`) | ignored ("42 is unknown") | useful |
| 43 (0x35) | `GetCleanSeqSwitch()` | clean_sequence_switch | OK |
| 44 (0x36) | SS+10 = `ws_board_series` | ignored | info |
| 45 (0x37) | b0 `GetChildLockMode()`, b1 RS[0x19] `childLock-followDND-switch` | child_lock_enabled / child_lock_follows_dnd | OK |
| 46-49 (0x38-3b) | per-handler status counter `this+0x60`, incremented every frame, u32 **BE** | ignored ("async_number?") | it is a sequence number |
| 50 (0x3c) | b0 never written, b1 `GetStationInjectFluidSwitch`, b2 `GetStationInjectFluid2Switch`, b3=0, b4 `GetCarpetEvadeSwitch` (vtbl+0x1a0), b5 `SS.WSStatus==9 (SelfClean)`, b6 `GetStationFirstFastWash`, b7 `GetPetModeSwitch` | b0 personal_clean_prefer, b1 inject_fluid, b2 inject_soft_fluid, b4 carpet_evade, b6 first_fast_wash, b7 pet_mode | b0 is dead. **b5 ignored** |
| 51 | not written | — | — |
| 52 (0x3e) | `CCGetStationCapability()` | station_capability_flags | OK |
| 53 (0x3f) | b0 `GetStainCleanSwitch`, b1 RS[1] ai_avoidance_switch, b2 RS[0x1a] cross_bridge, b3 `GetCameraLedSwitch`, b4 `Get3DMapSwitch`, b5 `GetRecognitionSwitch` | stain_clean, ai_obstacle, cross_bridge, camera_led, map_3d, ai_recognition | OK (b1 duplicates p68 b3) |
| 54 (0x40) | `GetTestModeType()` | test_mode_type | OK |
| 55 (0x41) | `GetStationHotWaterWashMode()` | hot_water_wash_mode | OK |
| 56 (0x42) | b0 `GetStationSelfFluid2Switch`, b1 `GetSlamVersion()!=0`, b2 `GetHotDryChargePlateSwitch`, b3 RS[0x1d] `enable_telnet`, b4 `GetMopAutoDrySwitch` (vtbl+0x1e0), b5 `GetAiGradeAvoidanceMode()!=0`, **b6 never written**, b7 `GetPoundSignSwitch` | …, b6 tail_sweep_clean_switch, … | b6 dead (M11). b5 collapses a 3-value enum to a bool |
| 57 (0x43) | GC.self_clean_interval | stationCleanFrequency | OK |
| 58 (0x44) | RS[0xd] beautify-map grade (`SetBeautifyMapGrade`) | beautify_map_grade | OK |
| 59 (0x45) | RS[2] collect-dust mode (`SetCollectDustTime`) | collect_dust_mode | OK |
| 60 | not written | — | — |
| 61 (0x47) | `GetSessionId()` | session_id | OK |
| 62 (0x48) | `GetTransactionId()` | transaction_id | OK |
| 63 (0x49) | b3 `GetBridgeBoostSwitch`, b4 `GetNarrowZoneRechargeSwitch`, b5 RS[0xc] verification-map (`SetVerfictionMapSwitch`) | bridge_boost, narrow_zone_recharge, verification_map | OK |
| 64 (0x4a) | CC+0xc89 `PersistentWarning` bitmask (`SetWarning`/`ClearWarning`) | ignored | useful |
| 65 (0x4b) | b0 `GetWakeUpSwitch`, b1 `GetAICarpetAvoidSwitch`, b2 `GetCarpetEvadeAdaptive` (vtbl+0x1a8), b3 `GetStuckMarkSwitch`, b5 `GetMopExtendSwitch`, b6 `GetZigzagToEndSwitch` | wake_up, ai_carpet_avoid, carpet_evade_adaptive, stuck_mark, mop_extend, zigzag_to_end | OK |
| 66-67 (0x4c) | `RSt+0x1a` u16 LE | remaining_area (readUInt16LE) | OK |
| 68 (0x4e) | b3 RS[1] ai_avoidance, b4 `GetGapDeepCleaningSwitch`, b5 `GetFurnitureLegsCleaningSwitch`, b7 RS[0x1c] `edge_deep_vacuum` | ai_avoidance, gap_deep_cleaning, furniture_legs_cleaning, edge_deep_vacuum | OK |
| 69 (0x4f) | b0 `CC+0xab3==1` (unidentified), b1 `!IsStationWorkManually()` | ignored | unparsed |
| 70 (0x50) | b0 `GetBigObjectDetectSwitch`, b1 `GetMiddleGobackDustSwitch`, b2 `GetFallDownDetectSwitch`, b3 RS[0] `live_photo_switch`, b6 RS[0x1f] `threshold_detect_switch`, b7 RS[0x20] `curtain_detect_switch` | furniture_identify, frequent_auto_empty, fall_detection, obstacle_image_upload, threshold_recognition, curtain_recognition | OK semantically (names differ: big-object, middle-goback-dust, live-photo) |
| 71 | not written | — | — |
| 72 (0x52) | RS[0x28] (CC+0x7d9; `UpdateSetting` cases 0xe/0x1e test `!= 2` for CarpetStrategySetting) | ignored | unparsed |
| 73 (0x53) | b0 BlackBoard `GOLBAL::adb_pull_switch` (sic), **b1 never written**, b2 BlackBoard `GLOBAL::stain_detect_switch`, b3 RS[0x29] `cliff-sensor` (`!=0`) | adb_switch, station_v2_switch, static_stain_recognition, stairless_mode | b1 dead. See Q1 for b3 |

## (b) Mismatches

| # | Area | Valetudo says/does | Firmware actually does | Impact | Evidence | Confidence |
|---|---|---|---|---|---|---|
| M1 | work_status 3 | `STATUS_MAP[3] = DOCKED` | 3 is `GoingHomePause` (internal 8). It is also the **fallback** for any unmapped internal state (0, 5, 20 `VoiceInteraction`) | Robot paused mid-floor while returning shows "docked", without the resumable flag unless job_state>0. Voice-interaction or unknown states also show "docked" | encoder table init @0x5d9100. Fallback `SetUINT8Value(0xd,3)` @0x818398/0x816f98. StateToString @0x8af9c0. Valetudo MideaValetudoRobot.js:1198-1200 | confirmed |
| M2 | work_area / work_time hi bits | `((p22 & 0x0f) << 8) + p9`, `((p22 >> 4) << 8) + p14` | lo = v % **255**, hi = v / **255** (magic 0x80808081 >>39 @0x8175cc-0x8175ec). The hi nibble caps at 15, so the maximum is 4079 | Value is off by +1 per 255 (300 m² reads as 301). Area >4079 m² would bleed into the time nibble. p39-40 already carry the exact area as u16 BE, and Valetudo ignores it | 0x8172f0 F0x13/0x18/0x20/0x31/0x32. BEightParser.js:328, :336 | confirmed |
| M3 | p36 "station_work_status" → DockStatus | Always maps p36 through `DOCK_STATUS_MAP` to the dock state | p36 depends on the work status. OnStation gives WSStatus 0-13. **Relocation** gives a relocation reason. **Sleep** gives a sleep reason (49 work_pause, 50 stop, 51 charge_pause, 52 back_pause, 53 cruise_pause, written in `StartCleanTimer` thunk @0x772af0). All other states give 0 | Dock status shows PAUSE when the robot is asleep (even off-dock) and IDLE during relocation. In every other state it is forced to IDLE whatever the dock is doing. The 48-53/80-89 entries actually describe the *robot*, not the dock | 0x8178a0-0x817990 logic. BEightParser.js:376. MideaValetudoRobot.js:336-340, 1268-1300 | confirmed |
| M4 | WSStatus naming | comments: 5 "rag_air_drying", 8 "sleep_in_station", 9 "auto_clean" | Enum string table: 0 Idle, 1 Charging, 2 InjectWaterToRobot, 3 WorkClean, 4 MopDry, 5 **MopHotDry**, 6 Err, 7 ChargeDone, 8 **ERP** (low-power), 9 **SelfClean**, 10 CollectDust, 11 CutHair, 12 WaitCharge, 13 DrainWaterTank | Mapping outcome is fine, labels are slightly off. Order inferred from string order, consistent with `_ProcStationStatus` (7→ERP timer, 6→abort) and logs (ChargeDone→ERP, p36=8) | strings near "WSStatus::Idle". `GetWSStatusSTR` @0xa55dd0 | likely |
| M5 | station_error_code values | Treats 11, 12, 13 as dustbag missing/full | Firmware zeroes any station error outside 100..219 (`(x-100)&0xff > 0x77 → 0`) | Dustbag branches for 11/12/13 are dead on this firmware. Every non-zero code is ≥100 | F0x2d @0x817950. MideaValetudoRobot.js:255-263 | confirmed |
| M6 | voice_level | Speaker volume capability returns `voice_level` | Sends 0 while DND silent state is active | UI reports volume 0 during DND hours. A read-modify-write could persist 0 | F0x15 @0x81768c-0x8176ac. MideaSpeakerVolumeControlCapabilityV2.js:27 | confirmed |
| M7 | fan_level / water_level / mopMode | Treated as current state | Taken from `GetGlobalConfig()`, the persisted default settings, not per-room or runtime values | During segment cleaning with per-room presets, Valetudo shows the global preset | 0x817318, local_40/3d/3a | confirmed (impact speculative) |
| M8 | water_level range | J15PU uses HIGH_RES {101,108,115,122,130}. Values >100 that do not match are normalized by re-sending | Infinite mode can emit any 100..130 (legacy 0→100, 1→105, 2→120, 3→130). Fallback is 120. Non-infinite mode (`ManagerRuntime+0x129==0`) emits 0-3 (fallback 2) | 100 is not ">100", so it is logged as unknown and never normalized. If the runtime flag were 0, every value would be unmapped | encoder table @0x5d9100 (35 pairs). MideaModernValetudoRobot.js:101-104 | confirmed (whether 100 occurs is speculative) |
| M9 | fan 0 / 5 | FAN_SPEEDS has only 1-4 | Encoder emits 0 (internal 0) and 5 (internal 5) | "unknown fan_level" warning, and the attribute is not updated | MideaValetudoRobot.js:1157-1168 | confirmed (whether reached is unverified) |
| M10 | p15 flags | uv/wifi/voice/command_source/device_error bits | Constant 0x01 | `uv_switch` is always true and `device_error` always false, so p15 is useless as an error signal | F0x19 | confirmed |
| M11 | Dead bits | `tail_sweep_clean_switch` p56 b6, `station_v2_switch` p73 b1, `personal_clean_prefer_switch` p50 b0, `dustDrag*` p27, `dustedTimes` p29 | Never written (always 0) on this firmware | Any J15PU logic keyed on them reads false/0. MopTwistV1 (tail_sweep) is not registered for J15PU, so no live impact | builder listing | confirmed |
| M12 | duplicate | `ai_obstacle_switch` (p53 b1) and `ai_avoidance_switch` (p68 b3) are separate fields | Both are RS[1] `ai_avoidance_switch` (`this+0x125 != 0`) | None (naming only) | F0x3f b1, F0x4e b3 | confirmed |
| M13 | naming | `furniture_identify_switch`, `frequent_auto_empty`, `obstacle_image_upload_switch` | `GetBigObjectDetectSwitch` (big_object_switch), `GetMiddleGobackDustSwitch` (middle-goback-dust), RS[0] `live_photo_switch` | Semantics plausibly equal, names differ | UpdateSetting cases 1/0x13. F0x50 | likely |
| M14 | ai_grade_avoidance_mode in status | bool | `GetAiGradeAvoidanceMode()!=0` (enum 0 off/1 high/2 normal collapsed) | None. Valetudo reads the full value from 0xAA | F0x42 b5 | confirmed |

## (c) Enum tables

WorkStatus (internal `Manager::WorkStatus` from `StateToString` @0x8af9c0) → IoT p3 → Valetudo:

| internal | name | IoT | Valetudo STATUS_MAP | OK? |
|---|---|---|---|---|
| 1 | Cleaning | 5 | CLEANING | ✓ |
| 2 | Paused | 6 | PAUSED (resumable) | ✓ |
| 3 | Standby | 7 | IDLE | ✓ |
| 4 | Sleep | 10 | IDLE | ✓ |
| 6 | Error | 9 | ERROR | ✓ |
| 7 | GoingHome | 1 | RETURNING | ✓ |
| 8 | GoingHomePause | **3** | **DOCKED** | ✗ should be PAUSED, resumable |
| 9 | Manual | 17 | MANUAL_CONTROL | ✓ |
| 10 | Relocation | 11 | MOVING | ✓ |
| 11 | MapExplore | 12 | MOVING+MAPPING | ✓ |
| 12 | MapExplorePause | 21 | PAUSED | ✓ |
| 13 | GoingStation | 14 | RETURNING | ✓ |
| 14 | GoingStationPause | 15 | PAUSED | ✓ |
| 15 | OnStation | 18 | DOCKED | ✓ |
| 16 | Cruising | 19 | MOVING | ✓ |
| 17 | CruisePause | 20 | PAUSED | ✓ |
| 18 | TargetReminder | 23 | IDLE | ~ |
| 19 | BridgeCheck | 22 | MOVING | ✓ |
| 0, 5, 20 VoiceInteraction | (unmapped) | **3** (fallback) | DOCKED | ✗ |

The firmware never emits IoT 2, 4, 8, 13 or 16. Valetudo's DOCKED entries for those are dead on this robot.

Fan (MotorSpeed internal → IoT): 0→0, 1→4, 2→1, 3→2, 4→3, 5→5. Valetudo maps only 4 MIN, 1 LOW, 2 MED, 3 HIGH. Its order matches.

Water: non-infinite {0,1,2,3} identity (fallback 2). Infinite: {0→100, 1→105, 2→120, 3→130, 100..130 identity} (fallback 120).

p36 contexts: WSStatus 0-13 (see M4). Sleep reason 48?/49-53 (49 from Paused or MapExplorePause, 50 from Standby, 51 from GoingHomePause, 52 from GoingStationPause, 53 from CruisePause). Relocation reason from `GetRelocationReason()`; the values were not decoded here, and Valetudo assumes 80-89.

## (d) Open questions

1. **Cliff sensors (p73 b3, high priority).** Every logged frame has p73 = 0x08, so `cliff-sensor` = 1, and Valetudo's CLIFF_SENSORS quirk would report sensors "off" (quirk setter: off→1). Firmware passes `cliff-sensor != 0` as planner FlagMode 0x19 (`_setCliffSensorControl` @0x77e170). Either the user really disabled cliff sensors, or 1 means "enabled" and Valetudo's polarity is inverted, which would be dangerous. Next step: check the user's `cliff-sensor` value, or how planner_node handles FlagMode 25.
   **Follow-up (2026-11-04):** the 0x63 handler (`0x814690`) stores payload byte 13 unchanged as `cliff-sensor`, and the planner stores the FlagMode 25 value with `PlannerCore::SetCliffSensor(bool)` (`planner 0x59d6a0`, field `+0x41a`, read in `RunOnce`), whose log line calls it `disale_cliff_sensor` (sic). So 1 means *disabled*, Valetudo's polarity is right, and the stored setting in these logs means the cliff sensors were **disabled**. The owner confirmed they're intentionally off on this unit, so the polarity is settled. How `RunOnce` acts on the flag wasn't traced.
2. p72 = RS[0x28]: unknown carpet-strategy-related setting. The logged value is 1.
3. p69 b0 = `CC+0xab3 == 1`: unidentified.
4. Values returned by `GetRelocationReason()` (Valetudo assumes 80-89). Not verified.
5. Whether fan 0/5 and water 100 occur in practice, and what sets `ManagerRuntime+0x129` (infinite water). Logs show water 115, so it is set on this unit.
6. Field names inside RSt (`+8` mop byte, `+9` carpet, `+0xa`/`+0xd` vibrate) were not traced to named setters. Valetudo's naming was kept and matches logged values (has_mop=1).
7. iot_node_msmart relays these frames. Whether it rewrites any byte before Valetudo or the cloud sees them was not checked. The logged frames are on the manager↔iot TCP link.
