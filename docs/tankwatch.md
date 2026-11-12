# tankwatch

Estimates how full the dock's clean and dirty water tanks are. The dock has no
level sensors, so tankwatch counts the water the logs say was used. Use it to
get a warning before the clean tank runs empty or the dirty tank fills up.
Status: verified on the robot. The constants come from one measured mopping
job, so calibrating them for your dock is recommended (see
[Calibrating for your dock](#calibrating-for-your-dock)).

## What the dock tells you without it

Only binary states: whether each tank is fitted, and a "full" bit for the dirty
tank. An empty clean tank is detected only while a wash is running, when the
dock fails to draw water. Valetudo shows these states (Freshwater `ok` /
`empty` / `missing`, Wastewater `ok` / `full`), but they change only once the
firmware has raised an error, which is too late for a warning.

## How the estimate works

tankwatch follows the robot's `data` and `manager` logs and keeps two running
totals:

- **Clean tank:** water used = the dock's supply flow meter, integrated over
  time, plus the time the robot's onboard tank was refilled.
- **Dirty tank:** water added = how long the dirty pump ran.

It writes the result to `/userdata/tankwatch/state.json`: used mL, capacity,
remaining percent, a low flag and the time of the last reset, per tank. For the
dirty tank the percent is the space left. The totals survive reboots.

The counters reset like this:

- **Dirty tank put back** (taken out and reinserted): dirty counter to 0.
- **Clean tank refilled:** removing the clean tank isn't reported by the dock,
  so you reset it by hand (below).
- **Dock says the dirty tank is full:** the dirty counter is set to the
  capacity, and the estimate it had is appended to
  `/userdata/tankwatch/calibration.log`. That shows how far off the constants
  are.
- **Dock fails to draw clean water:** the clean counter is set to empty, and
  logged the same way, at most once per 10 minutes. This trigger is
  implemented from a string in the firmware and hasn't been seen to fire. If
  the clean level jumps to empty without a real empty tank, report it.

On a first install, tankwatch assumes the clean tank is full and the dirty
tank is empty. If that isn't true, the estimates are off until you next refill
the clean tank and empty the dirty one (and reset them). Installing again over
an existing install keeps the current counters.

## Requirements

- A rooted J15 with SSH access as `root`.
- No build.
- For levels in the Valetudo UI, the [patched Valetudo](valetudo.md).

## Install, status, uninstall

```sh
./install.sh tankwatch-install   192.168.1.50 [ssh options]
./install.sh tankwatch-status    192.168.1.50 [ssh options]   # running? boot hook? state, calibration log
./install.sh tankwatch-uninstall 192.168.1.50 [ssh options]   # keeps the calibration log, renames the state
```

Reset a tank after refilling or emptying it:

```sh
ssh root@192.168.1.50 /userdata/tankwatch.sh reset clean      # or: dirty
```

With the patched Valetudo you can reset the tank from its Consumables page
instead.

## With Valetudo

The patched Valetudo shows the estimates on the Dock panel (for example "~62%
left" for the clean tank, "~26% full" for the dirty one) and as consumables
("Clean Water Tank", "Dirty Water Tank"). A tank flagged low turns its tile
yellow. Resetting a consumable resets the tankwatch counter.

At startup, Valetudo only checks whether the state file exists, to decide
whether to show the consumables; it re-reads the levels whenever the file
changes. After installing or uninstalling tankwatch, restart Valetudo:

```sh
./install.sh valetudo-restart 192.168.1.50
```

The installer prints this reminder when the patched build is installed.
Uninstalling renames `state.json` to `state.json.uninstalled`, so the levels
disappear from Valetudo after its next restart. Installing again creates a
fresh `state.json` and doesn't restore the renamed file.

## Configuration

`/userdata/tankwatch.conf` on the robot (kept across reinstalls):

| Setting | Default | |
|---|---|---|
| `CLEAN_CAPACITY_ML` | `4000` | clean tank size |
| `DIRTY_CAPACITY_ML` | `3400` | dirty tank size |
| `FLOW_ML_PER_UNIT_S` | `0.016667` | mL per unit of the supply flow reading per second (the reading looks like mL/min, so 1/60) |
| `REFILL_ML_PER_S` | `3.1` | mL taken from the clean tank per second of robot tank refill |
| `DIRTY_ML_PER_PUMP_S` | `1.4` | mL moved into the dirty tank per second of dirty pump running |
| `LOW_PCT` | `20` | a tank is low below this percent remaining (clean) or free (dirty) |

Restart after editing: reboot, or run `./install.sh tankwatch-install <ip>`
again (it keeps your config).

The defaults were fitted to one mopping job (clean tank full and dirty tank
empty at the start): 69,730 unit-seconds of flow, 110 s of robot refill and
645 s of dirty pump, which used about 1.5 L of clean water and put about
0.9 L into the dirty tank. The refill constant is a fit to that single job,
not measured separately.

## Calibrating for your dock

Do this after a mopping job, before you touch the tanks.

1. Run `./install.sh tankwatch-status 192.168.1.50` and note `used_ml` for
   the clean and dirty tank.
2. Measure with a measuring jug how much water it takes to fill the clean tank
   back up, and how much is in the dirty tank.
3. Reset the clean tank (`reset clean`, or from Valetudo's Consumables). The
   dirty tank resets when you take it out and put it back.
4. Compare. If the estimates are within about 10% of the measured values, leave
   the constants alone.
5. If not, scale the constants by `measured / estimated`, and edit them on the
   robot:
   - dirty tank off: multiply `DIRTY_ML_PER_PUMP_S`;
   - clean tank off: multiply both `FLOW_ML_PER_UNIT_S` and `REFILL_ML_PER_S`.
6. Restart tankwatch (`./install.sh tankwatch-install 192.168.1.50`).

One job can't tell the flow term from the refill term, so the single factor in
step 5 is a compromise. To separate them, repeat on a second job with a
different number of washes (for example a different room count), collect the
logs with `./install.sh collect-logs 192.168.1.50`, and solve for the two
constants. `tools/tankwatch-replay.sh <log>...` runs data and manager logs
through the same model on your computer and prints the resulting state, so you
can try constants against logs you already have. The manager logs are needed
for the clean-tank-empty trigger.

If the dock reports the dirty tank full or the clean tank empty, check
`/userdata/tankwatch/calibration.log` (shown by `tankwatch-status`): it lists
what the estimate was at that moment.

## Limits and caveats

- Events are seen only while the daemon runs. A restart, reboot or `data_node`
  crash that happens while it is down misses whatever the dock did in between,
  including a tank removal. A pump or refill run in progress when the daemon
  stopped is dropped.
- The clean tank always needs a manual reset after refilling.
- It is an estimate. It does not stop or block a mopping job.
- The model is fitted to one dock and one cleaning pattern. Your wash settings
  (water temperature, wash frequency) may use water differently.

## How it was found

What the dock reports, how the water use was measured and how the model was
fitted: wiki page
[water-tank-investigation](https://github.com/lyarenei/j15-stuff/wiki/water-tank-investigation).
