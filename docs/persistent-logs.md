# Persistent logs

**Status:** implemented (`persistlog`), not yet tested on the robot.
Investigated 2026-11-04.

## Goal

Keep the robot's logs across reboots, and further back than the firmware
keeps them, so a fault (a mop that didn't lift, a crash) can still be
investigated days later.

## How the firmware handles logs

- `/etc/init.d/S23ramlogs` mounts a **30 MB tmpfs on `/userdata/logs`**
  early in boot. Everything in it is lost at reboot, power loss or watchdog
  reset (`S01watchdog` is enabled).
- The nodes use a modified glog. Its flags are visible in the binaries
  (`FLAGS_log_dir`, `FLAGS_max_log_size`, `FLAGS_max_log_file_count`),
  and `planner_node` contains the compressor's messages
  (`[GZIP][%d]-[compress]: begin gz_compress...`).
- Each node writes `app/<node>/<node>.YYYYMMDD-HHMMSS.log`. `<node>.INFO`
  is a symlink to it. At about **2 MB** the file is closed, compressed in
  place to `<node>.<ts>.log.gz` (100–300 KB), and the oldest `.gz` is
  deleted.
- Retention is a **file count, not an age**. Most nodes keep 4–5 `.gz`
  files. `planner_node` keeps 14 (`planner.json`: `"additional_log_file_count": 10`).
- `data_node` also writes `ulog_mcu.ulg` (motor controller log), rotated
  logrotate-style to `ulog_mcu.ulg-1.gz` … `-6.gz`. These names are reused
  as files shift, so a copy can't be identified by name alone.
- The vendor cleanup scripts aren't involved in normal rotation.
  `/usr/sbin/delete_oldest_log.sh` → `S63_delete_oldest_log.sh` runs only
  when `/userdata` has less than 2 MB free, and deletes `*.log.gz` from the
  top of `/userdata/logs`. `debug_mode.sh debug_prepare` also deletes logs
  (see [modifying-firmware.md](modifying-firmware.md)).
- The legacy `config.ini` files in `/etc/formal/product/*/` contain
  `log_max_size_per=2` and `log_max_file_count=5`, matching what was observed.

### How far back the stock logs go

From the 2026-11-02 dump (robot mostly idle on the dock):

| Node | `.gz` kept | Oldest | Typical `.gz` size |
|---|---|---|---|
| manager | 4 | about 18 h earlier | 110–150 KB |
| data | 4 | about 18 h earlier | 140–220 KB |
| media | 4 | about 20 h earlier | 80–150 KB |
| planner | 14 | 5 weeks earlier | 240–330 KB |
| slam | 14 | 9 days earlier | 190–250 KB |

Manager, data and media log steadily, even while idle, so they keep **less
than a day**. The planner and slam go back weeks only because they log
heavily just while cleaning. Across all nodes the rotated output is roughly
**3 MB a day**.

### Other log sources

| Path | Notes |
|---|---|
| `/userdata/logs/system/` | `system.log`, `dmesg.log` and their `_old`, rewritten in place |
| `/userdata/logs/crash/` | `crash_<node>.txt`, and `coredump/*-bt-*` backtraces. `coredump/` is a loop-mounted ext2 (`/dev/loop0`) |
| `/userdata/logs/iot/` | cloud connection logs, **contain credentials** |
| `/sys/fs/pstore/` | ramoops, see below |
| `/tmp/valetudo.log`, `/tmp/camstream.log` | RAM |

### pstore (ramoops)

The device tree reserves `ramoops@110000` (`0xf0000` bytes:
`record-size 0x20000`, `console-size 0x80000`, `pmsg-size 0x50000`), and
the boot log confirms it's active (`pstore: Registered ramoops as persistent
store backend`, `console [pstore-1] enabled`, deflate compression). This RAM
survives a warm reset, so after a reboot or watchdog reset `/sys/fs/pstore`
should contain `console-ramoops-0` (the **previous boot's kernel log**) and
`dmesg-ramoops-*` after a kernel oops or panic. It's lost on a cold power
cut. The existing dumps don't show what was actually in `/sys/fs/pstore`.

### Storage

`/userdata` is UBIFS on NAND (264 MB, about 200 MB free), so its wear
levelling spreads writes across the whole volume. Storing a few MB a day of
rotated files is negligible. Active-log snapshots (below) add roughly
10–40 MB a day of writes. At that rate the whole volume is rewritten about
once every 1–3 weeks, which is still far inside the endurance of NAND flash.

## Design (`persistlog`)

A shell loop on the robot (`/userdata/persistlog.sh`), started from its own
line in `/oem/_root_postboot.sh`. It's installed separately from camstream.

- **Store:** `/userdata/persist-logs/boot-NNNN/`. The boot counter is in
  `.bootcount`. The robot's clock can be wrong just after boot (files dated
  2017 exist), so boots are numbered rather than dated. `boot-info.txt`
  records the date, uptime, firmware version and kernel `boot_id`. A restart
  within the same boot (same `boot_id`) carries on in the same folder.
- **Every 10 minutes** (`INTERVAL`):
  - Copies each new rotated `app/*/*.log.gz` once, by name.
  - Copies `ulog_mcu.ulg-*.gz`, named by content hash, because the source
    names shift.
  - Copies crash `*.txt` and `*-bt-*` backtraces.
  - Writes `*.partial.gz` snapshots of the active logs (`*.log`,
    `ulog_mcu.ulg`, `tasks_info_log.txt`, `system/system.log`,
    `system/dmesg.log`, the `dmesg` output and `EXTRA_LOGS`), but only for
    logs whose size changed since the last snapshot. A partial is deleted
    once its rotated `.gz` has been copied.
- **On TERM** (clean reboot or shutdown) it runs one last cycle.
- **At start** it copies `/sys/fs/pstore` into `pstore-previous-boot/`.
- **Retention:** total `du` capped at `MAX_MB` (64). Whole boots are deleted
  oldest first, then the oldest rotated files of the current boot, by copy
  time. A per-boot `.copied` list stops a deleted file from being copied
  again while it's still in the RAM logs. Copying
  pauses while `/userdata` has less than `MIN_FREE_MB` (50) free.
- **Never copied:** `iot/` (credentials), core dumps, `photo/`, `video/`, and
  home-layout data (`room_map_data_*`, `.ppm`/`.pgm`/`.jpg`, map and task
  snapshots). It uses a whitelist of file patterns.
- With a 64 MB cap and about 3 MB a day of rotated logs, it should keep
  roughly **2–3 weeks**, less if the robot reboots often (each boot's
  partials add some overhead).

Install and use: see the "Persistent logs" section of the
[README](../README.md).

## Open questions

- Does BusyBox `init` send TERM to background scripts on `reboot`? `rcK`
  only stops init scripts. If it doesn't, the final cycle never runs, and
  up to 10 minutes of active logs are lost on reboot, the same as on a
  crash. BusyBox `init` usually follows TERM with KILL after about a second, so
  the final cycle may also be cut short. The snapshots are written to `.tmp`
  and renamed, so an interrupted cycle leaves the previous snapshot intact.
- Which files actually appear in `/sys/fs/pstore` after a normal reboot
  (expected: `console-ramoops-0`).

## Files examined

| File | sha256 |
|---|---|
| `/etc/init.d/S23ramlogs` | `2cf9caa9c2e7c6185ff0125f1a02b3ce2891cee506486fc61c031b4b3bc24c6c` |
| `/usr/sbin/S63_delete_oldest_log.sh` | `7d9e68d1e8356608ef05d44659c1a5fcdc903ad71512b59f5df9d4870148690c` |
| `/usr/navi/planner.json` | `27e9338adeca810347c3f5567b1eb684c3ccee77215345d3fbd157ed93d229ec` |
