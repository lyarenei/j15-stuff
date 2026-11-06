# j15-stuff

Tools for a rooted **Midea J15 Pro Ultra** robot vacuum running
[Valetudo](https://valetudo.cloud/). They add things the stock firmware and
Valetudo don't do: a cloud-free camera stream, logs that survive reboots,
estimated dock water tank levels, cleaning rooms in the order you select them,
cleaning closer to recognised objects, and a patched Valetudo that fixes the
Midea driver. It is for people who already have root access on their J15 and
are comfortable with `ssh`.

## Components

Each component installs on its own. All are installed from your computer with
`./install.sh`.

| Component | What it does for you | Needs a build | Restarts robot nodes | Status |
|---|---|---|---|---|
| [camstream](docs/camstream.md) | Live video from the robot's camera as H.264 over your local network, for Home Assistant, Frigate, VLC or a browser (through go2rtc). Includes `camera-check`, a camera pipeline diagnostic. | Yes (C, cross-compiled) | No | Verified on the robot. |
| [persistlog](docs/persistlog.md) | Keeps the robot's logs across reboots and further back than the firmware does. | No | No | Verified on the robot. |
| [tankwatch](docs/tankwatch.md) | Estimates how full the dock's clean and dirty water tanks are (the dock has no level sensors). | No | No | Verified on the robot. Calibration recommended. |
| [roomorder](docs/roomorder.md) | Firmware patch: cleans selected rooms in the order you selected them. Optional if you use the patched Valetudo. | No | Yes, all nodes | Untested. |
| [obstaclegap](docs/obstaclegap.md) | Firmware patch: turns away from recognised objects at 270 mm instead of 350 mm, so less floor around them stays uncleaned. | No | Yes, all nodes | Verified on the robot. |
| [Patched Valetudo](docs/valetudo.md) | A patch series on top of Valetudo 2026.10.0: Midea driver fixes, more settings, ordered room cleaning, tank levels in the UI. | Yes (git, Node.js) | No (restarts Valetudo) | Verified on the robot. |

## Requirements

- A rooted J15 with SSH access as `root` (for example, after installing
  Valetudo). Tested on the J15 Pro Ultra. The firmware patches only install on
  the firmware version they were written for and refuse anything else.
- A computer with `ssh`. Other tools depend on the component: `make` and a
  C cross-compiler for camstream, `git`, `node` 20+ and `npm` for the patched
  Valetudo. The other components need nothing else.

## Quick start

```sh
git clone https://github.com/lyarenei/j15-stuff && cd j15-stuff
./install.sh install 192.168.1.50     # camstream, on your robot's IP
```

Every component has its own `install`, `status` and `uninstall` commands, for
example `./install.sh persistlog-install 192.168.1.50`. They are listed in the
component guides. `./install.sh --help` lists all of them.

Anything after the robot address goes to `ssh` unchanged, so you can add a
key, a port or any other option:

```sh
./install.sh persistlog-install 192.168.1.50 -i ~/.ssh/robot
./install.sh status 192.168.1.50 -i ~/.ssh/robot -p 2222 -o StrictHostKeyChecking=accept-new
```

Your options are applied before the installer's default
`-o ConnectTimeout=10`, so you can override that too. The robot address must
come before the ssh options.

## Guides

- [camstream](docs/camstream.md): building, installing, viewing in Home
  Assistant or a browser, configuration, troubleshooting.
- [Camera troubleshooting](docs/camera-troubleshooting.md): finding out why the
  camera shows nothing (`./install.sh check`).
- [persistlog](docs/persistlog.md)
- [tankwatch](docs/tankwatch.md)
- [roomorder](docs/roomorder.md)
- [obstaclegap](docs/obstaclegap.md)
- [Patched Valetudo](docs/valetudo.md): what the patches change, building,
  installing, and adding patches.

## Research

How all of this was found (hardware, firmware internals, protocol details,
investigations that are still open) is written up in the
[wiki](https://github.com/lyarenei/j15-stuff/wiki). Each guide links to the
page behind its component.

## Tools

Helper scripts for your computer, in [tools/](tools/):

- `mop-timeline.py`: lists mop events from robot logs.
- `fdt2dts.py`: converts a device tree blob to text.
- `tankwatch-replay.sh`: runs robot data logs through the tankwatch model.

## Disclaimer

This modifies a device you own. Each component only adds files
in `/userdata` and one line in `/oem/_root_postboot.sh`, and its uninstall
command removes both (persistlog keeps the logs it saved, tankwatch its
calibration log and the renamed state). roomorder and
obstaclegap also bind-mount a patched `manager_node` / `planner_node` over the
vendor one at boot; uninstalling unmounts it. The Valetudo
component has no boot hook; it replaces `/userdata/valetudo` and keeps the
stock binary as `/userdata/valetudo.stock`.

I have absolutely no idea what I am doing, I would not be able to do something
like this without Claude or other LLMs.

ALWAYS USE AT YOUR OWN RISK

## Security

camstream's stream is **unencrypted and unauthenticated**. Anyone who can
reach the port can watch the camera. Keep it on a network you trust and never
forward the port through your router. See the
[camstream guide](docs/camstream.md#security). The other components open no
network ports.

## License

Public domain, under the [Unlicense](LICENSE). No rights reserved and no
warranty.
