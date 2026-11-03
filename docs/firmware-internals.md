# Firmware internals

Findings from a rooted J15 Pro Ultra running Valetudo. They come from static
analysis of the shipped binaries plus observation on the running robot.

Firmware examined: `video_node` build `release_mp_64_hotfix03`
(`474c527ee0a7c6edc9e025f569b81de3e4731a2c`), product config
`common-V15Overseas.json`. Other firmware versions may differ.

## Processes

The robot software lives in `/usr/navi/`. Each `*_node` is a separate process.

| Process | Role |
|---|---|
| `data_node` | sensor data hub |
| `planner_node` | path planning and cleaning tasks |
| `laser_slam3_node` | lidar SLAM |
| `semantic_slam_node` | semantic map (objects, rooms) |
| `manager_node` | top-level robot state |
| `detect_node` | AI obstacle recognition (`recognition2_node.json`), reads `camera_frame` |
| `video_node` | camera capture, H.264 encoder, `media.engine.control` ubus object |
| `media_node` | pushes video to the cloud (Tencent Cloud IoT Video, `iv_*` APIs) |
| `iot_node` | Midea cloud connection |
| `audio_node` | voice prompts |
| `rkaiq_3A_server` | Rockchip auto-exposure, white balance and focus ("3A") daemon (`/etc/init.d/S40rkaiq_3A`) |
| `valetudo` | `/userdata/valetudo` (replacement for the cloud app) |

## Boot hooks

`/etc/init.d/S98_postboot.sh` runs `/oem/_root_postboot.sh` in the background
if that file exists. `/oem` is writable, so this is where custom services
start. `install.sh` adds a single marked line there.

SSH (`S97dropbear.sh`) starts before the hook, so a broken hook can't lock
you out.

## ubus

`ubusd` runs on a **non-default socket**, so every call needs `-s`:

```sh
ubus -s /tmp/ubus.sock list
```

### `media.engine.control` (from `video_node`)

| Method | Arguments | Effect |
|---|---|---|
| `grap_pic` | `{"file_path": "String"}` | save a JPEG from the camera to the given path |
| `start_push` | | start encoding and publishing H.264 on the `camera_stream` topic |
| `stop_push` | | stop it |
| `request_idr` | | ask the encoder for a keyframe |
| `set_bitrate` | `{"bit_rate": Integer}` | change the encoder bitrate |
| `start_ai` / `stop_ai` | | start or stop the AI frame feed (`camera_frame`) |
| `save_raw_video` | | not investigated |

The first `grap_pic` after the camera has been idle can return a black image,
because auto-exposure hasn't settled yet. A second capture is fine.

```sh
ubus -s /tmp/ubus.sock call media.engine.control grap_pic '{"file_path":"/tmp/snap.jpg"}'
```

## "mass" IPC (`/usr/lib/libsample_plugin.so`)

All `*_node` processes talk through Midea's "mass" library. It statically
embeds **nanomsg 1.1.5**. The exported C++ functions have readable mangled
names (`clean_robot::plugin::mass::*`), so other programs can call them.

### Addresses

`mass_generate_url(protocol, topic)`:

| Protocol | URL |
|---|---|
| `ipc` | `ipc:///tmp/<topic>` |
| others (`inproc`, `tcp`) | `<protocol>://<topic>` |

So `ls /tmp` lists every topic: `camera_stream`, `planner-request-*`,
`mcu-request-*`, `slam-2d-*` and so on. They are pub/sub (`NN_SUB` = `0x21`)
or request/reply sockets.

### Shared-memory topics

Large payloads (camera frames) don't go through the socket. The publisher
calls `mass_publish_create_shm(topic, data_size)`, which creates
`/dev/shm/<topic>`:

```
offset 0x00  64-byte header (process-shared pthread mutex, ...)
offset 0x40  slot 0
             slot 1            (2 slots; data_size bytes each)
```

The file size is `2 × data_size + 64`:

| Topic | File size | data_size | Payload |
|---|---|---|---|
| `camera_frame` | 2 097 216 | 1 048 576 | raw frames for `detect_node` |
| `camera_stream` | 3 145 792 | 1 572 864 | H.264 for `media_node` |

For each message, the nanomsg socket carries only a 32-byte descriptor:

```c
struct shm_meta {
    uint64_t timestamp_ms;  // CLOCK_MONOTONIC, ms, when published
    uint64_t offset;        // payload position in /dev/shm/<topic>
    uint64_t length;        // payload length (whole struct, not just the data)
    uint64_t timeout_ms;    // 200; readers drop it if now > timestamp + timeout
};
```

`mass_shm_cpyout_ptr()` checks the timeout and returns `shm_base + offset`.
Subscribers get the descriptor in their callback, not the payload.
Publishers alternate between the two slots, so a slot is overwritten two
frames later. Copy the payload out immediately.

Subscriber API, as used by `camstream`:

```c
// _ZN11clean_robot6plugin4mass25mass_subscribe_create_shmEPKcmPFvPKvmPvE
void *mass_subscribe_create_shm(const char *topic, unsigned long data_size,
                                void (*cb)(const void *data, unsigned long len, void *user));
// _ZN11clean_robot6plugin4mass19mass_subscribe_spinEPNS1_11__subscribeEPv
int mass_subscribe_spin(void *sub, void *user);   // blocks, calls cb per message
```

## Video stream format

`midea::VideoPush::PushProcess` (in `video_node`) fills a
`clean_robot::message::VideoFrame` and publishes the whole struct
(`0x100024` bytes) on `camera_stream`:

| Offset | Type | Field |
|---|---|---|
| `0x00` | | zeroed; partly filled by later code (not investigated) |
| `0x04` | u32 | `1` = the frame doesn't start with an SPS (not a keyframe), `0` = keyframe |
| `0x10` | u32 | H.264 size in bytes |
| `0x24` | u8[1 MiB] | Annex-B H.264 (`00 00 00 01` start codes) |

Encoder settings come from `/usr/navi/video_node.json`: 640×480, up to
20 fps, GOP 60, 0.5–2 Mbps (1 Mbps initial). The config names the camera
`sc1330t`; that label doesn't match the fitted SC035HGS and doesn't affect
anything.

### Path from camera to cloud

```
/dev/video5 ──> video_node (librockchip_mpp H.264)
                    │  start_push (ubus)
                    ▼
        /tmp/camera_stream + /dev/shm/camera_stream
                    │
        ┌───────────┴────────────┐
   media_node                camstream (this repo)
   Tencent IoT Video cloud   raw H.264 over TCP
```

## Logs

| Path | Contents |
|---|---|
| `/userdata/logs/app/<node>/` | glog logs per process (`*.INFO` is a symlink to the latest) |
| `/userdata/logs/crash/coredump/` | backtraces (`*-bt-*`) and cores |
| `/var/log/rkaiq_3A.log` | ISP 3A daemon |
| `/tmp/valetudo.log` | Valetudo |

`/userdata/logs` is a 30 MB tmpfs, so everything in it is lost at reboot.

## Method notes

- Used to find all of the above: `strings` and `llvm-nm -D` on the
  binaries, Hopper and `llvm-objdump` for decompiling and disassembly,
  `ls /tmp /dev/shm` on the robot to see which topics exist and which are
  active, and a dump of the subscriber callback contents.
- The mangled names in `libsample_plugin.so` give exact argument types.
  Return types aren't encoded in a mangled name, so they're inferred from
  the disassembly.
- Vendor log strings are very detailed. Searching them (`strings -a`) is
  usually the quickest way to find the code responsible for something.
