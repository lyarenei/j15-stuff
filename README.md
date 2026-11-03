# j15-stuff

Tools and notes for a rooted **Midea J15 Pro Ultra** robot vacuum running
[Valetudo](https://valetudo.cloud/).

- **camstream**: cloud-free live video from the robot's camera, served as
  H.264 on your local network. View it in Home Assistant, Frigate, VLC or a
  browser (through [go2rtc](https://github.com/AlexxIT/go2rtc)).
- **camera-check**: a diagnostic that finds where the camera pipeline breaks
  (dead sensor, loose cable, driver, capture).
- **[docs/](docs/)**: hardware and firmware findings (camera pipeline, ubus
  API, Midea's IPC protocol, the video frame format).

## Disclaimer

This modifies a device you own. It only adds files
in `/userdata` and one line in `/oem/_root_postboot.sh`, and
`./install.sh uninstall` removes both.

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
./install.sh uninstall <ip> [ssh options]   # remove everything, including the boot hook
```

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
