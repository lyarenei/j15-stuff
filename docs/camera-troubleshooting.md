# Camera troubleshooting

Symptom on the unit examined: the camera view in the Midea app crashed the
app. The cause was hardware: the camera's ribbon cable had come loose.
Everything above the sensor (driver, ISP, `video_node`, app) was failing
because no frames ever arrived.

## Quick check

```sh
./install.sh check <robot-ip>
```

This runs [`robot/camera-check.sh`](../robot/camera-check.sh) on the robot.
It checks each stage below and says where the pipeline breaks.

## What each stage looks like

### 1. The sensor answers on I2C (boot time)

The sensor driver probes once at boot. If the boot messages have scrolled
out of `dmesg` (they do after a few weeks of uptime), reboot first.

```sh
dmesg | grep -i sc035hgs
```

Healthy:
```
sc035hgs 2-0030: Detected SC035HGS CHIP ID = 0x0031 sensor
rockchip-csi2-dphy csi2-dphy1: dphy1 matches m00_b_sc035hgs 2-0030:bus type 4
```

Broken (the sensor doesn't respond after its power rails are switched on):
```
sc035hgs 2-0030: Unexpected sensor id(0000), ret(-5)
sc035hgs 2-0030: Dropping the link to regulator.2
```

`Failed to get supply 'avdd': -517` near the start is harmless. It's
`EPROBE_DEFER`: the first attempt was postponed until the regulators were
ready, and the retry a moment later is the one that counts.
`ov02b10 ... ret(-6)` is also normal, because that sensor isn't fitted.

### 2. The driver is bound

```sh
for d in /sys/bus/i2c/devices/2-00*; do echo "$d $(cat $d/name) driver=$(readlink $d/driver)"; done
```

An empty `driver=` for `2-0030` means the probe failed.

### 3. The sensor is in the media graph

```sh
media-ctl -d /dev/media0 -p | grep -A3 sc035hgs
```

Healthy output contains `type V4L2 subdev subtype Sensor`, with an
`[ENABLED]` link into `rockchip-csi2-dphy1`. When the sensor is missing, the
kernel logs this every time something tries to start capture:

```
rockchip-csi2-dphy1: No link between dphy and sensor
rkcif_mipi_lvds: rkcif_s_fmt_vid_cap_mplane no sensors
rkisp-vir0: Invalid mipi data type
```

### 4. video_node captures frames

```sh
grep -cE 'start_capture failed|Could not get buffers' /userdata/logs/app/video/video.INFO
```

This should be `0`. With a dead sensor, `video_node` logs
`vcm_ start_capture failed` and
`Could not get buffers from device. errno = 16` on every attempt. It can also
segfault (`/userdata/logs/crash/coredump/video_node-bt-*`).

## Fixing a sensor that doesn't respond

In order of likelihood:

1. **Loose or damaged ribbon cable.** Open the robot and find the cable from
   the front camera module to the main board. Check the connector latches,
   look for corrosion or creases, and reseat both ends. Tape over the latch
   (Kapton tape works well) so bumper knocks don't shake it loose again. This
   was the fix on the unit examined.
2. **Dead camera module.** Replace it with an identical one: SC035HGS,
   1-lane MIPI, I2C `0x30`. The firmware has tuning data only for the SC035HGS.
3. **A main board fault**, such as a regulator or clock. This is unlikely if
   the other devices on the board work.

Measuring the power rails at rest won't tell you anything. The driver only
switches them on for a fraction of a second during probe.
