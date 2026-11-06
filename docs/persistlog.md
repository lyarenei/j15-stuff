# persistlog

Keeps the robot's logs across reboots, and further back than the firmware
does. Use it when you want to investigate a fault days later (a mop that
didn't lift, a crash). Status: verified on the robot.

## Why

The firmware writes its logs to a 30 MB RAM disk (`/userdata/logs`) and keeps
only the last few files per process. Most nodes cover less than a day, and
everything is gone after a reboot, power loss or watchdog reset.

`persistlog` is a small shell loop on the robot. Every 10 minutes and on
shutdown it copies the logs to flash, in `/userdata/persist-logs`, one folder
per boot. It also saves the previous boot's kernel log from `pstore` when the
robot did a warm reset.

## Requirements

- A rooted J15 with SSH access as `root`.
- No build, and no camstream.

## Install, status, uninstall

```sh
./install.sh persistlog-install   192.168.1.50 [ssh options]
./install.sh persistlog-status    192.168.1.50 [ssh options]   # running? boot hook? store size, saved boots
./install.sh persistlog-uninstall 192.168.1.50 [ssh options]   # keeps the saved logs
```

Install adds a boot hook to `/oem/_root_postboot.sh` and starts the loop. To
delete the saved logs after uninstalling:

```sh
ssh root@192.168.1.50 rm -rf /userdata/persist-logs
```

`./install.sh collect-logs <ip>` includes the saved logs in its tar.

## What is saved

In `/userdata/persist-logs/boot-NNNN/`:

- rotated app logs (`*.log.gz`), copied once each;
- the motor controller log (`ulog_mcu.ulg-*.gz`);
- crash text files and backtraces;
- `*.partial.gz` snapshots of the logs that are still being written, only when
  they changed. A snapshot is deleted once the rotated log has been copied;
- `boot-info.txt` (date, uptime, firmware version, boot id);
- `pstore-previous-boot/`: the kernel log of the previous boot, if the robot
  was reset without losing power.

Boots are numbered, not dated, because the robot's clock can be wrong just
after boot. A restart of persistlog within the same boot carries on in the same
folder.

Never copied: cloud connection logs (they contain credentials), core dumps,
photos, video, and map data. Only a whitelist of file patterns is copied.

## Configuration

`/userdata/persistlog.conf` on the robot:

| Setting | Default | |
|---|---|---|
| `STORE` | `/userdata/persist-logs` | where logs are kept |
| `MAX_MB` | `64` | size cap of the store; the oldest boots are deleted first |
| `MIN_FREE_MB` | `50` | copying pauses while `/userdata` has less free space |
| `INTERVAL` | `600` | seconds between sync cycles |
| `EXTRA_LOGS` | `/tmp/valetudo.log /tmp/camstream.log` | extra text logs to snapshot |

Restart after editing: reboot, or run `./install.sh persistlog-install <ip>`
again (it keeps your config).

## Limits and caveats

- With a 64 MB cap and about 3 MB of rotated logs a day, the store keeps
  roughly 2 to 3 weeks. Less if the robot reboots often.
- On a crash or hard power cut, up to 10 minutes of the active logs are lost.
  Whether the final sync on a clean reboot always finishes is not certain
  (init may kill it quickly). Snapshots are written to a temporary file and
  renamed, so an interrupted sync leaves the previous snapshot intact.
- `pstore` content survives a warm reset only, not a cold power cut.
- Flash wear is negligible: the snapshots add roughly 10 to 40 MB of writes a
  day to a 264 MB NAND volume with wear levelling.
- The robot's clock can read 2017 until it syncs with NTP, so file times right
  after boot can be wrong.

## How it was found

How the firmware rotates logs, how far back the stock logs go and what the
other log sources are: wiki page
[persistent-logs](https://github.com/lyarenei/j15-stuff/wiki/persistent-logs).
