# Mismatch report D: ACTION queries, events, error codes (J15 Pro Ultra)

Firmware: `dumps/x2/usr/navi/manager_node` (sha256 049e9d56…50da). Valetudo: Hypfer/Valetudo 06cfc72.
Payload offsets below are MSmart payload offsets (frame offset − 10), so `[0]=0xAA [1]=0x01 [2]=cmd`, as in BEightParser.
Paths: `V/` = Valetudo `backend/lib/`.

## How the firmware dispatches (needed context)

`CIotCommunicationHandler::OnRecvIotFrame` @0x810470:
- For msg type 2 or 3 with `payload[0] != 0xAA`, it logs "unsupport cmd … send back" and **echoes the request frame back**. That covers every legacy `LEGACY_MULTI_*` (0x32/0x35) request.
- Otherwise it looks up `"handle0x%02X_0x%02X"` (type, payload[2]) in a hash map. The 121 keys are listed in `.rodata` (`strings | grep ^handle0x`).
- If there's no handler and type==2, it echoes the request. If type==3, no reply goes out at all: type 3 is in the std::set<u8> {0x00,0x02,0x03,0x04,0x0A,0xA0} @0xc61780 (initialised @0x5cd534), so it isn't routed to `handleOldIotMsg` either.

There is **no `handle0x03_0x30`**, so `GET_ACTIVE_SEGMENTS` (0x30) is dropped silently and Valetudo's `sendCommand` times out.

## (a) Command / event table

| cmd / event | Firmware layout / meaning (payload offsets) | Valetudo handling | Match? |
|---|---|---|---|
| 0x03 0x01 GET_STATUS | Status block (see [status-packet.md](status-packet.md)). Error fields: `[16]=this+0xec` (last A3 type), `[17]=this+0xf0` (last A3 index), `[35]=this+0x168` station error code, sent only if 100..219, otherwise 0 (@0x817944). `[42]=this+0x12a` (unknown flag, also sent by 0x03_0x25 and event 0x04_0x21) | `_parse_status_payload` | error offsets match |
| 0x03 0x20 LIST_MAPS | `[3]=1` (const), `[4]=current map id`, `[5]=popcount(bitmask&0xFFFF)`, `[6]=4` (const), `[7..8]=bitmask u16 LE` (@0x800910, `CMapHandler::GetMultiHouseInfo` = fields +0x1d61fc/+0x1d6200) | `currentMapId=[4]`, `count=[5]`, `bitfield=u16LE[7]`, bit i → id i+1 | yes (bit→id mapping not proven statically) |
| 0x03 0x22 POLL_MAP | Replies `[3]=0`, then `ReportFullMap(1,0)` over the map channel (@0x800e00) | reply ignored | yes |
| 0x03 0x24 GET_DOCK_POSITION | `[3]=valid`, `[4..5]=x u16LE`, `[6..7]=y`, `[8..9]=angle` (ChargeDockOdo +0,+2,+4; valid=+6). If invalid: 7 zero bytes (@0x801270). Log sample: `aa 01 24 01 88 01 90 01 00 00` → (392,400,0) | `valid=[3]==1`, `x/y/angle=u16LE` | yes (angle sign/units unverified) |
| 0x03 0x27 GET_ACTIVE_ZONES | `[3]=count`, then 10 B per zone: `idx(0-based), passes, minX, minY, maxX, maxY` (u16LE) (@0x801960; CMapRange normalises to [0]=minX,[4]=maxY,[8]=maxX,[c]=minY @0x890840, and the emit order is 0,c,8,4) | `index, passes, pA.x, pA.y, pC.x, pC.y` | yes. pA/pC are min/max corners, not the original click order. The index is 0-based in the reply but 1-based in Valetudo's 0x02 0x05 request; the firmware ignores it |
| 0x04 0x22 (event) | Same layout as 0x03 0x27 (@0x808660). Pushed after every 0x02 0x05 | parsed as active zones | yes |
| 0x03 0x30 GET_ACTIVE_SEGMENTS | **No handler**. Silently dropped, no reply | `MideaJ15MaxUltraValetudoRobot.executeMapPoll` only; not sent on the J15PU path | n/a for J15PU (see M1) |
| 0x03 0x57 LOCATE | Plays `/oem/sound/34.mp3` unless `payload[1]&0x10`; reply `[3]=0` (@0x80e6c0) | fire-and-ignore | yes |
| 0x03 0x90 GET_DND | `[3]=enabled`, `[4]=startH`, `[5]=startM`, `[6]=endH`, `[7]=endM` (CDNDSetting +0x28..+0x2c; vol +0x2d is not sent) (@0x803a80, GetDndParam @0x7766b0) | same | yes |
| 0x04 0x91 (event) | Identical to 0x03 0x90 (@0x804b00) | parsed as DND | yes |
| 0x03 0x93 GET_MOP_DOCK_SETTINGS | `[1]` = 1, or 2 if `ManagerRuntime+0x131` is set. `[3..7]` = GlobalConfig bytes 7..11 (@0x804190). Setter 0x02 0x59 writes the same 5 bytes back (@0x7fe350) | mode, general_backwash_area, general_cleaning_mode, custom_backwash_area, custom_cleaning_mode | layout matches and round-trips. `[1]`≠1 is ignored (harmless) |
| 0x04 0x95 (event) | Same 5 GlobalConfig bytes as 0x93 at `[3..7]` (@0x804fa0) | not handled ("Unhandled EVENT") | ignored |
| 0x03 0x94 GET_MOP_DOCK_DRYING_SETTINGS | `[3]` = dry mode mapped through std::map @0xc61658 (same map as setter 0x02 0x9B, which accepts 0..7). `[4..5]` = **big-endian** u16 of `(vtable+0x1e8 value)/60` (@0x80a220) | `mode=[3]` (5/6/7), `time_remaining=u16BE[4]` | yes (time unit: source/60, probably minutes) |
| 0x03 0xAA GET_CLEANING_SETTINGS_1 | `[3]` = route type via kRouteTypeEncoder (default 1), `[4]` = GlobalConfig+0xf, `[5..6]` not written, `[7]` = GlobalConfig+0x10, `[8]` = this+0x142, `[9]` = GetAiGradeAvoidanceMode, `[10]` = this+0x13f, `[11]` = GetTurbidityReMopSwitch (@0x80b780) | route_type[3], cut_hair_level[4], collect_suction_level[7], exhibition[8], ai_grade[9], cut_hair_super[10], turbidity[11] | offsets match. Names for [8]/[10] not proven; setter 0x02 0xC9 subtypes 0=route, 1=cut hair (0..2), 4=collect suction (0..1), 6=cut-hair-super (0..1), 7=turbidity (0..1) are consistent (@0x8157b0). The IoT→internal subtype map @0xc61810 was not decoded |
| 0x04 0xAA (event) | Same as 0x03 0xAA (@0x80bb70) | parsed | yes |
| 0x03 0xAB GET_CARPET_BEHAVIOR | `[3]` = this+0x132 mapped through map @0xc61718 (falls back to key 2 if missing). `[4]` bits 0..3 = this+0x133/0x134/0x135/0x136 (@0x80bed0) | `carpet_behavior=[3]`, bitfield `[4]` with bits 0..3 | yes (bit meanings not checked against the setter 0x02 0x5E) |
| 0x04 0xA3 ERROR (event) | `[3]` = fault type, `[4]` = fault index (desc), `[5]` = station error code (StationInfo+4), `[6]` = transaction id, `[7]` = StationInfo+0x12 (@0x8093e0, filled by RobotFaultCallback @0x8097c0 and `_ProcStationStatus` @0x785670). Type 0 means cleared. Log: `aa 01 a3 00 00 00 0a 3a` | `MSmartErrorDTO{type=[3], desc=[4], sta_index=[5]}`, then **ignored** (`V/robots/midea/MideaValetudoRobot.js:177`) | parse matches. Using it is redundant because the status carries the same values in [16]/[17] |
| 0x04 0x90 (event) | 1 byte: RobotEvent mapped through map @0xc61750 (default 0) (@0x80c2b0) | SKIP | ignored |
| 0x04 0xA8 (event) | `[3]=u8`, `[4..7]=u32`, `[8..11]=u32`, `[12]=u8`, `[13..16]=u32` (RobotWorkProcess +0,+4,+8,+0xc,+0x10; WorkProcessCallback @0x805940). Pollable with 0x03 0xA8 (GetWorkProcess) | SKIP. The comment in BEightParser.js:197-207 matches this layout | ignored |
| 0x04 0x20 (event) | Dock position: `[3..4]=x`, `[5..6]=y`, `[7]=valid` (ChargeDockOdo) (@0x804430) | SKIP ("map state?") | ignored, useful |
| 0x04 0x21 (event) | 1 byte = this+0x12a (same value as status [42] and the 0x03 0x25 reply) (@0x804690) | SKIP | ignored |
| 0x04 0x28 (event) | 1 byte = GetCleanSeqSwitch (room-order switch) (@0x8048c0) | not listed, "Unhandled EVENT" warning | ignored |
| 0x04 0x55 / 0x96 / 0xC1 / 0xAC | 1-byte payloads (u8 arg / int / bool / u8). Meaning not decoded | "Unhandled EVENT" warning | ignored |
| 0x06 0x66 0x06 (dock) | `[2]=GetCollectDustNum`, `[3]=0xFF`, `[4]=0xFF`, `[5]=IsFluidOK(1)`, `[6]=IsFluidOK(2)` (@0x809960) | `MSmartDockStatusDTO` count=[2], fluid1=[5], fluid2=[6], then not used | yes |
| 0x02 0x26 / 0x27 replies | Join reads `[4],[5]` (seg A,B). Split reads `[3..10]` (x1,y1,x2,y2 u16LE) and `[11]` (seg id). Reply `[3]=result` (UpToIotMsg0x02_0x26/27) (@0x807ac0/@0x807e70) | checks `payload[3]!==0` | yes (the join error text says "split") |
| 0x02 0x25 / 0x2D / 0x90 (unsolicited SETTING frames) | `0x25(u8,u8)`, `0x2D(u8)`, `0x90(u8)` pushed as type-2 frames | SETTING branch: not in its SKIP list → "Unhandled SETTING packet" | ignored |

## (b) Mismatches

| # | Area | Valetudo says/does | Firmware actually does | Impact | Evidence | Confidence |
|---|---|---|---|---|---|---|
| M1 | 0x03 0x30 active segments | `MideaJ15MaxUltraValetudoRobot.executeMapPoll` sends `aa 01 30` and awaits the reply | No `handle0x03_0x30` key. Type 3 is in the drop-set @0xc61780, so nothing is sent back | On this manager_node build every map poll would block until the dummycloud timeout. **The J15PU class doesn't send 0x30**, so there's no impact here. Matters only if the J15 Max Ultra runs the same build (unknown) | OnRecvIotFrame @0x810470 (lookup @0x81076c, set test @0x810960); key strings list; `V/robots/midea/MideaJ15MaxUltraValetudoRobot.js:128-140` | confirmed (firmware side) |
| M2 | Error 1-21 | "Sterilization module fault", PERMANENT/ERROR/ATTACHMENTS | `M_RADAR_UART_COM_ABNORMAL` (MCU code 21): LDS UART link failure | Wrong message and subsystem; should be SENSORS, probably CATASTROPHIC | ErrInfo table @file 0x6a73f8 (rec 21 → 01 15); `V/robots/midea/MideaValetudoRobot.js:656` | confirmed |
| M3 | Error 1-22 | "Water tank missing", TRANSIENT/WARNING | `MCUE_ARM_UART_COM_ABNORMAL`: SoC↔MCU UART failure | Wrong meaning; severity far too low (should be CORE, CATASTROPHIC) | same table rec 22; `MideaValetudoRobot.js:662` | confirmed |
| M4 | Error 1-23 | "Wipe chip error" | `MCUE_INTERIOR` (internal MCU error) | Wrong message | rec 23; `:668` | confirmed (name), meaning of "INTERIOR" likely |
| M5 | Error 1-24 | "LDS temperature out of operating range", SENSORS/ERROR | `MCUE_RELOCATION_FAIL`: relocalisation failed | Wrong; should be NAVIGATION/WARNING | rec 24; `:674` | confirmed |
| M6 | Error 1-20 | "Robot stuck or trapped" (VIBRATION_DRAG_ERR), NAVIGATION | `MCUE_VIBRATE_MOP`: vibrating-mop module fault | Wrong subsystem (ATTACHMENTS/MOTORS) | rec 20; `:650` | likely |
| M7 | Error 1-19 | "Charging station without power" | `MCUE_DOCK_FAIL` (docking/charging failed) | Message too specific | rec 19; `:644` | likely |
| M8 | Error 1-81 | "Robot trapped by virtual restrictions" | `PE_BUMPER_TRIGGER` (planner: bumper keeps triggering) | Wrong meaning | Planner table (PE_* → 01 51); `:734` | confirmed |
| M9 | Error 1-83 | "Wheel lost floor contact" | `PE_CLIFF_TRIGGER` (cliff sensor stop) | Slightly wrong (cliff, not wheel drop) | `→01 53`; `:746` | confirmed |
| M10 | Unknown robot codes | Not mapped → "Unknown error 1-n" | 1-25 BATTERY_LOW_NEED_DOCK, 1-26 DUST_FULLED, 1-27 WATER_BOX_EMPTY, 1-28 TURN_PLATE, 1-29 WATERBIN_ABSENT, 1-30 TURN_PLATE_CHIP, 1-86 PE_MCU_FAULT, 1-95 PE_ROOM_LAYER_ERROR, 1-165 IMU_I2C_ABNORMAL, 1-168 OBS_WHEEL_BACK, 1-169 OBS_WHEEL_OUT_OVERLOAD, 1-170 OBS_WHEEL_BACK_OVERLOAD, 1-171 BUMPER_SIDE_BRUSH_RIGHT, 1-172 CONTRACT_SIDE_BRUSH_RIGHT | Generic unknown errors for real J15PU faults (obstacle-crossing wheels, extendable side brush, IMU) | tables @file 0x6a73f8 / 0x6a77a8 | confirmed |
| M11 | Station code 100 | 3-100 "Dock communication error" | StationErrors 1 `CollectDust` → 100 | Any station_error_code>0 turns the robot status into ERROR (`MideaValetudoRobot.js:359-362`), so a dust-collect state could show as "Dock communication error" | map<StationErrors,u8> init @0x6f7474 (data @file 0x74d4b8), names @file 0x74d008; `:962` | likely (whether 100 is ever reported is unverified) |
| M12 | Station codes 103/104 | Wastewater "full or not installed" only on 152; 103/104 unknown | 103 = `DirtyWaterFull`, 104 = `NoneDirtyTank`, 152 = `DirtyTankErr` | Wastewater full/missing could show as "Unknown error 3-103/104", and the WATER_TANK_DIRTY component stays OK | same; `MideaValetudoRobot.js:244-251,1094` | likely (which code the J15 dock raises when full isn't proven) |
| M13 | Station 111 / 112 / 148 | 111 "Mop Dock Tray not installed", 112 "Tray full of water", 148 "Dock air motor error" | 111 `WashSlotFull` (wash tray full), 112 `RobotFull`, 148 `DuctSwitchErr` | Wrong messages | same; `:998,1004,1070` | likely |
| M14 | Station codes unknown | not mapped | 102 MotorNotAt, 108 HotNotEnough, 110 MotorUpErr, 113 BoxNotInstalled, 115 OpenChargeErr, 116 StartTimerErr, 118 AutoUpErr, 119 AutoDownErr, 120 NoneFliter, 130 DuctBlocked, 132 NoneWaterBox, 133 LackWater(2), 138 HeatWaterErr, 144 WashSlotFull(2), 145 DustNotInstall, 153 PlumbWaterTankErr | Generic unknown errors | same | confirmed (names) |
| M15 | Dustbag codes 11/12/13 | Treated as dustbag missing/full (`MideaValetudoRobot.js:256-266`) | Status [35] is forced to 0 unless 100..219 (@0x81794c) | Dead code on J15PU (harmless) | @0x817944-0x817964 | confirmed |
| M16 | A3 error event | Ignored (debug log only) | Pushed on every fault/station-error change, but no status push necessarily follows | Errors may only show at the next status push or poll (latency) | `MideaValetudoRobot.js:177-181`; RobotFaultCallback @0x8097c0 | likely |
| M17 | Error 1-43 | "Charging error" | Raised by `_handleMotionStatus` (FaultReport(1,0x2b) @0x99282c) inside a wash-sink (`IsWashSinkInstalled`) branch, with sound 200 | Message may be wrong | @0x992680-0x99282c; `:686` | speculative |
| M18 | Legacy MULTI on this firmware | E20 path sends `0x32/0x35` ACTIONs | Echoed back unchanged ("unsupport cmd") | Not on the J15PU path. On a misdetected model the echo would be parsed as a status | @0x810538 | confirmed |

## (c) Error code comparison (robot fault type-desc)

How the firmware produces these. MCU faults: `_ProcMcuFault(type, info, MCU::ErrorCode)` @0x97fe70 stores type/info at CC+0xa4c/0xa50. The per-code (type, desc) table is at file 0x6a73f8 (`{u64 code, u8 type, u8 desc, char* name}`). Planner faults go through FaultReport(1,desc). SLAM faults go through `SetFaultByFSM(1, desc)` (vtable+0x88 resolved through the thunk table @file 0x6b9860), so the table's leading `02` is not the IoT type. FSM messages: type 3→0x3d, 1→0x3e, 2→0x3f, matching WARNING / RECOVERABLE / FATAL. That agrees with Valetudo's 1=solvable, 2=restart, 3=warning.

| Code | Firmware name | Valetudo meaning | Match |
|---|---|---|---|
| 1-1 | MCUE_DUST_ABSENT | Dustbin missing | yes |
| 1-2 | MCUE_WHEEL_SUSPEND | Wheel lost floor contact | yes |
| 1-3 | MCUE_WHEEL_OVERLOAD | Wheel jammed | yes |
| 1-4 | MCUE_SIDE_BRUSH_OVERLOAD | Side brush jammed | yes |
| 1-5 | MCUE_BRUSH_OVERLOAD | Main brush jammed | yes |
| 1-6 | MCUE_SUCTION | Fan speed abnormal | yes |
| 1-7 | MCUE_BUMPER_FRONT | Stuck front bumper | yes |
| 1-8 | MCUE_BUMPER_RADAR_COVER | LDS jammed | approx (LDS cover bumper) |
| 1-9 | MCUE_CLIFF | Cliff sensor dirty… | yes |
| 1-10 | MCUE_BATTERY_TOO_LOW | Low battery | yes |
| 1-11 | MCUE_START_INLINDED (inclined) | Tilted robot | yes |
| 1-12 | MCUE_RADAR_SHELTERED | LDS jammed | approx (LDS blocked) |
| 1-13 | MCUE_WF_SENSOR_SHELTERED | Sensor dirty | yes |
| 1-14 | MCUE_START_FORBIDDED_ZONE | Trapped by virtual restrictions | approx (started in no-go zone) |
| 1-15 | M_STRT_STRONG_MAGNETIC | Magnetic interference | yes |
| 1-16 | MCUE_RADAR_STUCKED | LDS bumper jammed | yes |
| 1-17 | MCUE_MOP_ABSENT | Lost mop pad | yes |
| 1-18 | MCUE_SLIP_TRAPPED | Robot stuck or trapped | yes |
| 1-19 | MCUE_DOCK_FAIL | Charging station without power | approx (M7) |
| 1-20 | MCUE_VIBRATE_MOP | Robot stuck or trapped | **no** (M6) |
| 1-21 | M_RADAR_UART_COM_ABNORMAL | Sterilization module fault | **no** (M2) |
| 1-22 | MCUE_ARM_UART_COM_ABNORMAL | Water tank missing | **no** (M3) |
| 1-23 | MCUE_INTERIOR | Wipe chip error | **no** (M4) |
| 1-24 | MCUE_RELOCATION_FAIL | LDS temperature out of range | **no** (M5) |
| 1-25..1-30 | BATTERY_LOW_NEED_DOCK, DUST_FULLED, WATER_BOX_EMPTY, TURN_PLATE, WATERBIN_ABSENT, TURN_PLATE_CHIP | — | missing |
| 1-32 | MCUE_HAIR_CLIPPER_OVERLOAD | Hair cutter jammed | yes |
| 1-43 | (FaultReport in _handleMotionStatus, wash-sink branch) | Charging error | ? (M17) |
| 1-80 | PE_NO_PATH | Cannot reach target | yes |
| 1-81 | PE_BUMPER_TRIGGER | Trapped by virtual restrictions | **no** (M8) |
| 1-82 | PE_VIRTUAL_BUMPER_TRIGGER | Trapped by virtual restrictions | yes |
| 1-83 | PE_CLIFF_TRIGGER | Wheel lost floor contact | approx (M9) |
| 1-84 | PE_OUT_CHARGER_FAIL | Failed to exit dock | yes |
| 1-85 | PE_STUCKED | Robot stuck | yes |
| 1-86 | PE_MCU_FAULT | — | missing |
| 1-87 | PE_TIME_OUT | Operation timeout | yes |
| 1-88 | PE_START_ON_CARPET | Cannot start on carpet | yes |
| 1-89 | PE_START_ON_VIRTUAL_WALL | Stuck inside restricted area | yes |
| 1-90 | PE_START_FORBIDDEN_ZONE | Stuck inside restricted area | yes |
| 1-91 | PE_START_WATER_FORBIDDEN | Stuck inside restricted area | yes |
| 1-92 | PE_START_ON_CHARGER (also FaultReport(1,0x5c) in _handlePlannerFault @0x993c70) | Cannot start while charging | yes |
| 1-93, 1-96, 1-64..69, 1-128, 1-160 | not in this firmware's tables | mapped | unverifiable (other models or paths) |
| 1-94 | PE_SLAM_LAYER_ERROR | Navigation map error | yes |
| 1-95 | PE_ROOM_LAYER_ERROR | — | missing |
| 1-162 | MAP_CREATE_FAIL_BY_IMU (SLAM) | Map creation error | yes |
| 1-164 | SLAM_RELOC_FAIL_ON_SLOPE (SLAM) | Localization error | yes |
| 1-165, 1-168..172 | IMU_I2C_ABNORMAL, OBS_WHEEL_BACK, OBS_WHEEL_OUT_OVERLOAD, OBS_WHEEL_BACK_OVERLOAD, BUMPER_SIDE_BRUSH_RIGHT, CONTRACT_SIDE_BRUSH_RIGHT | — | missing |
| 2-x / 3-1..3-37 | Come from the MCU's own (type, info) bytes; can't be enumerated from manager_node | mapped | not verifiable statically |

Station error codes (status [35] and A3 [5]). Valetudo maps them as `mapErrorCode(3, code)`:

| Code | Firmware StationErrors name | Valetudo (3-x) | Match |
|---|---|---|---|
| 100 | CollectDust | Dock communication error | **no** (M11) |
| 101 | MachineNotAt | Robot not in dock | yes |
| 102 | MotorNotAt | — | missing |
| 103 | DirtyWaterFull | — | **missing** (M12) |
| 104 | NoneDirtyTank | — | **missing** (M12) |
| 105 | NoneWaterTank | Clean tank not installed | yes |
| 106 | LackWater | Clean tank empty | yes |
| 107 | CloseChargeErr | Dock close error | approx |
| 108 | HotNotEnough | — | missing |
| 109 | FanError | Dock fan error | yes |
| 110 | MotorUpErr | — | missing |
| 111 | WashSlotFull | Tray not installed | **no** |
| 112 | RobotFull | Tray full of water | approx |
| 113 | BoxNotInstalled | — | missing |
| 114 | MopNotInstalled | Lost mop pad | yes |
| 115/116 | OpenChargeErr / StartTimerErr | — | missing |
| 117 | AutoNotExit (auto-water module) | Dock water module not installed | yes |
| 118/119/120 | AutoUpErr / AutoDownErr / NoneFliter | — | missing |
| 121 | DustFull | Dust bag full | yes |
| 125 | CommunicateErr | Dock communication error | yes |
| 128 | DustBoxOpen | Dock cover not closed | yes |
| 129 | NoneDustBag | Dust bag missing | yes |
| 130 | DuctBlocked | — | missing |
| 131 | LackFluid | Cleaning liquid empty | yes |
| 132/133 | NoneWaterBox / LackWater(2) | — | missing |
| 134 | FlowInError | Water injection timeout | approx |
| 135 | LackFluid2 | Fortified liquid empty | yes |
| 136 | WaterStageErr | Water level sensor error | yes |
| 138 | HeatWaterErr | — | missing |
| 144/145 | WashSlotFull(2) / DustNotInstall | — | missing |
| 148 | DuctSwitchErr | Dock air motor error | **no** |
| 149 | SelfCleanUpErr | Dock motor raise error | yes |
| 150 | SelfCleanDownErr | Dock motor down error | yes |
| 151 | WaterNtcErr | Temperature sensor error | yes |
| 152 | DirtyTankErr | Wastewater full or not installed | approx (see 103/104) |
| 153 | PlumbWaterTankErr | — | missing |
| 204 | (unnamed, enum 36) | Dock communication error | ? |
| 255 | UnknownError | — (clamped to 0 in status) | n/a |

## (d) Unused firmware queries and events worth knowing

- **0x04 0x20**: dock position push (x, y, valid). Could replace polling 0x24 on every map poll.
- **0x03 0xA8 / 0x04 0xA8**: dock work process (mode + 3 u32 timers). This is the data the BEightParser comment guesses at; usable for dock-status progress.
- **0x04 0x90**: robot-event code byte (RobotEvent → IoT map @0xc61750). Log shows RobotEvent 162/173 around task start.
- **0x04 0x95**: mop-dock settings changed (same 5 bytes as 0x93). Could keep quirks fresh without polling.
- **0x04 0x28 / 0x03 0x2A**: room clean-sequence switch (relevant to the room-order work).
- **0x03 0x28**: room list (`CCentralController::GetRooms`).
- **0x03 0x02**: clean plans/schedules (`GetCleanPlans`).
- **0x03 0x59**: capability bits (IsWSSupportEleWater, IsSupportCarpetBoost, GetSuctionConfigType, IsSupportSelfCleanFreq, IsSupportMopAutoDry, GetStationCapability, IsSupportDialect). Confirms Valetudo's "feature bits" comment.
- **0x03 0x64**: stain-recognition method / zigzag-to-end.
- **0x03 0x97**: target reminder.
- **0x03 0xA6**: rotate interval.
- **0x03 0xA9**: reporting switch.
- **0x03 0xA5**: a GlobalConfig slice.
- **A3 `[6]`/`[7]`**: transaction id and StationInfo+0x12. Neither is parsed by Valetudo.
- **Firmware limits**: 0x02 0x05 silently drops zones with any coordinate ≥ 801 (0x321), with no error reply. The request reads passes from the 10th byte; the reply puts passes second.

## (e) Open questions / not covered

- The value tables of the small std::maps (dry mode @0xc61658, carpet @0xc61718, route kRouteTypeEncoder/Decoder @0xc65140/0xc65170, 0xC9 subtype @0xc61810, RobotEvent @0xc61750) were not decoded. Valetudo's get and set use the same IoT space, so round-trips are consistent, but the enum meanings (e.g. carpet 0..3, dry 5/6/7) aren't proven statically.
- 0x03 0x20: whether bitmask bit i is map id i or i+1. Not traced (writer of CMapHandler+0x1d6200 not found).
- 0x03 0x24: dock angle units and sign.
- Whether StationStatus+8 (status [35]) always equals the map<StationErrors,u8> encoding. Likely, but the encoder call site wasn't traced.
- Meaning of this+0x12a (status [42], event 0x21, reply 0x03 0x25), and of the 0xAA `[8]`/`[10]` names.
- Type-2 and type-3 robot error descs come from the MCU firmware; not enumerable from manager_node.
- Handlers 0x03 0x03/0x21/0x23/0x25/0x26/0x29/0x50-0x56/0x58/0x63/0x91/0x92 were not decoded.
- Live logs contain only 0x22/0x24/0x27 queries and 0x01/0xA3/0xA8 events, so the layouts above are mostly static-only.
