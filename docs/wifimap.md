# wifimap

Records the robot's Wi-Fi signal strength together with its position while it
cleans, and draws a heatmap of it over the Valetudo map. Use it to find where
the signal is weak, for example before moving a router or an access point.
Status: untested.

## What it does

While the robot moves, wifimap reads its position from the planner log (about
once per second) and the signal level (dBm) from `/proc/net/wireless`. It also
notes which access point (BSSID) and channel the robot is connected to. Each
sample is one line in a CSV file in `/userdata/wifimap`, one file per cleaning
job.

A pause longer than 15 minutes in the position updates starts a new job file.
A dock mop wash (a few minutes without movement) stays in the same job. A
sample with no signal (a dead zone, or no connection) is kept and drawn
differently on the heatmap, because those places are exactly what you are
looking for.

`tools/wifimap.py` runs on your computer. It fetches the samples over `ssh` and
the map from Valetudo, and writes one HTML file.

## Requirements

- A rooted J15 with SSH access as `root`.
- No build.
- Python 3 on your computer, for the heatmap. No extra packages.
- Valetudo reachable on the robot's address, for the map.

## Install, status, uninstall

```sh
./install.sh wifimap-install   192.168.1.50 [ssh options]
./install.sh wifimap-status    192.168.1.50 [ssh options]   # running? boot hook? jobs, newest sample, signal now
./install.sh wifimap-uninstall 192.168.1.50 [ssh options]   # keeps the recorded samples
```

Samples are recorded only while the robot moves, so there is nothing to see
until it has cleaned once. Uninstalling keeps the samples; delete them with:

```sh
ssh root@192.168.1.50 rm -rf /userdata/wifimap
```

## Rendering the heatmap

```sh
tools/wifimap.py 192.168.1.50 [ssh options]
```

This writes `wifimap.html` in the current directory; open it in a browser. As
with `install.sh`, anything after the robot address goes to `ssh` unchanged,
and the options of the tool go before the address:

| Option | Default | |
|---|---|---|
| `-o`, `--output FILE` | `wifimap.html` | output file |
| `--cell CM` | `25` | heatmap cell size, in cm of the Valetudo map |
| `--offset-x CM`, `--offset-y CM` | `40`, `5` | where the planner's origin is relative to the dock (see below) |
| `--job latest\|NAME` | all jobs | job shown first, for example `job-1793000000.csv` |
| `--samples DIR` | | read `job-*.csv` from a local folder instead of the robot |
| `--map FILE` | | read the map JSON from a file instead of Valetudo |

With both `--samples` and `--map` the robot address is not needed.

The page shows the floor plan, the dock, and a grid of cells coloured by the
mean signal of the samples in them, from -90 dBm (bad) to -30 dBm (good). Hover
a cell (or touch it on a phone) for its mean, minimum and maximum, the number
of samples and the access points seen. A selector switches between all jobs
merged and single jobs; if more than one access point was seen, you can also
show one at a time. The page follows your light or dark mode setting.

As a rule of thumb, -67 dBm or better is good for video and voice, and -80 dBm
or worse is unreliable. Hatched cells contain samples where the robot had no
signal.

The tool drops samples where the position jumps more than 1.5 m within two
seconds, which is the robot relocalising rather than moving. The summary it
prints shows how many that was.

The generated page contains your floor plan and the MAC addresses of your
access points. Don't publish it.

## Configuration

`/userdata/wifimap.conf` on the robot (kept across reinstalls):

| Setting | Default | |
|---|---|---|
| `INTERVAL_S` | `1` | minimum seconds between two samples |
| `JOB_GAP_S` | `900` | a pause in the position updates longer than this starts a new job |
| `BSSID_EVERY_S` | `10` | how often the access point and channel are looked up |
| `MAX_JOBS` | `100` | job files kept; the oldest are deleted beyond that |
| `FLUSH_S` | `30` | samples are written to flash at most this often |

Restart after editing: reboot, or run `./install.sh wifimap-install <ip>` again
(it keeps your config).

## Data format

`/userdata/wifimap/job-<epoch>.csv`, where `<epoch>` is the start of the job in
Unix time, with a header line:

```
t,x_mm,y_mm,theta_deg,dbm,bssid,freq_mhz
1793000000,-3101,2701,155,-37,74:fe:48:aa:bb:cc,2412
```

- `t`: Unix time of the sample (the robot's clock is UTC).
- `x_mm`, `y_mm`, `theta_deg`: the planner's position in mm, and heading in
  degrees. The origin is the dock.
- `dbm`: signal level; empty when there is no value.
- `bssid`, `freq_mhz`: access point and channel, empty when not connected.

The planner's position becomes a Valetudo map position (in cm) with
`x = dock_x + 40 + x_mm / 10` and `y = dock_y + 5 - y_mm / 10`; the dock is the
charger marker of the map, and the 40 and 5 are `--offset-x` and `--offset-y`.
A job is about 150 kB, so the default 100 jobs take at most 15 MB of flash.

## Limits and caveats

- The robot's radio is 2.4 GHz only, so the map shows only that band.
- The signal is what the robot's antenna sees, close to the floor. A phone in
  your hand may see something different.
- Samples are tied to the current map. After creating a new map or moving the
  dock, old samples no longer line up; delete the old job files on the robot
  (or pick a newer job with `--job`).
- The fit of the planner's coordinates to the Valetudo map is good to a few
  centimetres, much less than a cell.
- Samples are recorded only where the robot goes and only while it moves.
  Cells it never visited are empty.
- Events are seen only while the daemon runs; positions logged while it is
  down are not recorded. Samples buffered for up to 30 seconds are lost if the
  power is cut.

## How it was found

Where the position and signal come from and how they fit the map: wiki page
[wifi-heatmap-investigation](https://github.com/lyarenei/j15-stuff/wiki/wifi-heatmap-investigation).
