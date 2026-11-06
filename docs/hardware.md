# Hardware

Notes on the Midea J15 Pro Ultra main board, taken from a running robot
(`/proc/cpuinfo`, the live device tree in `/sys/firmware/fdt`, and boot logs).

## SoC and kernel

| | |
|---|---|
| SoC | Rockchip RK3566, 4× Cortex-A55 (`Hardware: Rockchip RK3566 For Midea`) |
| Kernel | Rockchip vendor kernel `4.19.219+`, built `Mon Dec 2 2024` |
| Root FS | squashfs, read-only, about 85 MB |
| Writable | `/oem` (UBIFS, about 28 MB), `/userdata` (UBIFS, about 264 MB) |
| RAM-backed | `/tmp`, `/userdata/logs` (30 MB tmpfs, wiped at reboot) |
| Wi-Fi/BT | Realtek RTL8723DS (`8723ds` module, `rtk_hciattach` on `/dev/ttyS1`) |

## Camera pipeline

```
sensor ──I2C bus 2 (control)──┐
   │                          │
   └─MIPI CSI-2, 1 lane──> csi2-dphy1 ──> rockchip-mipi-csi2 ──> rkcif_mipi_lvds ──> rkisp (vir0/vir1)
                                                                    /dev/media0           /dev/media1, /dev/media2
```

- **Sensor: SmartSens SC035HGS**, I2C address `0x30` on bus 2
  (`i2c@fe5b0000`). VGA, 640×480, 10-bit Bayer (`SBGGR10_1X10`). The only
  image-tuning file in the firmware is `/etc/iqfiles/sc035hgs_default_default.json`.
- **OmniVision OV02B10**, I2C address `0x3c` on the same bus, is also declared
  in the device tree. It's probably a camera variant this board design also
  supports; on the unit examined it's not fitted, and failing to probe is
  normal (`ret(-6)`). The CSI port links back only to the SC035HGS.
- Both sensors share the same reset and power-down GPIOs (with opposite
  polarity) and the same clock (`xvclk`).
- **Power rails** are fixed regulators switched by GPIO. The driver turns
  them on only while probing and turns them off again if the probe fails:

  | Supply | Regulator | Voltage |
  |---|---|---|
  | AVDD | `vcc2v8_dvp` | 2.8 V |
  | DOVDD | `vcc1v8_dvp` | 1.8 V |
  | DVDD | `vcc1v5_dvp` | 1.5 V |

- The image processor (ISP) outputs: `rkisp_mainpath` = `/dev/video5`
  (live view) and `rkisp_selfpath` = `/dev/video6` (AI). These are the
  `device_index` values in `/usr/navi/video_node.json`.

The camera connects to the main board with a flat ribbon cable. On the unit
examined, that cable had worked loose, which made the camera completely dead
(see [camera-troubleshooting.md](camera-troubleshooting.md)).

## Actuators

Most motors (wheels, mops, mop lift, mop arm, pumps, the dock) are run by a
separate motor/sensor microcontroller. Linux sends it commands over the
`mcu-request-*` IPC topics (see
[firmware-internals.md](firmware-internals.md)).

A few things are driven straight from the SoC through `midea-pwm` device
tree nodes. Changes are logged to `dmesg` (`pwm_<name> set level N`):

| Node | Status | Probably |
|---|---|---|
| `pwm_left_hand_brush` | okay | left side brush |
| `pwm_right_turn_right` | okay, `smooth-mode` | right side brush rotation (ramps in steps of 10) |
| `pwm_right_brush_reversal` | okay, `smooth-mode` | right side brush reverse |
| `pwm_fill_light_control` | okay | camera fill light |
| `pwm_radar_speed_control` | disabled | |

## Useful tools already on the robot

`media-ctl`, `v4l2-ctl`, `i2cdetect`, `i2cget`, `i2cset`, `i2ctransfer`,
`ubus`, BusyBox (with `httpd`, `tcpsvd`, `inetd`), `adbd`, `dropbear`.

Some BusyBox v1.27.2 applets have no link in `$PATH`: **`tr`, `wc`, `nohup`,
`timeout`, `install`, `sum`, `last`** (found 2026-11-06). Scripts that run on
the robot must call them as `busybox <applet>`. The robot scripts and
`install.sh` define a small shell function for each one they use. `pkill` and
`pgrep` are missing altogether. When a command is missing, `$(wc -c < f)` just
returns an empty string, so a size check can quietly turn into a no-op.

The factory test binaries in `/usr/bin/rk_pcba_test/` are worth knowing about.
For example, `echo_camera_check_test` only runs
`media-ctl -d /dev/media0 -p | grep type` and looks for a `Sensor` entity.
