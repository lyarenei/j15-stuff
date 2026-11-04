# Investigation: cleaning rooms in the selected order

**Status:** cause found. Two fixes are packaged: the `roomorder` firmware
patch (`./install.sh roomorder-install`) and a `cleanSeq` write in the
patched Valetudo. Both are implemented, **untested on the robot**.
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
- So the order isn't random, it's the firmware's ranking. Two ways around it
  (see [Options](#options)): a one-instruction patch in `manager_node`, or
  setting `cleanSeq` on the selected rooms before the clean.

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
- The packet that reaches `SetRoomInfo` is **SETTING `0x2B`**
  (`handleIotMsg0x02_0x2B` `0x80ef60`). In the v2 layout (`[11]=2`) `cleanSeq`
  is entry byte +6. v1 has it at +6 too but leaves some fields as stack
  garbage, so use v2. The read side is ACTION `0x03 0x28` (`cleanSeq` at
  byte +4 of each 9-byte entry). Full layouts in
  [valetudo-comparison/room-info.md](valetudo-comparison/room-info.md).
  Valetudo sends none of this for ordering: its segment names live only on
  the Valetudo side (`MideaMapHacksProvider`).
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

## Options

Both give the selection order. They can be installed together.

### 1. `roomorder`: patch `manager_node` (firmware side)

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
| Patched file sha256 | `c91f58059e761194c8196bde2bd82dc348a9935427f241ff773b3fac6e477620` |

- Only the room-selection branch changes. Whole-house cleans take the
  `whole_house == true` branch (`0x87d924`) and aren't affected.
- **Caveat:** if some rooms already have a non-zero `cleanSeq` (for example
  set by the Midea app before rooting), the bubble sort would still move
  them relative to each other. Check the saved room map for non-zero
  `cleanSeq` values first.
- Needs no Valetudo change. Valetudo still reports `customOrderSupport:
  false`, so its UI doesn't show order numbers; the selection order is what
  gets sent.
- Must be re-created after a firmware update (the installer refuses other
  versions).

### 2. Valetudo writes `cleanSeq` around a segment clean (protocol side)

Implemented in the patched Valetudo ([valetudo-patches.md](valetudo-patches.md)),
following [room-info.md §5](valetudo-comparison/room-info.md#5-ordered-segment-clean-without-the-manager_node-patch):

1. Read all rooms (ACTION `0x03 0x28`).
2. Send SETTING `0x2B` v2 with `cleanSeq` = 1...N on the selected rooms and 0
   on the others, everything else written back unchanged.
3. Start the segment clean (SETTING `0x03`) as before.
4. After the clean, send `0x2B` again with the original `cleanSeq` values.

When the `roomorder` mount is active (`/usr/navi/manager_node` is a mount
target in `/proc/mounts`), the patched Valetudo skips this and relies on the
firmware patch.

### Trade-offs

| | `roomorder` patch | Valetudo writes `cleanSeq` |
|---|---|---|
| Touches | the robot's firmware path (bind mount, whole stack restarts once per install, uninstall and boot) | nothing on the robot |
| Flash writes | none per clean | each `0x2B` runs `CRoomMap::Save`, so two writes per clean |
| Whole-house cleans | unchanged | **reordered while `cleanSeq` is set** (`PlannerStartRoomsClean` also calls `SequenceRoomItem`); a failed or skipped restore leaves it set |
| Mode 6 (customized clean) | order kept, but rooms with `vacuum_mop_mode == 1` are still moved first | the same, and per-room fan, water and route then apply |
| Other `0x2B` side effects | none | writes every field of each listed room back, so a wrong read-modify-write corrupts per-room settings |
| After a firmware update | has to be re-created (it refuses and logs) | still works if the layout didn't change |

Mode 6 ("customized clean", SETTING `0x58` with value 6) applies the stored
per-room fan, water and route and moves rooms with `vacuum_mop_mode == 1`
(probably vacuum-only) to the front, so a strict user order isn't possible
there with either mechanism. Details in
[room-info.md §4](valetudo-comparison/room-info.md).

An earlier version of this doc rejected the Valetudo approach because the
`SetRoomInfo` packet was unknown. It is known now (SETTING `0x2B`), and the
Valetudo patch series is maintained here anyway, so both are kept.

## Packaging (`roomorder`)

A separate component, independent of `camstream` and `persistlog`. Install
with `./install.sh roomorder-install <ip>`; `roomorder-status` and
`roomorder-uninstall` are the other two actions.

Files: `/userdata/roomorder/roomorder.sh` (from `robot/roomorder.sh`),
`/userdata/roomorder/manager_node` (patched copy), one marked line
(`# j15-roomorder`) in `/oem/_root_postboot.sh`, log in `/tmp/roomorder.log`.
The vendor binary is **not** shipped; the patched copy is made on the robot.

Install:
1. Preflight: aarch64, `/usr/navi/manager_node` and `/usr/bin/track` exist,
   vendor debug mode (`/oem/midea_autorun`) is off.
2. `roomorder.sh prepare` on the robot: refuse unless the sha256 of
   `/usr/navi/manager_node` is exactly the one above, the 4 bytes at file
   offset `0x47d8e8` are `60 07 00 34`, and at least 20 MB are free. Then
   `cp`, write the 4 bytes with
   `printf '\037\040\003\325' | dd bs=1 seek=$((0x47d8e8)) conv=notrunc`,
   check the bytes and the patched sha256, and `mv` into place.
3. Add the boot line.
4. `roomorder.sh apply`: `mount --bind`, check the mounted file's sha256,
   restart `manager_node` (below). If the restart fails, unmount again.

At every boot the same `apply` runs: it re-checks the stock sha256 (firmware
updated: skip and log), re-checks the patched copy's sha256, mounts if not
mounted, and restarts `manager_node` only if the running process isn't
already using the patched binary (`sha256sum /proc/PID/exe`). It waits until
the system has been up 90 s so the stack finished booting.

Uninstall: remove the boot line, `umount -l` (lazy, because a running
`manager_node` keeps the mount busy), restart `manager_node` so the stock
binary runs, delete `/userdata/roomorder`.

`/usr/navi/manager_node` is a mount target in `/proc/mounts` exactly while
the patch is active; the patched Valetudo uses that to detect it.

Checked locally only: the `dd` / `printf` write on the dump gives the
expected sha256 above. busybox 1.27.2 on the robot has `dd` (with `notrunc`),
`od`, `sha256sum`, `pidof`, `killall`, `mount` and `umount`; not run there yet.

### Restarting `manager_node`

Found by static analysis of `/usr/bin/track` (objdump), `start-dushu`, `stop`
and `S98_lunch_init`. **Not tested on the robot.**

- `S98_lunch_init` `normal_mode` starts `/usr/bin/track &` and then
  `/usr/navi/start-dushu` from `cd /usr/navi/`. `start-dushu` runs each node
  directly (`./manager_node config.ini common-V15Overseas.json manager.json`,
  `LD_LIBRARY_PATH=../lib`); the nodes detach themselves. There is no
  per-node supervisor script.
- `track` loops once per second (`sleep(1)` at `0x4015ac`). Each round it
  calls a pid-file check (`0x403220`) and a heartbeat check (`0x402f40`).
- The pid-file check walks a table of 15 entries in `.data` (stride `0x188`:
  pid file path at +0, restart command at +0x80, cached pid at +0x180):
  `iot`, `midea`, `slam_navi`, `manager`, `data`, `slam`, `planner`,
  `voice`, `media`, `detect`, `semantic`, `camera_node`, `rkaiq_3A_server`,
  `audio_node`, `video_node` (`.pid` files in `/var/run`). `manager_node`
  itself writes `/var/run/manager.pid` (the path is in its strings).
- For an existing pid file whose pid is dead (`kill(pid, 0)` fails), `track`
  logs `%s exit, exec %s to restart it.`, **removes the pid file** and runs
  the entry's command with `system()`, then waits up to 10 s for the pid file
  to reappear.
- The command for **`manager`, `data`, `slam` and `planner` is
  `cd /usr/navi && ./stop* ; ./start*`**. So the death of `manager_node` (or
  of any of the other three) makes `track` run `stop` (`killall -9` on every
  node, `ubusd`, `audio_node`, `video_node`, `midea_watchdog`) and then
  `start-dushu` again. **`manager_node` can't be restarted alone through
  `track`; the whole navigation stack restarts.** (`./start*` expands to
  `start-dushu start-dushu-fact`; `start-dushu` ignores its arguments.)
- The other entries have an empty command; `track` rebuilds one from
  `/proc/PID/cwd` and `/proc/PID/cmdline` and runs `(cd CWD; CMDLINE) &`.
- If `/oem/midea_autorun` exists (vendor debug mode) `track` logs
  `debug mode, not restart.` and does nothing.
- The heartbeat check works on a 64-entry shared-memory table (shm key
  `0x1306e7b`, `0x168` bytes per entry, filled by the nodes): on a dead pid or
  a hang timeout it sends `SIGKILL` and runs that entry's own registered
  command. Not decoded further.
- Nothing in the scripts reboots the robot when a node dies.
- The restart runs in `track`'s process, which has the global mount
  namespace, so the new `manager_node` starts from `/usr/navi/manager_node`,
  i.e. the bind-mounted patched file.

Design from that:
- **Kill `manager_node` and let `track` restart everything.** Starting it by
  hand with the `start-dushu` command line would not help: `track` reacts to
  the death within a second anyway and starts the whole stack, so a manual
  start only creates a duplicate.
- Mount first, then kill (`SIGKILL`; `track` removes the stale pid file).
- Wait up to 240 s for a `manager_node` with a new pid that runs from a file
  with the wanted sha256 (`/proc/PID/exe`).
- Skip the restart in vendor debug mode (`track` won't do it).
- When restoring, unmount lazily (`umount -l`) *before* killing, so the
  restarted process finds the stock file.

Uncertainties:
- Whether the nodes write their pid files fast enough after `start-dushu`
  returns for `track` not to run the restart a second time. Worst case is one
  extra full restart.
- How long the full restart takes. A running clean doesn't survive it (all
  nodes are killed), so don't install or uninstall during a clean.
- Whether Valetudo copes with the nodes restarting under it. `iot_node*` and
  `midea_robot` aren't in `stop`, so it probably reconnects by itself.
- A reboot restarts the stack once more, because the boot hook only runs
  after `start-dushu` (nothing earlier on this firmware is writable).

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
