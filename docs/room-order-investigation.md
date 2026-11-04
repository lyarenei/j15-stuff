# Investigation: cleaning rooms in the selected order

**Status:** cause found, fix designed but not yet built or tested.
Started 2026-11-04.

## Symptom

In Valetudo, selecting several rooms in a particular order and starting a
segment clean doesn't clean them in that order. The order looks random.

## Summary

- Valetudo sends the rooms in the order they were selected.
- `manager_node` throws that order away. It uses the request only to know
  *which* rooms to clean, then orders them itself: rooms with a stored
  per-room **`cleanSeq`** first (sorted by it), the rest by the firmware's
  own proximity ranking.
- `planner_node` then cleans in exactly the order `manager_node` gives it.
- So the order isn't random, it's the firmware's ranking. A one-instruction
  patch in `manager_node` should make it keep the request order (see
  [The fix](#the-fix)).

Everything below is static analysis of the binaries listed in
[research-workflow.md](research-workflow.md#binaries-examined). No room
clean with a custom selection has been logged yet (see
[Verification](#verification)).

## Valetudo side

`backend/lib/robots/midea/capabilities/MideaMapSegmentationCapabilityV1.js`
and `V2.js` (Valetudo `master`, read 2026-11-04):

- `executeSegmentAction(segments, options)` writes the segment IDs into the
  payload **in the order given**. The frontend
  (`frontend/src/map/actions/live_map_actions/SegmentActions.tsx`) passes
  them in selection order.
- V2 (used by the J15) sends `SETTING.START_SEGMENT_CLEANUP` (`0x03`) with a
  fixed 10-slot payload: 1-byte count, then 10 bytes per room
  (`id, iterations, operationMode, ?, fanSpeed, waterGrade, 4 × ?`).
- Both versions report `customOrderSupport: false`, and `options.customOrder`
  is ignored. The UI therefore doesn't offer custom order, but the order is
  still sent.

## Firmware side

### `manager_node`: `CMapHandler::SequenceRoomItem` (`0x87d790`)

Signature: `SequenceRoomItem(RoomsCleanParam &out, bool whole_house,
const std::vector<CAreaCleanItem> &selected)`.

1. Calls `GetRoomsCleanParam` (`0x878610`), which runs the firmware's room
   ranking (`ZoneSegmentation::SetInputRankZone` / `ProcessZoneRank` /
   `GetZoneRank`). It ranks from the dock (`RoomRank method - dock`) or the
   robot's position (`RoomRank method - robot pose`).
2. For a room selection (`whole_house == false`) it walks `selected` in
   request order, looks up each room's `CRoomItem` (`0x98` bytes) and puts
   it in one of two lists:
   - `cleanSeq != 0` → "seg" list
   - `cleanSeq == 0` → "nor" list

   The check is `ldr w0, [x1, #0x70]; cbz w0, 0x87d9d4` at **`0x87d8e4`**.
3. Sorts the "seg" list by `cleanSeq` (a bubble sort that swaps only when
   strictly greater, so equal values keep their order).
4. Rebuilds the "nor" list in **ranking order**, using only the rooms that
   were selected.
5. Writes "seg" rooms then "nor" rooms into `out` (29-byte
   `OneRoomCleanParam` entries, count at `+0x9`, entries from `+0xd`), and
   logs each one as `[seg]: room_id:N` or `[nor]: room_id:N`.
6. If the "customized clean" flag (`CMapHandler+0x1d64a6`, set by
   `SetCustomizedClean`) is on, it also moves rooms with
   `vacuum_mop_mode == 1` to the front and logs
   `[customize_sorted_room]: ...`. Not investigated further.

Normally no room has a `cleanSeq`, so every selected room lands in "nor" and
the order comes entirely from the ranking. That's the "random" order.

### `cleanSeq`

- `CRoomItem+0x70`, serialized as `"cleanSeq"` by `CRoomItem::ToJson`
  (`0x896dc0`) and saved with the room map. Other keys in the same object:
  `id`, `name`, `range`, `neighbors`, `iotNeighbors`, `fanSpeed`,
  `infinite_water_speed`, `fluidType`, `cleanCount`, `roomType`, `isEdited`,
  `groundMaterialType`, `groundMaterialIsEdited`, `is_zone_changed`,
  `vacuum_mop_mode`, `route_type`.
- Written by `CMapHandler::SetRoomInfo(Manager::RoomInfo)` (`0x871fe0`,
  `str w13, [x12, #0x70]`, then `CRoomMap::Save`). Its only caller is
  `CCentralController::SetRoomInfo` (`0x7789d0`). This is probably what the
  Midea app's "cleaning sequence" setting uses. A JSON entry point,
  `ThingsModel::CommandRoomInfo`, also exists.
- Which MSmart packet reaches `SetRoomInfo` is **not known**. Valetudo
  doesn't send one: its segment names live only on the Valetudo side
  (`MideaMapHacksProvider`). Probably SETTING `0x2B`
  (`handleIotMsg0x02_0x2B` → `CCentralController::SetRoomInfo`; fan at
  byte +4, water +5, route +7 per room). Which byte is `cleanSeq` isn't
  decoded yet, see [valetudo-comparison.md](valetudo-comparison.md).
- The 0x03 handler reads only room id and count per slot, plus the first
  room's mode byte; Valetudo's per-room fan and water bytes are ignored
  ([features.md](valetudo-comparison/features.md), M3).

### `planner_node` keeps the order it receives

- `PlannerCore::StartRoomsClean` → `RoomsCleanTask`. For a room selection
  on an existing map, `RoomsCleanTask::_procRoomLayer` (`0x6d1460`) calls
  `ZoneInfo2RoomInfo` (`0x6d0a70`).
- `ZoneInfo2RoomInfo` walks the request's room list and gives each room
  `clean_order` = its index. It logs
  `room_id=%d clean_order=%d clean_count=%d vacuum_mop_mode=%d route_type=%d`.
- `_getRoomCleanOrder` (`0x6de770`) just returns the IDs in list order;
  `_removeExtraRoomInfo` uses it only as a filter.
- The planner re-ranks only in `_procSlamLayer` (`0x6d3ea0`, reached from
  `RoomsCleanFSM::ExploreState`, the explore-then-clean path). It overwrites
  the list with `GetZoneRank`'s result and logs `clean order is` /
  `room_id=N`.

Entry layout of a room in `RoomsCleanParam` (29 bytes), as far as known:

| Offset | Type | Field |
|---|---|---|
| `+0x00` | i32 | room ID |
| `+0x04` | i32 | clean count |
| `+0x08..0x17` | 4 × i32 | room rectangle (minx, miny, maxx, maxy; order not checked) |
| `+0x18` | u8 | `vacuum_mop_mode` |
| `+0x19` | i32 | `route_type` |

## Options considered

1. **Valetudo change.** Before each segment clean, set `cleanSeq` = 1…N on
   the selected rooms (0 on the others) through the cloud protocol, then
   start the clean and turn on `customOrderSupport`. This needs the unknown
   `SetRoomInfo` packet, and it means maintaining a Valetudo fork, because
   upstream is unlikely to take external contributions. **Rejected.**
2. **Patch `manager_node`** so a room selection keeps the request order.
   It doesn't depend on Valetudo, and it has to be re-applied after firmware
   updates, which are rare. **Chosen.**

## The fix

Replace the `cbz w0, 0x87d9d4` at `0x87d8e8` with a `nop`. Every selected
room then goes into the "seg" list in request order. With every
`cleanSeq == 0`, the bubble sort never swaps, so the request order survives.
The "nor" list stays empty and the ranking isn't used.

| | |
|---|---|
| Binary | `/usr/navi/manager_node`, sha256 `049e9d56d2c0dee98209871deb74fa31006b3bcd730e8b8abaf2d072215b50da` |
| Address | `0x87d8e8` (file offset `0x47d8e8`) |
| Original | `60 07 00 34` (`cbz w0, 0x87d9d4`) |
| Patched | `1f 20 03 d5` (`nop`) |

- Only the room-selection branch changes. Whole-house cleans take the
  `whole_house == true` branch (`0x87d924`) and aren't affected.
- **Caveat:** if some rooms already have a non-zero `cleanSeq` (for example
  set by the Midea app before rooting), the bubble sort would still move
  them relative to each other. Check the saved room map for non-zero
  `cleanSeq` values first.
- Valetudo still reports `customOrderSupport: false`, so its UI doesn't
  show order numbers. The order of selection is still what gets sent.

### Packaging (planned)

- A separate component, independent of `camstream`, so users can install
  either one.
- Don't ship the vendor binary. Patch the robot's own copy on the robot:
  check the sha256 and the 4 original bytes, write the patched copy to
  `/userdata`, and refuse to patch if either doesn't match (another
  firmware version).
- Apply it with a bind mount over `/usr/navi/manager_node` (approach 4 in
  [modifying-firmware.md](modifying-firmware.md)). The boot hook runs
  *after* `start-dushu` has already started the nodes, so `manager_node` has
  to be restarted after mounting. Before doing that, find out how
  `/usr/bin/track` reacts to a node being restarted.
- Uninstall removes the mount and the patched copy. A reboot without the
  hook restores the original.

## Verification

Not done yet. The saved logs contain only one whole-house clean
(`PlannerCore::StartRoomsClean ... is_whole_rooms_clean=1
is_customized_clean=0`).

1. **Before patching:** select rooms out of their natural order and start a
   segment clean, then check:
   - `manager` log: `[nor]: room_id:` lines (and `[ROOM SORT]`) in ranking
     order, not selection order.
   - `planner` log: `ZoneInfo2RoomInfo - room_id=%d clean_order=%d ...` in
     the same order.
2. **After patching:** the same selection should log `[seg]: room_id:` in
   selection order, and the planner's `clean_order` should match.
3. Check that a whole-house clean behaves as before.

## Where things are

| What | Where |
|---|---|
| Manager logs | `/userdata/logs/app/manager/manager.*.log[.gz]` (RAM, lost at reboot) |
| Planner logs | `/userdata/logs/app/planner/planner.*.log[.gz]` |
| Relevant classes | `manager_node`: `CMapHandler::SequenceRoomItem`, `CMapHandler::GetRoomsCleanParam`, `CMapHandler::SetRoomInfo`, `CRoomItem`, `CRoomMap::SortRooms`; `planner_node`: `RoomsCleanTask::{_procRoomLayer, _procSlamLayer, ZoneInfo2RoomInfo, _getRoomCleanOrder}` |
| IPC topic manager → planner | `planner-request-start-rooms-clean` |
| Valetudo code | `backend/lib/robots/midea/capabilities/MideaMapSegmentationCapabilityV2.js` |
