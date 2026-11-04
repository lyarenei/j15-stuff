# Per-room info: SETTING 0x2B, ACTION 0x28/0x2A, customized clean

Static analysis of `manager_node` (sha256 `049e9d56…50da`), using Ghidra (REA) and objdump. All addresses are in `manager_node`. "Frame offset" means the absolute byte index in the MSmart frame: a 10-byte header, then `[10]=0xaa`, `[11]=version`, `[12]=cmd`, then the payload from `[13]`. Valetudo's `buildPayload(cmd, p)` puts `p[0]` at frame offset 13.

## 1. SETTING 0x02 0x2B: `handleIotMsg0x02_0x2B` (`0x80ef60`)

### Header (confirmed)
- `[11]` is the format version. The handler accepts only `1` or `2`; Valetudo always sends `0x01` today.
- `[13]` is never read.
- `[14]` is the room count N.
- Count `N == 0` resets every room in the map (read through `GetRoomInfo`) to these defaults: cleanSeq 0, fan `GetDefaultFanSpeed()`, water 2, cleanCount 1, fluid 0, vmm 0, route 1 (`0x80f000…`, `local_45=0x102`). The reset happens whatever version byte is sent.
- `N > 0` with a version other than 1 or 2 builds an empty list. `SetRoomInfo` still runs and saves, and no reply is sent.

### v1 layout (`[11]=1`): 10-byte entries from frame offset 15
| Entry byte | Meaning | Decoding |
|---|---|---|
| +0 | room id | raw |
| +1 | cleanCount | raw, not validated |
| +2, +3 | unused | |
| +4 | fan | `MotorSpeedDecoder`; out of range → `GetDefaultFanSpeed()` plus an error log (`0x80f288`) |
| +5 | water | `WaterSpeedDecoder`; out of range → 2 |
| +6 | **cleanSeq** | raw, not validated |
| +7 | route | `kRouteTypeDecoder` (IoT 0→2 fast, 1→1, 2→3); out of range → 1 |
| +8, +9 | unused | |

**Bug (confirmed, `0x80f3e4`/`0x80f3ec`):** the v1 path never writes the stack bytes for fluidType (`sp+0xbd`) or vacuum_mop_mode (`sp+0xbe`), so whatever happens to be on the stack gets stored. `SetRoomInfo` stores vmm raw, while fluid goes through a decoder and falls back to 0. **Don't use v1.**

### v2 layout (`[11]=2`): `[15]` = entry stride S, entries from frame offset 16, N entries
| Entry byte | Meaning | Decoding |
|---|---|---|
| +0 | room id | raw |
| +1 | cleanCount | raw |
| +2 | vacuum_mop_mode | `VacuumMopModeDeEncoder` = identity {0,1,2} (init `0x5d9b9c`). On a miss the byte is **not written**: stale or uninitialised stack data |
| +3 | unused | |
| +4 | fan | `MotorSpeedDecoder` (0→0, 4→1, 1→2, 2→3, 3→4, 5→5); miss → default fan |
| +5 | water | `WaterSpeedDecoder` (identity 0..3, 100..130); miss → 105 if `ManagerRuntime+0x129` (infinite water; set on J15PU) else 2 |
| +6 | **cleanSeq** | raw |
| +7 | fluidType | raw here; `SetRoomInfo` maps it through `ctrl::WSFluidTypeDecoder` = identity {0,1,2} (table `0xabb5f8`), miss → 0 |
| +8 | route | `kRouteTypeDecoder`; miss → 1 |

The stride is taken from the frame, so S must be at least 9 (10 is fine). Always send a valid vmm (0..2) (confirmed).

### Reply and validation (confirmed)
- The reply is always result 0: v1 sends `RespIotCmd(2,0x2b,0)` = `[aa 01 2b 00]`, v2 sends `RespIotCmd_v2` = `[aa 02 2b 00]` (`0x824ff0`, writes `[11]=2`).
- There is no state gate (it's accepted during a clean too) and no check on the room id.
- No status push.

### Per-entry struct `Manager::RoomItem` (0x40 bytes) → `CRoomItem` (0x98), in `CMapHandler::SetRoomInfo` `0x871fe0` (confirmed)
| RoomItem | Field | CRoomItem | JSON key (`CRoomItem::ToJson` `0x896dc0`) |
|---|---|---|---|
| +0 u8 | id | match on +0x00 | `id` |
| +1 u8 | cleanSeq | +0x70 i32 | `cleanSeq` |
| +2 u8 | fan (internal) | +0x74 u8 | `fanSpeed` |
| +3 u8 | water | +0x76 u8 | `infinite_water_speed` |
| +4 u8 | cleanCount | +0x7c i32 | `cleanCount` |
| +5 u8 | fluid (raw) → WSFluidTypeDecoder | +0x78 i32 | `fluidType` |
| +6 u8 | vacuum_mop_mode | +0x75 u8 | `vacuum_mop_mode` |
| +8 string, +0x28..+0x34 | name, 4 × i32 (zeroed) | not used | |
| +0x38 i32 | route (internal) | +0x90 i32 | `route_type` |

- **Only the listed rooms are updated, and every field of each listed room is overwritten.** Updating one field therefore needs a read-modify-write through 0x03 0x28.
- Unknown room ids are silently ignored.
- The name can't be changed this way.

### Side effects (confirmed)
- Takes the mutex at `+0x1d6238`.
- Calls `CRoomMap::Save(1,0)`, plus `Save(n,0)` if `+0x1d61fc > 1`. This persists to flash.
- Then `CCentralController::SetRoomInfo` (`0x7789d0`) calls `_handle_customized_clean_param(this+0xb68, force=1)` (`0x9929b0`). That re-applies the current room's parameters only if `+0xb68` (the current room under customized clean) is non-zero. Outside mode 6, `+0xb68` is kept at 0 (see §4), so the call is a no-op.

## 2. ACTION 0x03 0x28 reply: `handleIotMsg0x03_0x28` (`0x80ac50`), list of all rooms from `GetRooms()`

**Header (confirmed):**
- `[11]` = `1 + (ManagerRuntime+0x12a != 0)`. On the J15PU, robot type 0x1a sets bytes `+0x123…+0x12a` to 1 (`0x7dfea4`), so the J15PU replies **v2**.
- `[13]` = room count, `[14]` = 0.

**v2:** `[15]` = 9 (the stride), entries from `[16]`, 9 bytes each.

| Byte | Field | Encoding |
|---|---|---|
| +0 | id | raw |
| +1 | cleanCount | raw, from +0x7c |
| +2 | fan | `MotorSpeedEncoder`; miss → 3 |
| +3 | water | `InfiniteWaterSpeedEncoder` if `+0x129` (0→100, 1→105, 2→120, 3→130, 100..130 identity; miss → 0x78), else `WaterSpeedEncoder` (miss → 2) |
| +4 | **cleanSeq** | +0x70, low byte |
| +5 | fluidType | `WSFluidTypeEncoder`; miss → 0 |
| +6 | not written | 0 |
| +7 | vacuum_mop_mode | `VacuumMopModeEncoder`; miss → 0 |
| +8 | route | `kRouteTypeEncoder`; miss → 1 |

**v1** (not used on the J15PU): entries from `[15]`, 5 bytes each: id, cleanCount, fan, water, cleanSeq.

**The read and write layouts differ (confirmed).** The reply has vmm at +7 and fluid at +5. The SET has vmm at +2, fan at +4, water at +5, cleanSeq at +6, fluid at +7 and route at +8. Copy the values field by field, not as raw bytes.

The encoders should be the inverses of the decoders, so the IoT values should round-trip. Only the water encoder table was checked (likely).

## 3. The clean-sequence "switch"

- **There is no stored switch (confirmed).** `CMapHandler::GetCleanSeqSwitch` (`0x86da90`) returns true when **any room has cleanSeq != 0**. `CCentralController::GetCleanSeqSwitch` (`0x778190`) only forwards to it.
- ACTION 0x03 0x2A (`0x801ee0`) replies `[aa 01 2a sw]`.
- Event 0x04 0x28 (`0x8048c0`) sends the same 1 byte. No direct `bl` callers were found, so it's probably called through a pointer (not traced).
- Status byte 43 is the same value (`0x8165d8`, `0x817a18`).
- **The switch has no setter.** It's on when any cleanSeq is non-zero and off when all are 0. The app presumably turns it off with 0x2B (all cleanSeq 0, or count 0, which also resets every other setting). App behaviour is speculative.
- **cleanSeq ordering doesn't depend on the switch or on customized mode (confirmed).**
  - `StartRoomClean` (`0x785fc0`) always calls `SequenceRoomItem(out, false, req)`.
  - Whole-house `CCleanCtrl::PlannerStartRoomsClean` (`0x8ee75c`) calls it with `true`, so **cleanSeq also reorders later whole-house cleans**.
  - `UpdateFirstRoomFluidType` (`0x908a6c`) is the only place that checks the switch.
- **Customized clean = sweep mode 6 (confirmed).**
  - `CCentralController::SetSweepMode` (`0x784540`): mode 6 → `SetCustomizedClean(1)`, `_handle_customized_clean_param(...,1)`, `SetStationFluidCleanMode(1)`. Any other mode → `SetCustomizedClean(0)` and `_ExitCustomizedClean`. It also persists through `SetAndSaveGlobalConfig`, and `_LoadSettings` restores it (`0x793bdc`).
  - The SETTING that turns it on is **0x58 (operation mode) with value 6**. `settings-commands.md` already notes that 6 is accepted; its earlier description of 6 as "single step, mop on" is really "customized per-room".
  - Valetudo would show mode 6 as an unknown operation mode.

## 4. How per-room settings apply during a room clean (SETTING 0x03 → StartRoomClean → SequenceRoomItem `0x87d790`)

**Order** (confirmed): selected rooms with cleanSeq != 0 come first, sorted ascending by a stable bubble sort (`0x87da…`). The other selected rooms follow in firmware ranking order.

**cleanCount** (confirmed): for every selected room, the CRoomItem copy's +0x7c is overwritten with the request's per-slot count (`*(item-0x1c)=uStack_464`), so **the 0x03 count wins**. The stored cleanCount is used only for whole-house cleans in customized mode. A non-customized whole-house clean uses 1.

**vacuum_mop_mode:** for room selections, the stored +0x75 is copied into `OneRoomCleanParam+0x18` even outside customized mode (the else branch at `0x87dcd0`). Whether the planner acts on it outside mode 6 isn't known (speculative). The planner does have `RoomsCleanTask::_getVacuumMopMode(room)`.

**route_type** (confirmed): copied from +0x90 only when customized (`0x87e340`). Otherwise the field is left at the caller's memset value 0.

**Customized (+0x1d64a6) extras:**
- Rooms with vmm == 1 are stable-partitioned to the front ("customized clean need sweep first", log `[customize_sorted_room]`). So 1 is probably vacuum-only (likely); 0 = vacuum+mop and 2 = mop-only are speculative.
- **This breaks a strict user order in mode 6.**

**fluidType:** `StartRoomClean` always calls `SetFirstRoomFluidType(stored fluidType of the first room)` (`0x786258`), whatever the mode (confirmed).

**Fan, water and fluid at runtime:**
- `PlannerStatusCallback` (`0x996454`): if sweep mode == 6, it calls `_handle_customized_clean_param(status.room_id, 0)` on every status. On a room change that applies:
  - suction `set_suction_room_setting(kMotorSpeedToDMotorSpeedMap[fan])` plus suction control mode
  - `SwitchVacuumMopMode(vmm)`
  - `CCSetWaterBumpSpeed(water)`
  - `SetNeedGobackWashMop(fluid)`
  - `SetRouteType(route)`
- Otherwise the callback clears `+0xb68` (`0x996478`).
- So **stored per-room fan, water and route are honoured only in mode 6**, and there they override the global values while the robot is in each room (confirmed for the code path; likely as observed behaviour).
- Outside mode 6, the global fan and water apply and the stored values are ignored (confirmed), except vmm (unknown, see above) and the first room's fluid type.

## 5. Ordered segment clean without the manager_node patch

Sequence (likely to work; not tested on the robot):
1. Send ACTION `0x03 0x28` and parse the v2 reply (§2) to get every room's current settings.
2. Send SETTING `0x2B` as v2. The payload is `[aa 02 2b 00 N 0a]` followed by N 10-byte entries. Use a custom header, because `buildPayload` hard-codes `0x01`.
   - For each selected room i (0-based) write cleanSeq = i+1.
   - For every other room whose current cleanSeq != 0, write cleanSeq = 0.
   - Write all the other fields back unchanged, re-ordered into the SET layout (vmm +2, fan +4, water +5, fluid +7, route +8, count +1).
   - Expect the reply `[aa 02 2b 00]`.
3. Send SETTING `0x03` as today. Every selected room lands in "seg" and is sorted by cleanSeq, which is the selection order; the ranking isn't used. The firmware logs `[seg]: room_id:N` in order.
4. Don't switch to mode 6. Mode 6 brings in per-room fan and water and the vmm==1-first reordering.
5. Restore: send the 0x2B again with the original cleanSeq values (normally all 0).
   - The order is copied into the task when `StartRoomClean` runs, so restoring right after the 0x03 reply should be safe. Resume after recharge or mop wash wasn't traced (speculative), so restoring when the clean finishes is the safer choice.

Costs and caveats:
- Each 0x2B costs two flash writes (`CRoomMap::Save`): one before the clean and one after.
- While any cleanSeq != 0, status byte 43 / event 0x28 report the "switch" as on, and **whole-house cleans also put those rooms first**. A missed restore (crash, reboot) leaves that order in place until the values are cleared.
- Sending count 0 to clean up also resets every per-room fan, water, route, count, fluid and vmm to the defaults.
- The Midea app isn't in use (Valetudo replaces the cloud), so there are no app conflicts.
- Per-room settings UI (part (b) of the goal): read with 0x28 and write with 0x2B v2. They only take effect in operation mode 6 (0x58 = 6), and mode 6 brings the vmm==1-first reordering and the per-room route.
