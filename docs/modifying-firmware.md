# Modifying robot behaviour

Notes on how the robot software could be changed or extended, from least to
most invasive. Apart from adding programs on the IPC bus (which `camstream`
does), **none of this has been tried on the robot yet**. The `roomorder`
patch (approach 4) is implemented but untested.

## Why it's feasible

- Full root access; the robot software is ordinary Linux programs in
  `/usr/navi/` (see [firmware-internals.md](firmware-internals.md)).
- **The binaries keep their symbol names.** `planner_node` exports about 8,100
  dynamic symbols and `manager_node` about 12,700 (`llvm-nm -D --defined-only`),
  so the C++ class and method names are visible. A lot of logic also lives in
  shared libraries with descriptive names (`/usr/lib/libpath_finding.so`,
  `libstuck_identity.so`, `libcharger_finding.so`, `libBridgeDetection.so`,
  `libzone_segmentation.so`, `liblocal_planning.so`, ...).
- Very detailed glog logging. Searching the log strings is the quickest way
  to find the responsible code.

## Boot chain

```
/etc/init.d/rcS
├─ S40rkaiq_3A                 ISP 3A daemon
├─ S97dropbear.sh              SSH (before any custom hook, so a broken hook can't lock you out)
├─ S98_lunch_init start
│    audio, config dirs, coredump (core_pattern → /etc/coredump_helper),
│    AI models (/userdata/aimodels loop-mounted at /userdata/ai_models, md5-checked)
│    midea_autorun:
│      /usr/sbin/debug_mode.sh test  ──yes──▶ /oem/midea_autorun/debug_mode.sh start_app
│                                    ──no───▶ normal_mode:
│        cd /usr/navi; /usr/bin/track &
│        /oem/test.mod == "FOFF" ? /usr/navi/start-dushu : /usr/navi/start-dushu-fact start
│        /usr/bin/midea_ota &
│        iot_node / iot_node_msmart / midea_robot   (per /oem/product/product_diff.ini IOT_NODE)
└─ S98_postboot.sh             runs /oem/_root_postboot.sh &   ← custom hook (camstream uses this)
```

- `/usr/navi/start-dushu` picks the config set from `/oem/midea/device.type`.
  `MD-DUSHU-MA-RB-01` uses the `*-V15Overseas.json` configs (this robot),
  `MD-DUSHU-MALITE-RB-00` uses `*-V15Lite.json`, and anything else uses the
  defaults. It starts `data_node`, `planner_node`, `laser_slam3_node`,
  `detect_node`, `manager_node`, `semantic_slam_node` and `media_node`, then
  `ubusd.sh`, `audio_node.sh` and `video_node.sh`.
- `/usr/navi/stop` kills all of them.
- `/usr/bin/track` runs alongside the nodes and **is** a supervisor. Once a
  second it checks the pid files in `/var/run` (`manager.pid`, `planner.pid`,
  ...). When a node's pid is dead it removes the pid file and restarts it. For
  `manager_node`, `data_node`, `laser_slam3_node` and `planner_node` the
  restart command is `cd /usr/navi && ./stop* ; ./start*`, so **killing one of
  these restarts the whole navigation stack**; the other nodes are restarted
  from their old `/proc/PID/cwd` and `cmdline`. In vendor debug mode
  (`/oem/midea_autorun` exists) it does nothing. Found by static analysis,
  not tested; details in
  [room-order-investigation.md](room-order-investigation.md#restarting-manager_node).
- `/oem/test.mod` must stay `FOFF`. Anything else boots the factory test
  stack (`/usr/bin/rk_pcba_test/echo_pcbatest_server`).

## Approaches, least to most invasive

### 1. New programs on the IPC bus

Write a separate program that talks to the existing nodes over the "mass"
IPC (nanomsg + `/dev/shm`), like `camstream`. Vendor code stays untouched.
There are hundreds of topics in `/tmp`, including some that sound like app
features Valetudo may not expose:

| Topic | Why interesting |
|---|---|
| `planner-request-start-point-cruise` | patrol a route (pairs well with camstream) |
| `planner-request-start-find-human` | |
| `planner-request-set-pet-mode` | |
| `planner-request-get-stain-info`, `planner-request-start-stain-clean` | stain detection |
| `recognition2-publish-ai-object` | what obstacle recognition sees |
| `mcu-publish-mcu-status` | raw motor-controller status (mops, sensors) |

**Cost:** each topic's payload layout has to be reverse-engineered, the same
way `VideoFrame` was (find the publishing or handling code, read the struct
offsets). Request/reply topics use `mass_request_create` /
`mass_request_sync` from `libsample_plugin.so`.

### 2. Config overrides

The JSON configs in `/usr/navi` (`planner.json`, `recognition2_node.json`,
`video_node.json`, `common-V15Overseas.json`, ...) are on the read-only
squashfs. From the boot hook, mount an edited copy over the original and
restart that node:

```sh
mount --bind /userdata/override/planner.json /usr/navi/planner.json
```

Reversible by removing the hook and rebooting.

### 3. Intercepting library calls (`LD_PRELOAD`)

A small library loaded ahead of the vendor ones can wrap exported functions
in the vendor shared libraries. This only works for calls that cross a
shared-library boundary. Calls inside the same executable are direct
branches and can't be intercepted this way. The nodes are started by
`start-dushu`, so the launch line has to change (via mount override or debug
mode, below).

### 4. Small binary patches

Copy a node to `/userdata`, change a few bytes (flip a branch, change a
constant), mount it over `/usr/navi/<node>` and restart the node. Good for
targeted fixes. As reversible as option 2. Restart the node by killing it
and letting `track` do it (it restarts every node, see above); the `roomorder`
component does this.

### 5. Midea's debug mode (`/usr/sbin/debug_mode.sh`)

A vendor mechanism for running modified software from `/userdata`:

- `debug_mode.sh start` stops everything, creates `/oem/midea_autorun/`,
  `/userdata/midea/` and `/userdata/install/bin/`, fills `install/bin` with
  **symlinks to every file in `/usr/navi`**, records the firmware version
  (`ls --full-time /etc/versionCode`), and starts the robot software from
  `/userdata/install/bin`.
- At every boot, `S98_lunch_init` calls `debug_mode.sh test`. If debug mode
  is active and the firmware version hasn't changed, it runs `start_app`
  from `/userdata/install/bin` instead of `/usr/navi`.
- So a single component can be replaced by swapping its symlink for a
  modified copy. `debug_mode.sh stop` removes everything again.
- **Catch:** this firmware has `/etc/formal/`, and in that case debug mode
  refuses to start unless `/oem/midea_test/` exists. That directory looks
  like a factory test-mode flag. Find out what else checks for it before
  creating it.
- `debug_prepare` also deletes log files (`*.txt`, `*.ppm`, `*.pgm`, `*.log`,
  `*.log.gz` under `/userdata/logs`).

## Don't touch

- **The main firmware image / kernel.** Reflashing risks a brick, and the
  boot log mentions signature checks (`F1 signature OK`).
- **The motor/sensor microcontroller firmware.** Motors, cliff sensors and
  mops run on a separate MCU. Linux only sends it commands
  (`mcu-request-*` topics).

## Safety

This is a moving machine. Changes near cliff detection, wheel or motor
control, or docking can make it fall down stairs or stall motors. Prefer
approaches that a reboot undoes (1–4), test with the robot supervised, and
leave the vendor watchdogs alone.
