# j15-stuff

Tools and notes for a rooted **Midea J15 Pro Ultra** robot vacuum running
[Valetudo](https://valetudo.cloud/).

- **camstream**: cloud-free live video from the robot's camera, served as
  H.264 on your local network. View it in Home Assistant, Frigate, VLC or a
  browser (through [go2rtc](https://github.com/AlexxIT/go2rtc)).
- **camera-check**: a diagnostic that finds where the camera pipeline breaks
  (dead sensor, loose cable, driver, capture).
- **persistlog**: keeps the robot's logs across reboots (the firmware keeps
  them in RAM, and only about a day's worth). Installed separately.
- **roomorder**: makes the robot clean selected rooms in the order you
  selected them, by patching 4 bytes in a copy of its `manager_node`
  (bind-mounted over the original). Installed separately; restarts the robot's
  nodes once.
- **obstaclegap**: makes the robot turn away from recognised objects (shoes,
  scales, bins, ...) at 270 mm from its centre instead of 350 mm, by patching
  2 bytes in a copy of its `planner_node`. Wires and feces keep 400 mm.
  Installed separately; restarts the robot's nodes once.
- **patched Valetudo**: a patch series on top of a Valetudo release, built
  into an aarch64 binary and installed over the stock one. Installed
  separately; the stock binary is backed up and can be restored.
- **[docs/](docs/)**: hardware and firmware findings, and ongoing
  investigations:

  | Doc | Contents |
  |---|---|
  | [hardware.md](docs/hardware.md) | SoC, storage, camera pipeline, sensors, power rails |
  | [camera-troubleshooting.md](docs/camera-troubleshooting.md) | diagnosing a dead camera (solved: loose ribbon cable) |
  | [firmware-internals.md](docs/firmware-internals.md) | processes, ubus API, "mass" IPC, video frame format, logs |
  | [modifying-firmware.md](docs/modifying-firmware.md) | boot chain, vendor debug mode, ways to change behaviour, risks |
  | [mop-lift-investigation.md](docs/mop-lift-investigation.md) | **open**: right mop pad sometimes doesn't lift |
  | [room-order-investigation.md](docs/room-order-investigation.md) | rooms aren't cleaned in the selected order: cause, the two fixes, how `manager_node` gets restarted |
  | [valetudo-comparison.md](docs/valetudo-comparison.md) | where Valetudo's Midea driver and the firmware disagree (labels, enums, error codes, unexposed features) |
  | [firmware-flashing-investigation.md](docs/firmware-flashing-investigation.md) | flash layout, stock update chain, brick risk and recovery paths for reflashing |
  | [corner-cleaning-investigation.md](docs/corner-cleaning-investigation.md) | corner and edge cleaning routines, which switches turn them on |
  | [obstacle-avoidance-investigation.md](docs/obstacle-avoidance-investigation.md) | why the robot keeps a wide berth around recognised objects (hard-coded 350/400 mm thresholds) |
  | [water-tank-investigation.md](docs/water-tank-investigation.md) | dock tank sensors, water use measured on a real job, options for level warnings |
  | [valetudo-patches.md](docs/valetudo-patches.md) | how the Valetudo patch series is built, edited, rebased and installed |
  | [persistent-logs.md](docs/persistent-logs.md) | how the firmware rotates logs, and keeping them across reboots |
  | [research-workflow.md](docs/research-workflow.md) | how to dump, analyse and reproduce these findings |

- **[tools/](tools/)**: helper scripts for analysis on your computer:
  `mop-timeline.py` (mop events from robot logs) and `fdt2dts.py`
  (device tree to text).

## Disclaimer

This modifies a device you own. Each component only adds files
in `/userdata` and one line in `/oem/_root_postboot.sh`, and its uninstall
command removes both (persistlog keeps the logs it saved). roomorder and
obstaclegap also bind-mount a patched `manager_node` / `planner_node` over the
vendor one at boot; uninstalling unmounts it. The Valetudo
component has no boot hook; it replaces `/userdata/valetudo` and keeps the
stock binary as `/userdata/valetudo.stock`.

I have absolutely no idea what I am doing, I would not be able to do something
like this without Claude or other LLMs.

ALWAYS USE AT YOUR OWN RISK

## Requirements

- A rooted J15 with SSH access as `root` (for example, after installing
  Valetudo). Tested on the J15 Pro Ultra; see
  [firmware-internals.md](docs/firmware-internals.md) for the firmware
  version examined.
- A computer with `ssh`, `make` and a C cross-compiler for aarch64 Linux
  (see [Building](#building)).
- For viewing: `ffplay` (part of ffmpeg) for a quick test, and go2rtc for
  everyday use.

## Building

`camstream` is a single C file with no dependencies beyond glibc. It has to
be built on another machine, because the robot has no compiler.

The one constraint is the **glibc version**. The robot runs glibc 2.29, and
a binary built against a newer glibc may refuse to start with
`version 'GLIBC_2.34' not found`. glibc 2.34 moved `pthread_create` and
`dlopen` into a newly versioned libc, so toolchains with 2.34 or later
(Ubuntu 22.04+, Debian 12+, most current distributions) hit this. It also
can't be linked statically or against musl: `camstream` loads the robot's
own glibc-linked `libsample_plugin.so` at runtime.

### With Zig (easiest)

[Zig](https://ziglang.org/) isn't required, but it's the most convenient
option. It bundles a C cross-compiler for every target, and can build against
any older glibc version without a sysroot or Docker, on macOS, Linux or
Windows.

```sh
brew install zig          # or your distribution's package / ziglang.org/download
make                      # → build/camstream
```

The Makefile uses `zig cc -target aarch64-linux-gnu.2.17`, which needs only
`GLIBC_2.17` symbols.

### With GCC or Clang

Any aarch64 Linux toolchain whose glibc is **2.29 or older** works:

```sh
make CROSS_CC=aarch64-linux-gnu-gcc       # e.g. a Debian 10 cross toolchain
make CROSS_CC=cc                          # natively on an old-enough aarch64 Linux box
```

### Checking a build

Every version listed must be 2.29 or lower:

```sh
objdump -T build/camstream | grep -o 'GLIBC_[0-9.]*' | sort -uV
```

Use `aarch64-linux-gnu-objdump` if your `objdump` doesn't understand
aarch64; the macOS and LLVM `objdump` do.

## Install

```sh
git clone <this repo> && cd j15-stuff
./install.sh install 192.168.1.50     # your robot's IP
```

This builds `camstream` if `build/camstream` doesn't exist yet (see
[Building](#building)), checks the robot is a compatible J15, copies the
files to `/userdata`, adds a boot hook to `/oem/_root_postboot.sh` and
starts the service. Running it again upgrades in place and keeps your
config.

Anything after the robot address goes to `ssh` unchanged, so you can add a
key, a port or any other option:

```sh
./install.sh install 192.168.1.50 -i ~/.ssh/robot
./install.sh status  192.168.1.50 -i ~/.ssh/robot -p 2222 -o StrictHostKeyChecking=accept-new
```

Your options are applied before the installer's default
`-o ConnectTimeout=10`, so you can override that too.

Test it:

```sh
ffplay -fflags nobuffer -f h264 tcp://192.168.1.50:8555
```

Other commands:

```sh
./install.sh status    <ip> [ssh options]   # running? listening? boot hook present? last log lines
./install.sh restart   <ip> [ssh options]   # after editing /userdata/camstream.conf
./install.sh check     <ip> [ssh options]   # camera pipeline diagnostic
./install.sh collect-logs <ip> [ssh options]  # save robot logs + dmesg to ./j15-logs-<time>.tar
./install.sh uninstall <ip> [ssh options]   # remove everything, including the boot hook
```

## Persistent logs

The firmware writes its logs to a 30 MB RAM disk and keeps only the last few
files per process, so most of them cover less than a day and all of them are
gone after a reboot. `persistlog` copies them to flash (`/userdata/persist-logs`,
capped at 64 MB, one folder per boot) every 10 minutes and on shutdown. It
doesn't need camstream and doesn't need a build:

```sh
./install.sh persistlog-install   <ip> [ssh options]
./install.sh persistlog-status    <ip> [ssh options]   # running? boot hook? store size, saved boots
./install.sh persistlog-uninstall <ip> [ssh options]   # keeps the saved logs
```

`./install.sh collect-logs` includes the saved logs. Settings (size cap,
interval, extra logs) are in `/userdata/persistlog.conf`. Cloud connection
logs, core dumps and map images are never copied. Details are in
[docs/persistent-logs.md](docs/persistent-logs.md).

## Room order

When you select several rooms, the firmware cleans them in its own order, not
yours (cause in
[docs/room-order-investigation.md](docs/room-order-investigation.md)).
`roomorder` fixes that on the robot: it copies `/usr/navi/manager_node` to
`/userdata/roomorder`, changes one instruction in the copy, and bind-mounts it
over the original at every boot. The vendor binary is never shipped, and the
installer refuses to do anything unless the robot's `manager_node` is exactly
the firmware version the patch was written for.

```sh
./install.sh roomorder-install   <ip> [ssh options]
./install.sh roomorder-status    <ip> [ssh options]   # mount active? running binary? boot hook? log
./install.sh roomorder-uninstall <ip> [ssh options]   # unmounts, restarts manager_node, removes files
```

Installing, uninstalling and every boot **restart all the robot's nodes**
(`/usr/bin/track` restarts the whole stack when `manager_node` dies; about a
minute). Don't do it during a clean. Not tested on the robot yet. The patched
Valetudo notices the mount and then doesn't write the clean sequence itself
(see [docs/valetudo-patches.md](docs/valetudo-patches.md)).

## Obstacle gap

The robot turns away from objects its camera recognises when its centre is
350 mm from them, which leaves about 17 cm uncleaned around each one (see
[docs/obstacle-avoidance-investigation.md](docs/obstacle-avoidance-investigation.md)).
`obstaclegap` lowers that to 270 mm (about 9.5 cm to the bumper). It works
like `roomorder`: it copies `/usr/navi/planner_node` to `/userdata/obstaclegap`,
changes the two distances in the copy's level table, and bind-mounts it over
the original at every boot. Electric wires and feces (400 mm) and circling
around an object (0.40 m) are unchanged.

```sh
./install.sh obstaclegap-install   <ip> [ssh options]
./install.sh obstaclegap-status    <ip> [ssh options]
./install.sh obstaclegap-uninstall <ip> [ssh options]   # unmounts, restarts planner_node, removes files
```

Installing, uninstalling and every boot **restart all the robot's nodes**
(`track` restarts the whole stack when `planner_node` dies). Don't do it during
a clean.

## Patched Valetudo

`valetudo/patches/` holds a patch series on top of the Valetudo release in
`valetudo/BASE`. `valetudo/build.sh` builds it (needs `git`, `node` 20+ and
`npm`), and the installer swaps it in for the stock binary:

```sh
valetudo/build.sh                                       # → build/valetudo-aarch64
./install.sh valetudo-install   <ip> [ssh options]      # backs up the stock binary, disables auto-update
./install.sh valetudo-status    <ip> [ssh options]      # running? patched or stock? backup present?
./install.sh valetudo-uninstall <ip> [ssh options]      # restores the stock binary
```

Not tested on the robot yet. Details, caveats and how to add patches are in
[docs/valetudo-patches.md](docs/valetudo-patches.md).

## Viewing in Home Assistant or a browser

`camstream` serves **one client at a time**; a newly connecting client
replaces the current one. Put go2rtc in front of it, so go2rtc holds the
single connection and serves any number of viewers. Use the go2rtc add-on,
Frigate's built-in go2rtc, or standalone go2rtc with
[examples/go2rtc.yaml](examples/go2rtc.yaml):

```yaml
streams:
  j15:
    - exec:ffmpeg -hide_banner -use_wallclock_as_timestamps 1 -f h264 -i tcp://ROBOT_IP:8555 -c copy -rtsp_transport tcp -f rtsp {output}
```

Then use `rtsp://<go2rtc-host>:8554/j15` as a camera in Home Assistant, or
open go2rtc's web UI on port 1984 for a WebRTC player.

## Configuration

`/userdata/camstream.conf` on the robot:

| Setting | Default | |
|---|---|---|
| `BIND` | `0.0.0.0` | address to listen on; set it to the robot's LAN IP to listen only there |
| `PORT` | `8555` | TCP port |

Run `./install.sh restart <ip>` after changing it.

## How it works

`video_node`, the robot's camera service, already hardware-encodes
640×480 H.264 for the cloud app. When a client connects, `camstream`:

1. calls `start_push` on the `media.engine.control` ubus object, which makes
   `video_node` start publishing frames;
2. subscribes to the `camera_stream` topic through the robot's own messaging
   library (`libsample_plugin.so`), reading each frame from
   `/dev/shm/camera_stream`;
3. waits for a keyframe, then streams raw Annex-B H.264 over TCP.

When the client disconnects, it calls `stop_push`, so the camera only encodes
while someone is watching. The details are in
[docs/firmware-internals.md](docs/firmware-internals.md).

`camstream` can also record a clip, which is useful for debugging:

```sh
ssh root@<ip> '/userdata/camstream -d /tmp/clip.h264 -n 200'   # about 10 s
ssh root@<ip> 'cat /tmp/clip.h264' > clip.h264 && ffplay clip.h264
```

### Snapshots without camstream

`video_node` can save a JPEG on its own:

```sh
ssh root@<ip> "ubus -s /tmp/ubus.sock call media.engine.control grap_pic '{\"file_path\":\"/tmp/snap.jpg\"}'"
```

The first snapshot after the camera has been idle can be black while
auto-exposure settles.

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `ffplay` connects but shows nothing | The camera isn't delivering frames. Run `./install.sh check <ip>` and see [camera-troubleshooting.md](docs/camera-troubleshooting.md). |
| `ubus object media.engine.control not found` | `video_node` isn't running, or the firmware differs from the one examined. |
| `Connection refused` | `camstream` isn't running. Run `./install.sh status <ip>` and read the log lines it prints. |
| A second viewer disconnects the first | Expected; use go2rtc. |
| `ubus` says "cannot connect to ubus" | Add `-s /tmp/ubus.sock`; the robot uses a non-default socket. |

## Security

The stream is **unencrypted and unauthenticated**. Anyone who can reach the
port can watch the camera. Keep it on a network you trust, limit it with
`BIND` if the robot has several interfaces, and never forward the port
through your router.

## License

Public domain, under the [Unlicense](LICENSE). No rights reserved and no
warranty.
