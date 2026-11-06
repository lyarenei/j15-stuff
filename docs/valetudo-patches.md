# Patched Valetudo

**Status:** installed and running on the robot (2026-11-06). The API reports
release `2026.10.0`, the robot connected to the dummycloud, the updater is
disabled, and the stock binary is backed up. The patched features (room order,
the other protocol fixes) haven't been tried yet. Written 2026-11-04.

The first install attempt failed because `tr` and `nohup` aren't linked on
the robot ([hardware.md](hardware.md#useful-tools-already-on-the-robot)).
The old Valetudo was stopped, but the new one couldn't start. Without `tr`,
the captured environment was also empty, so a manual start would have lost
`VALETUDO_CONFIG_PATH`. The installer now falls back to `busybox` and adds
the config path it found. Nothing supervises Valetudo, so the robot never
restarts it itself; the installer always starts it by hand.

## Goal

Fix or extend behaviour in Valetudo's Midea driver (for example the room
order, see [room-order-investigation.md](room-order-investigation.md))
without waiting for upstream, and without forking the whole project.

## Why rebuild instead of patching the robot

- The Valetudo binary is a [pkg](https://github.com/yao-pkg/pkg) bundle:
  Node 22, all JavaScript and the web UI in one static aarch64 file, with
  the JS compressed (Brotli, no bytecode). There is nothing to edit in
  place.
- Valetudo has no plugin or hook system.
- Patching the compressed snapshot in the binary is fragile and breaks on
  every release.

- A runtime patch is possible: with `PKG_EXECPATH` set to the binary's own
  path, the pkg runtime runs an external script instead of the bundled
  entry point (`yao-pkg` 6.6.0 `prelude/bootstrap.js:77-89`), which could
  monkey-patch the bundled modules. It was rejected: it depends on pkg
  internals and Valetudo's internal names, breaks silently on upstream
  changes, and can't change the frontend.

So the repo keeps a **patch series on top of an upstream release tag**,
builds a full binary from it on your computer, and replaces
`/userdata/valetudo` on the robot.

## Layout

| Path | Contents |
|---|---|
| `valetudo/BASE` | upstream tag the patches apply to (`2026.10.0`) |
| `valetudo/patches/` | `NNNN-*.patch` files from `git format-patch`, applied in order |
| `valetudo/build.sh` | clone, apply patches, build, write `build/valetudo-aarch64` |
| `valetudo/export-patches.sh` | regenerate `patches/` from commits in a checkout |
| `build/valetudo-src/` | cached upstream clone (gitignored) |
| `build/valetudo-aarch64` | the build output (gitignored) |

## Patches

Base: Valetudo `2026.10.0`. All patches touch only the Midea driver and
`backend/lib/msmart`, and are based on static analysis. **None has been
tested on the robot.** The `#` column refers to the mismatch table in
[valetudo-comparison.md](valetudo-comparison.md#all-mismatches).

| Patch | What it does | # |
|---|---|---|
| 0001 | Robot error codes from the firmware table (fixes 1-19..1-24, 1-81, 1-83; adds 1-25..30, 1-86, 1-95, 1-165, 1-168..172) | 23–30 |
| 0002 | Dock error codes: 100 is dust collection (no longer an error), 103/104 dirty tank full/missing, fixed and added codes | 31–34 |
| 0003 | Work status 3 is paused (resumable), not docked | 3 |
| 0004 | Dock status byte only read while on the station | 4, 41 |
| 0005 | Area and time split at 255; exact area from bytes 39–40 when it agrees | 16 |
| 0006 | Volume isn't reported as 0 during DND silence | 17 |
| 0007 | Water levels between presets are reported, not overwritten | 7 |
| 0008 | Operation mode 5 read as vacuum and mop (6 = customized clean stays unknown); fix the field updated after a change | 8 |
| 0009 | Fan levels 0 and 5 reported as off / max | 18 |
| 0010 | `MSmartToggles.setToggle`: 0x9C writes check the reply, used by the capabilities | 35 |
| 0011 | Reply checks for 0xC7, 0x56, 0x5C, 0x5E | 36 |
| 0012 | State poll after an error event | 37 |
| 0013 | Mop drying getter accepts modes 0–7 | 5 |
| 0014 | Wash frequency / intensity quirks also write the custom pair | 6 |
| 0015 | AI obstacle classification options relabelled normal / smart / super | 2 |
| 0016 | "AI Carpet Detection" title and description for carpet bit 3 | 10 |
| 0017 | "Edge Deep Vacuum" quirk replaces collision-avoidant navigation (J15 Pro Ultra) | 1 |
| 0018 | "Gap Deep Cleaning" quirk replaces mop twist (J15 Pro Ultra) | 12 |
| 0019 | Quirks: criss-cross, zigzag to end | unexposed |
| 0020 | Quirks: AI carpet avoidance, curtain detection, big object recognition, fall-down detection, stuck spot marking | unexposed |
| 0021 | Quirks: continuous cleaning, child lock follows DND, narrow zone recharge, cross bridge | unexposed |
| 0022 | Unknown floor materials 1/4 logged at debug level | 19 |
| 0023 | Wi-Fi scan on the J15 Pro Ultra | 47 |
| 0024 | Quirks use `setToggle` too | 35 |
| 0025 | Parse the room info reply (ACTION 0x28) | |
| 0026 | Room info writer (SETTING 0x2B v2) | |
| 0027 | `MideaRoomOrderHelper`: ordered cleanups | |
| 0028 | Custom segment order on the J15 Pro Ultra | |
| 0029 | Core: `water_tank` consumable type with `clean` / `dirty` sub types (backend, MQTT names, frontend) | |
| 0030 | Tankwatch state file reader and consumable monitoring capability (J15 Pro Ultra, only if the file exists) | |
| 0031 | Dock panel tiles show the estimated tank level and a low warning | |

Room order (0025–0028) works with or without the `roomorder` firmware patch:
if `/usr/navi/manager_node` is a mount in `/proc/mounts`, the request order
is sent as is. Otherwise, or when a selected room already has a stored
`cleanSeq`, Valetudo writes `cleanSeq` = 1..N before the cleanup and
restores the old values once the robot is done. The pending restore is kept
in `robot.implementationSpecificConfig.roomOrderRestore` in the Valetudo
config, so it survives a restart. Details in
[room-order-investigation.md](room-order-investigation.md) and
[valetudo-comparison/room-info.md](valetudo-comparison/room-info.md).

Tank estimates (0029–0031) come from the `tankwatch` daemon on the robot
(see [water-tank-investigation.md](water-tank-investigation.md)). Valetudo
only reads `/userdata/tankwatch/state.json` (cached by mtime; a missing,
malformed or version != 1 file means no estimate) and never talks to the
robot about it. If the file exists at startup, the J15 Pro Ultra registers a
consumable monitoring capability with two percent consumables, "Clean Water
Tank" (water left) and "Dirty Water Tank" (space left). Resetting one (user
refilled or emptied the tank) creates the empty flag file
`/tmp/tankwatch.reset-clean` or `/tmp/tankwatch.reset-dirty`, which the
daemon applies within about 2 s. Without the file nothing changes, so a
restart is needed after installing tankwatch for the consumables to appear.
The dock tiles pick up the estimate on every state update with a station
code: while the firmware says ok, they read "~62% left" (clean) or "~26%
full" (dirty, 100 minus the space left) and turn yellow, making the panel
"Not OK", when tankwatch flags the tank as low. Firmware states empty, full
and missing keep their text and colour. Untested on the robot.

Not done: per-room fan/water/route settings. They only take effect in
operation mode 6 ("customized clean"), which also moves vacuum-only rooms to
the front, and they need a new frontend dialog. Deferred until the robot
runs again.

## Building

Needs `git`, Node 20+ (the build uses pkg's `node22` target, which it
downloads on first use) and `npm`. Works on macOS and Linux.

```sh
valetudo/build.sh
```

It clones `https://github.com/Hypfer/Valetudo` into `build/valetudo-src`,
checks out `BASE` as branch `j15-patched`, applies `valetudo/patches/*.patch`
with `git am --3way`, runs `npm ci`, builds the frontend and the aarch64
backend only, and prints the size and sha256 of `build/valetudo-aarch64`.
If a patch doesn't apply it stops and says so. `npm ci` is skipped when
`package-lock.json` hasn't changed since the last run.

| Variable | Default | |
|---|---|---|
| `VALETUDO_SRC` | unset | build this existing checkout as it is: no clone, no patches, `npm ci` skipped if `node_modules` exists |
| `VALETUDO_CACHE` | `build/valetudo-src` | where the clone lives |

Build facts (stock 2026.10.0, no patches, macOS arm64): about 35-45 s with
dependencies installed, 37 MB output (static-pie aarch64 ELF).
The backend build needs the OpenAPI schema generated first
(`npm run build_openapi_schema`); `build.sh` does that.

## Adding or editing a patch

Work in a checkout with the series applied, so each change stays a clean
commit:

```sh
valetudo/build.sh                       # leaves build/valetudo-src on branch j15-patched
cd build/valetudo-src
# edit, test
git commit -am "Describe the change"    # one commit per patch
cd ../..
valetudo/export-patches.sh              # rewrites valetudo/patches/
git diff valetudo/patches
```

To change an earlier patch, use `git rebase -i <BASE tag>` in the checkout,
then export again. `export-patches.sh` accepts another checkout as its
argument, for example the one you use for development.

Exported patches use `--no-signature --zero-commit`, so the header carries
no git version or commit hash and diffs between versions stay small.
Backend code can be tested without building a binary:
`npm run start:dev --workspace=backend` in the checkout.

## Moving to a new Valetudo release

1. Put the new tag in `valetudo/BASE`.
2. `valetudo/build.sh`. If a patch conflicts, it stops with the checkout in
   the middle of `git am`.
3. In `build/valetudo-src`: resolve, `git add`, `git am --continue`,
   repeat.
4. `valetudo/export-patches.sh`, then build and test again.

Check the release notes for changes to the Midea driver first.

## Install and uninstall

```sh
./install.sh valetudo-install   <ip> [ssh options]
./install.sh valetudo-status    <ip> [ssh options]
./install.sh valetudo-uninstall <ip> [ssh options]
```

`valetudo-install`:

1. builds `build/valetudo-aarch64` if it doesn't exist;
2. checks the robot (aarch64, J15 firmware, `/userdata/valetudo` present);
3. copies the stock binary to `/userdata/valetudo.stock` once, and never
   overwrites an existing backup;
4. uploads the new binary over plain ssh (dropbear has no scp) and checks
   its sha256;
5. captures the running Valetudo's `VALETUDO_*` environment, sets
   `updater.enabled` to `false` in its config, stops Valetudo, swaps the
   binary and restarts it.

`valetudo-uninstall` stops Valetudo, copies the backup back to
`/userdata/valetudo`, re-enables the updater if the installer was the one
that disabled it, restarts and deletes the backup. `valetudo-status`
shows whether Valetudo runs, the binary's sha256, whether it matches the
backup (stock) or not (patched), and whether the updater is on.

Unlike the other components there is no boot hook. The binary replaces the
stock one in place, and the robot starts it as it always did. State is in
`/userdata/valetudo.stock`, `/userdata/valetudo.patched` (config path and
whether the updater was flipped) and `<config>.pre-patched` (copy of the
config before the first change).

## Caveats

- Check `valetudo-status` and the Valetudo UI after installing. If it doesn't come up, restore with
  `valetudo-uninstall`, or copy `/userdata/valetudo.stock` over
  `/userdata/valetudo` by hand.
- **Automatic updates are disabled** (`updater.enabled=false`). A Valetudo
  update from the UI would replace the patched binary with stock. Update
  by rebasing the patches and installing again.
- **Upstream doesn't support modified builds.** Don't report bugs to
  Valetudo without reproducing them on a stock build. The version string
  is unchanged, so the UI doesn't show it's patched; use `valetudo-status`.
- **How Valetudo is started is not known.** The installer doesn't assume a
  start script. It kills the process and waits 15 s for the robot to start
  it again. If nothing does, it starts `/userdata/valetudo` itself with
  the environment it captured from the old process. After a reboot the
  robot's own boot scripts start it, as before.
- **The config path isn't verified.** Valetudo reads it from
  `VALETUDO_CONFIG_PATH` (otherwise it uses `/tmp`). The installer takes
  it from the running process, then falls back to
  `/userdata/valetudo_config.json` and two other guesses. If none exists
  it warns, and you have to turn updates off in the UI
  (Settings, Updater).
- The config edit is a `sed` on Valetudo's own pretty-printed JSON
  (`updater` block, first `enabled`), and it's checked after the restart.
- The binary is built from a pkg Node 22 base. It needs to start on the
  robot's kernel like the stock one does; that is expected but unverified.
