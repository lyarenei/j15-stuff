# obstaclegap

Makes the robot turn away from recognised objects (shoes, scales, bins, ...) at
270 mm from its centre instead of 350 mm. Status: verified on the robot.

## The problem

For objects its camera recognises, the robot brakes and turns away when its
centre is 350 mm from them. With a bumper radius of about 175 mm that leaves
roughly 17 cm of floor uncleaned around each object. The values are hard-coded
in the firmware, so no setting changes them.

## What it changes

| Object class | Stock | With obstaclegap |
|---|---|---|
| Most recognised objects (levels 2 and 3) | 350 mm | **270 mm** (about 9.5 cm to the bumper) |
| Electric wires, feces and a few others (level 4) | 400 mm | 400 mm, unchanged |

Circling around an object (0.40 m) is unchanged too.

obstaclegap copies `/usr/navi/planner_node` to `/userdata/obstaclegap`, changes
two bytes in the copy's distance table (12 bytes are rewritten) and bind-mounts
the copy over the original at every boot. The vendor binary is never shipped,
and the installer refuses to do anything unless `planner_node` is exactly the
firmware version the patch was written for.

## Requirements

- A rooted J15 with SSH access as `root`.
- The firmware version the patch was written for.
- The robot is not in vendor debug mode (`/oem/midea_autorun` absent), and is
  docked or idle.

## Install, status, uninstall

```sh
./install.sh obstaclegap-install   192.168.1.50 [ssh options]
./install.sh obstaclegap-status    192.168.1.50 [ssh options]
./install.sh obstaclegap-uninstall 192.168.1.50 [ssh options]   # unmounts, restarts planner_node, removes files
```

Installing, uninstalling and every boot **restart all the robot's nodes**
(`track` restarts the whole stack when `planner_node` dies; about a minute).
Don't do it during a clean.

## Configuration

None. To use another distance you would have to change the patch bytes in
`robot/obstaclegap.sh`.

## Limits and caveats

- These objects are avoided on purpose: the robot shouldn't touch wires, feces
  or things it could climb. A smaller distance gives it less room to stop and
  turn. Watch what it does around cables and shoes after installing.
- Some wire detections happen late (the camera sees a wire only from about
  21 to 25 cm), and the detector can also report a wire where there is none.
  The patch does not change either.
- The lidar bumper and the circling mode still bring the robot closer than
  270 mm in some cases.
- Re-create the patch after a firmware update; the boot hook skips the mount
  when the checksum doesn't match.
- If you also install [roomorder](roomorder.md), each one restarts the nodes
  at boot.

## How it was found

The thresholds, the logs they were read from and the check after install: wiki
page
[obstacle-avoidance-investigation](https://github.com/lyarenei/j15-stuff/wiki/obstacle-avoidance-investigation).
