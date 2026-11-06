# Patched Valetudo

A patch series on top of a Valetudo release, built into an aarch64 binary and
installed over the stock one on the robot. It fixes and extends Valetudo's
Midea driver without waiting for upstream and without forking the project.
Status: verified on the robot (patches 0001 to 0031, Valetudo 2026.10.0).

## What it fixes and adds

All patches touch only the Midea driver and `backend/lib/msmart` (plus a small
core addition for tank consumables and the frontend dock tiles).

**Status and reporting**

- Robot error codes from the firmware's own table: wrong labels fixed, missing
  codes added.
- Dock error codes fixed and added. Code 100 (dust collection) is no longer
  shown as an error, and codes for a full or missing dirty tank are added.
- Work status 3 is read as paused (resumable), not docked.
- The dock status byte is read only while the robot is on the station.
- Cleaned area and time are read correctly past 255.
- Volume isn't reported as 0 during do-not-disturb silence.
- Water levels between presets are reported instead of overwritten.
- Operation mode 5 is read as vacuum and mop. Fan levels 0 and 5 are reported
  as off and max.

**Settings and quirks**

- Better labels: AI obstacle classification options are normal / smart /
  super, and "AI Carpet Detection" has a proper title.
- J15 Pro Ultra quirks: "Edge Deep Vacuum" and "Gap Deep Cleaning".
- Newly exposed quirks: criss-cross, zigzag to end, AI carpet avoidance,
  curtain detection, big object recognition, fall-down detection, stuck spot
  marking, continuous cleaning, child lock follows DND, narrow zone recharge,
  cross bridge.
- Wash frequency and intensity quirks also write the custom pair.
- Setting changes check the robot's reply.
- Wi-Fi scan on the J15 Pro Ultra.
- A state poll after an error event.

**Room order**

- Cleans selected rooms in the order you selected them. See
  [roomorder](roomorder.md) for how this relates to the firmware patch.

**Water tank levels**

- "Clean Water Tank" and "Dirty Water Tank" consumables, with reset, and
  estimated levels with a low warning on the Dock panel. Needs
  [tankwatch](tankwatch.md) on the robot. Valetudo only reads
  `/userdata/tankwatch/state.json`; if the file doesn't exist when Valetudo
  starts, nothing is shown.

Not included: per-room fan, water and route settings. They only take effect in
"customized clean" mode, which also moves vacuum-only rooms to the front, and
need a new frontend dialog.

The patches are in `valetudo/patches/`, numbered in the order they apply.

## Requirements

- A rooted J15 with SSH access as `root`, running a stock Valetudo
  (`/userdata/valetudo` must exist).
- To build: `git`, Node.js 20+ and `npm`, on macOS or Linux. The build uses
  pkg's `node22` target, which it downloads on first use.
- About twice the binary size plus 10 MB free on `/userdata` (the installer
  checks).

## Building

```sh
valetudo/build.sh                        # writes build/valetudo-aarch64
```

It clones `https://github.com/Hypfer/Valetudo` into `build/valetudo-src`,
checks out the release in `valetudo/BASE` as branch `j15-patched`, applies
`valetudo/patches/*.patch` with `git am --3way`, runs `npm ci`, builds the
frontend and the aarch64 backend, and prints the size and sha256 of the
result. If a patch doesn't apply it stops and says so. A build takes under a
minute once dependencies are installed, and the output is about 37 MB.

| Variable | Default | |
|---|---|---|
| `VALETUDO_SRC` | unset | build this existing checkout as it is: no clone, no patches |
| `VALETUDO_CACHE` | `build/valetudo-src` | where the clone lives |

## Install, status, restart, uninstall

```sh
./install.sh valetudo-install   192.168.1.50 [ssh options]   # backs up the stock binary, disables auto-update
./install.sh valetudo-status    192.168.1.50 [ssh options]   # running? patched or stock? backup present?
./install.sh valetudo-restart   192.168.1.50 [ssh options]   # restarts Valetudo, keeping its environment and config path
./install.sh valetudo-uninstall 192.168.1.50 [ssh options]   # restores the stock binary
```

`valetudo-install`:

1. builds `build/valetudo-aarch64` if it doesn't exist;
2. checks the robot (aarch64, J15 firmware, `/userdata/valetudo` present, free
   space);
3. copies the stock binary to `/userdata/valetudo.stock` once, and never
   overwrites an existing backup;
4. uploads the new binary over plain ssh and checks its sha256;
5. captures the running Valetudo's `VALETUDO_*` environment, sets
   `updater.enabled` to `false` in its config, stops Valetudo, swaps the
   binary and starts it again.

`valetudo-uninstall` restores the backup, re-enables the updater if the
installer was the one that disabled it, restarts Valetudo and deletes the
backup. Use `valetudo-restart` after installing or uninstalling
[tankwatch](tankwatch.md).

There is no boot hook. The binary replaces the stock one in place, and the
robot starts it as it always did. State is in `/userdata/valetudo.stock`,
`/userdata/valetudo.patched` (config path and whether the updater was
flipped) and `<config>.pre-patched` (a copy of the config before the first
change).

## Limits and caveats

- Check `valetudo-status` and the Valetudo UI after installing. If it doesn't
  come up, run `valetudo-uninstall`, or copy `/userdata/valetudo.stock` over
  `/userdata/valetudo` by hand.
- **Automatic updates are disabled.** A Valetudo update from the UI would
  replace the patched binary with stock. Update by rebasing the patches and
  installing again (see below).
- **Upstream doesn't support modified builds.** Don't report bugs to Valetudo
  without reproducing them on a stock build. The version string is unchanged,
  so the UI doesn't show it's patched; use `valetudo-status`.
- Nothing supervises Valetudo on the robot. The installer kills the process,
  waits 15 s for the robot to start it again, and otherwise starts
  `/userdata/valetudo` itself with the environment it captured. After a reboot
  the robot's own boot scripts start it, as before.
- The config path is taken from the running process, then from
  `/userdata/valetudo_config.json` and two other guesses. If none exists, the
  installer warns and you have to turn updates off in the UI (Settings,
  Updater).
- The robot's busybox lacks `tr` and `nohup` links. The installer works around
  that; if you start Valetudo by hand, keep `VALETUDO_CONFIG_PATH` set.

## For developers

### Layout

| Path | Contents |
|---|---|
| `valetudo/BASE` | upstream tag the patches apply to |
| `valetudo/patches/` | `NNNN-*.patch` files from `git format-patch`, applied in order |
| `valetudo/build.sh` | clone, apply patches, build, write `build/valetudo-aarch64` |
| `valetudo/export-patches.sh` | regenerate `patches/` from commits in a checkout |
| `build/valetudo-src/` | cached upstream clone (gitignored) |
| `build/valetudo-aarch64` | the build output (gitignored) |

The Valetudo binary is a [pkg](https://github.com/yao-pkg/pkg) bundle (Node
22, all JavaScript and the web UI in one static file), and Valetudo has no
plugin system, so a patch series that is rebuilt from source is the
maintainable way to change it.

### Adding or editing a patch

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
argument. Exported patches use `--no-signature --zero-commit`, so diffs between
versions stay small. Backend code can be tested without building a binary:
`npm run start:dev --workspace=backend` in the checkout.

### Moving to a new Valetudo release

1. Check the release notes for changes to the Midea driver.
2. Put the new tag in `valetudo/BASE`.
3. Run `valetudo/build.sh`. If a patch conflicts, it stops with the checkout
   in the middle of `git am`.
4. In `build/valetudo-src`: resolve, `git add`, `git am --continue`, repeat.
5. Run `valetudo/export-patches.sh`, then build and test again.

## How it was found

Where Valetudo's Midea driver and the firmware disagree, and why each patch
exists: wiki page
[valetudo-comparison](https://github.com/lyarenei/j15-stuff/wiki/valetudo-comparison).
Room order: [room-order-investigation](https://github.com/lyarenei/j15-stuff/wiki/room-order-investigation).
Tank levels: [water-tank-investigation](https://github.com/lyarenei/j15-stuff/wiki/water-tank-investigation).
