# Investigation: right mop pad doesn't lift

**Status:** open. Waiting for the next occurrence so its logs can be
captured. Started 2026-11-03.

## Symptom

- Every now and then, the **right** mop pad stays on the floor when it should
  be lifted, typically while the robot travels between cleaning paths.
- Sometimes the pad **stops spinning** while it's stuck down.
- Not reproducible on demand.

"Right" here is as the owner sees it. In the firmware, `left`/`right` are
from the robot's point of view (as if you were riding on it, facing
forward). Confirm which side the firmware calls it before reading the logs.

## What we know

### Lifting is commanded together with stopping the spin

Every lift in the planner logs is the same sequence:

```
MopCommand::HandleMopUpDown - set motor action UP
MopCommand::SetMopSpeed - SetMopSpeed type=2 ... speed=0
MopCommand::SetTurnPlateRaise - use_direct_mop_lift_interface   (or "TurnPlateRaise 1")
MopCommand::SetMopLiftUpInplace - mopLiftUpInplace changed ->[1]
```

Lowering is `set motor action DOWN` followed by `mop_speed:200` and a spin
speed of 200.

**What this means:** a pad that stays down **and stops spinning** received
the lift command. The spin-stop half arrived and worked, but the pad didn't
physically rise. That points to the lift mechanism, or to the motor
controller failing to execute or check the lift. The planner's
decision-making looks fine. A pad that stays down **while still spinning**
would be a different bug: the planner never asked for a lift.

### State reporting from the motor controller

The planner receives per-side lift status and logs every change:

```
MotionData::_checkMopStatus - left_mop_lift_state:N
MotionData::_checkMopStatus - right_mop_lift_state:N
MopCommand::ProcMopStatus - left turnPlate status change A -> B
```

Values seen in the logs (meanings inferred, **not confirmed**):

| Value | Seen | Probable meaning |
|---|---|---|
| 0 | both sides, between actions | idle / no action in progress |
| 1 | both, right after a raise command | raising |
| 4 | both, after 1 | raise finished |
| 2 | both, after a lower command | lowering |
| 5 | both, after 2 | lower finished |
| 3 | **left only** (9×), after 1, followed by `is_mop_retract_up_action_finish:1` | unknown; appears in normal-looking flows |

These look like **action status**, not pad position. The left side usually
returns to 0 after finishing; the right side often stays at 4 or 5. So a
"0" doesn't mean "down".

`data_node` also logs per-side flags, which may be real position sensing:

```
[CHAIO] _procDataRelatedElectronicTask-cam_inout_status=0,mop_inout_status=1,left_mop_lift_up=0,right_mop_lift_up=1
```

### The planner's state translation tables

`planner_node` translates motor-controller enums to its own through
`std::unordered_map`s, built from static pair arrays. Read from
`planner_node` (sha256 `8a378562…c47669`):

| Map | Address | Entries (MCU → planner) |
|---|---|---|
| `MCU::MopLiftState` → `PlannerMopLiftState` | `0x81a1c0` | `0→0, 1→1, 2→2, 3→3, 4→4, 1→1, 5→5` |
| `MCU::MopStretchState` → `PlannerMopStretchState` | `0x81a1f8` | `0→0` … `12→12` |

- The lift table has **a duplicate `1→1`** (7 entries for 6 values).
  `unordered_map` ignores duplicates, so it's harmless. It may be a typo for
  an intended seventh value, but the logs contain no
  `left/right_mop_lift_state error=` lines, so the controller hasn't sent an
  unknown lift value in the logs we have.
- Unknown values are logged as `PlannerNode::_toPlannerMcuStatus -
  <field> error=<value>`.

### Side finding: unknown stretch state 13

The right pad also sits on an arm that swings out for edge cleaning (the
"stretch" or "expend" mechanism). The controller sometimes reports **stretch
state 13**, which the table doesn't contain. The planner then logs
`mop_stretch_state error=13` about 100 times in roughly a second.

- It happened 11 times in the logs from 2026-09-27 to 2026-11-02, out of about
  51 retractions, always during the 4 → 0 transition.
- In every logged case the arm then carried on normally (`0 → 11 → 12 → 6`).
- Most likely a state from a newer controller firmware that the planner
  doesn't know about. **Probably unrelated** to the lift problem, but worth
  checking whether it coincides with a failure.

Observed stretch sequences (meanings unconfirmed):

```
set mop expend=3  →  0 → 5            (start extending?)
set mop expend=1  →  5 → 1 → 2        (extended?)
set mop expend=2  →  … → 4 → 0 → 11 → 12 → 6   (retract, then lock/lift?)
also seen: 6 → 8 → 9 → 10 → 4
```

`data_node` has a `mop_retract_lock_action` state machine for this arm
(`RightMopRetractLock`, `RightMopRetractLockAndUp`) with its own timeout
handling (`... Action Timeout Transit Stop`).

### Not a fault

`WFMotionFSM::react - mop fail, change to Circular` appears hundreds of times.
It's the wall-follow logic falling back when it can't use the edge-mopping
mode (`WFMopping::_enterStart - 01 cannot find special mop env`), not a
hardware failure.

## Next steps

1. **Mechanical checks (cheap).** Remove the right pad and holder; look for
   hair around the spindle and dirt in the lift mechanism.
2. **Swap test.** If the pads or holders fit either side, swap them. A
   fault that moves with the pad means pad or holder; a fault that stays on
   the right means the lift mechanism.
3. **Catch the next occurrence.** Before rebooting, note the time and what
   the robot was doing, then run:
   ```sh
   ./install.sh collect-logs <robot-ip> [ssh options]
   tools/mop-timeline.py j15-logs-*.tar --around "MMDD HH:MM" --window 3
   ```
4. **Questions to answer from those logs:**
   - Was the raise commanded (`set motor action UP`, `speed=0`)?
   - Did the controller report the raise as finished for that side
     (`..._mop_lift_state:4`) even though the pad stayed down? If yes, it
     has no reliable way to detect the failure. A software workaround (a
     watcher that retries the lift) would be the only option, and only if a
     usable feedback signal exists (check `right_mop_lift_up` in `data_node`).
   - Or did it report something else (3? a timeout? an unknown value)? Then
     the planner may be ignoring a real failure, which could be fixable.
   - Did a `mop_stretch_state error=13` burst happen at the same time?

## Where things are

| What | Where |
|---|---|
| Planner logs | `/userdata/logs/app/planner/planner.*.log[.gz]` (RAM, lost at reboot) |
| Data logs | `/userdata/logs/app/data/data.*.log[.gz]` |
| Timeline tool | [`tools/mop-timeline.py`](../tools/mop-timeline.py) |
| Mop commands to MCU (IPC topics) | `mcu-request-set-mop-lift-module-raise`, `mcu-request-set-mop-motor-action`, `mcu-request-set-mop-speed`, `mcu-request-set-mop-control-right`, `mcu-request-set-turnplate-speed` |
| Relevant classes | `planner_node`: `MopCommand`, `MotionData::_checkMopStatus`, `PlannerNode::_toPlannerMcuStatus`, `PNPNaviMotion::_set_mop_lift`; `data_node`: `mop_retract_lock_action::*`, `device_node::MopInOutState` |
