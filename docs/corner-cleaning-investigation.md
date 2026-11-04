# Investigation: cleaning closer into corners

**Status:** mapped, nothing tested yet. Testing is blocked because the robot is
currently inoperable (2026-11-04). Started 2026-11-04.

## Question

Can the robot clean corners better, or is corner behaviour fixed in the
firmware?

## Summary

- Corner and edge behaviour isn't hard-coded. The wall-follow code in
  `/usr/lib/libmotion.so` has several special corner and edge routines, each
  behind a flag. The flags come from `planner.json` (`wall_follow.common`)
  and some can be overridden at runtime through the cloud protocol.
- **Vacuum-only cleans:** the "edge deep vacuum" routine is off, and has been
  off in every saved log. Valetudo can already turn it on: its
  **"Collision-avoidant navigation"** switch sends exactly this setting
  (toggle `0x31`). The firmware applies it only when the robot is vacuuming
  without mopping.
- **Mopping cleans:** the corner routine already runs (`edge_deep_cleaning`
  follows the mop extension switch). The logs show it finding inner right
  angles.
- The firmware also has an inner-corner manoeuvre that uses a swing-out
  side brush (`wf_side_brush_action_enable`). The J15 Pro Ultra has no such
  brush (only the J15 Max Ultra does), so it doesn't apply here.
- "Fish tailing" (`wf_fish_tailing_enable`, `false`) also exists in the code
  but can't be switched from the app protocol on this firmware. Turning it
  on means a changed `planner.json`, see [Options](#options).

Everything below is static analysis of the binaries listed in
[research-workflow.md](research-workflow.md#binaries-examined), plus the
saved planner logs (2026-09-27 to 2026-11-02). None of the switches has been
tested on the robot yet.

## How a corner setting reaches the wall-follow code

```
app / Valetudo
   │  MSmart SETTING 0x9C (SET_VARIOUS_TOGGLES), payload [toggle_id, value]
   ▼
manager_node  CIotCommunicationHandler::handleIotMsg0x02_0x9C
   │  saved in CommonSettingWrap ("edge-deep-vacuum", ...)
   │  CCentralController::_updatePlannerSwitchForSweepMopMode
   │  (sends each flag only in the matching cleaning mode)
   ▼
planner_node  PlannerCore::Enable* → PlannerRuntime::SetEnable*
   │  overwrites the planner.json value in PlannerConfig,
   │  then PlannerConfig::set_motion_wallfollow_config
   ▼
libmotion.so  MotionConfig (singleton) → wall-follow state machines
```

### The 0x9C toggle IDs

`handleIotMsg0x02_0x9C` (`manager_node` `0x81d390`) reads the toggle ID
from frame byte 13 and the value from byte 14. It looks the ID up in a
`std::map<uint8_t, switchType>` built in `main` from a static table at
`0xac9440` (46 pairs), then jumps through a table at `0xac8920`. On this
firmware every ID maps to the same number as its case, and unsupported IDs
get an error reply.

Corner and edge related IDs (handler addresses are the jump table targets):

| ID | Handler | Setting | Valetudo capability |
|---|---|---|---|
| `0x26` | `0x81f2c0` | mop extension (`SetMopExtendSwitch`) | MopExtensionControl |
| `0x2e` | `0x81f1a0` | gap deep cleaning (`SetGapDeepCleaningSwitch`) | MopTwistControl (V2) |
| `0x2f` | `0x81f1e8` | furniture legs (`SetFurnitureLegsCleaningSwitch`) | MopExtensionFurnitureLegHandlingControl |
| `0x31` | `0x81f230` | **edge deep vacuum** (`CommonSettingWrap` key `edge-deep-vacuum`, log `switch edge deep vacuum:%d`) | **CollisionAvoidantNavigationControl** |
| `0x16` | none | not supported on this firmware (Valetudo calls it `SUPER_TAIL_FLICK_CLEANING`) | MopTwistControl (V1, not used on the J15 Pro) |

Valetudo code read on 2026-11-04 (Hypfer/Valetudo `06cfc72`):
`backend/lib/robots/midea/capabilities/MideaCollisionAvoidantNavigationControlCapability.js`
enables with `[0x31, 0x01]` and reads `edge_deep_vacuum_switch` from the
status. Enabling Valetudo's switch turns **on** edge deep vacuum. The name
suggests careful driving, but the firmware routine it turns on is the
closer-to-the-wall behaviour described below. The setting is per robot, not
per clean.

### Which flags reach the planner, and when

`CCentralController::_updatePlannerSwitchForSweepMopMode` (`0x77cc50`)
sends one `FlagMode` per setting. It checks `SweepMode::IsInSweep()` /
`IsInDrag()` on each send:

- **Edge deep vacuum** (`FlagMode` 19, stored at `CCentralController+0x7c5`
  by `_edgeDeepVacuumAction`): sent as the stored value when the robot is in
  vacuum-only mode, otherwise as `0`.
- **Mop extension, edge deep cleaning, gap, furniture legs** (`FlagMode`
  13–16): sent as the stored value only while mopping.

The saved logs match. `enable_mop_extend`, `enable_edge_deep_cleaning`,
`enable_gap_deep_cleaning` and `enable_legs_deep_cleaning` flip to `1` when
a mopping clean starts and back to `0` afterwards. `enable_edge_deep_vacuum`
is `0` in all 50 log lines.

### Runtime overrides of `planner.json`

`PlannerRuntime::SetEnable*` writes straight into `PlannerConfig`, at the
same offsets `WallFollowConfig::LoadConfig` (`0x5951c0`) fills from
`planner.json`. Runtime switches therefore override the JSON values. If
`IsFastRouteActive()`, the value is cached and applied later.
`set_motion_wallfollow_config` (`0x5707a0`) then copies it into
`MotionConfig`.

| `planner.json` key (`wall_follow.common`) | Stock value | `PlannerConfig` | `MotionConfig` | Runtime switch |
|---|---|---|---|---|
| `wf_mop_control_enable` | `true` | `+0x438` | `+0xad` | `SetEnableMopExtend` |
| `wf_obs_wheel_action_enable` | absent | `+0x439` | `+0xb7` | `SetEnableObsWheelControl` |
| `wf_side_brush_action_enable` | **absent** | `+0x43a` | `+0xb6` | none |
| `wf_legs_circular_enable` | `false` | `+0x43d` | `+0xae` | `SetEnableLegsDeepCleaning` |
| `wf_fish_tailing_enable` | `false` | `+0x43e` | `+0xaf` | `SetEnableSwingTailCleaning` (no manager sender found) |
| `wf_gap_mop_enable` | `false` | `+0x43f` | `+0xb0` | `SetEnableGapDeepCleaning` |
| `wf_ai_circular_enable` | `false` | `+0x440` | `+0xb1` | none |
| `wf_edge_deep_cleaning_enable` | `false` | `+0x441` | `+0xb2` | `SetEnableEdgeDeepCleaning` |
| `wf_edge_deep_vacuum_enable` | `false` | `+0x442` | `+0xb3` | `SetEnableEdgeDeepVacuum` |

The stock JSON leaves these `false` because the app switches set them at
runtime. A missing key probably reads as `false`: the loader clears the
default before each `GetJsonVal<bool>`, but this hasn't been checked any
further.

## What the routines do (`libmotion.so`)

`MotionConfig` lives in `planner_node`. `libmotion.so` reaches it through
the GOT slot at `0x1faae8`.

### Edge deep vacuum (`MotionConfig+0xb3`)

- `BackwardMotion::_enterBackward` (`0x1242a0`) calls
  `_isEdgeDeepVacuumTrigger` (`0x123f40`). When that's true, it logs
  `edge deep vacuum occur,backward 25 mm` and backs off only 25 mm, instead
  of the usual distance for a virtual (lidar) bumper.
- The trigger needs the flag on, a lidar **virtual bumper** during wall
  follow, and `WallFollowDataMngr::IsEdgeDeepVacuumTrigger` (`0x142f80`).
  That function fits a line to lidar points 175–280 mm away in the front
  ±29° and accepts the event if the line is roughly perpendicular to the
  robot (|angle| within 0.1 rad of 90°) and a side wall is perceived
  (`GetSideWallPerceptionResult`). In other words, it fires when the robot
  meets a wall head-on while following another wall: an inner corner.
- `MoppingMotion::_enterStart` (`0x1673e0`) also uses it to choose a corner
  manoeuvre when the robot isn't mopping (log prefix `10`):
  - outer right angle → `10 A` (manoeuvre type 1);
  - inner right angle → `10 C` (type 3), **only if**
    `wf_side_brush_action_enable` is on (`MotionConfig+0xb6`) and a motion
    check returns false (not identified);
  - otherwise `10 cannot find special mop env`.

  So with stock `planner.json`, edge deep vacuum gives the shorter back-off
  at inner corners, plus the outer-corner manoeuvre. The inner-corner
  manoeuvre also needs `wf_side_brush_action_enable`, a swing-out side brush
  that the J15 Pro Ultra doesn't have (see [Side brush hardware](#side-brush-hardware)).

### Edge deep cleaning with the mop (`MotionConfig+0xb2`)

- In `MoppingMotion::_enterStart`, the mop corner mode is
  `edge_deep_cleaning && WallFollowDataMngr::GetMopExtendEnv() && arg`.
- Log prefixes: `01` = mop corner mode only, `10` = vacuum only, `11` = both,
  `00 f` = neither.
- Also read by `WallFollowMotion::_checkEdgeDeepActionEnable` (`0x16b5b0`)
  and `TrackingMotion::_runonceTrackWallState`.
- Seen in the logs: `01 A` 16×, `01 B` 41×, `01 cannot find special mop env`
  240×, `find inner right angle` 56×, `entry InnerRightAngleState` 41×, plus
  `_forwardLeaveConner` / `_recoverPose` steps. No `10` or `11` lines, which
  is consistent with edge deep vacuum always being off.

### Others

| Flag | Read by | Notes |
|---|---|---|
| `fish_tailing` | `WallFollowDecision::GetTrackingValue`, `FindwallFSM::RotateByDegreeState::react`, `TrackingMotion::_runonceTrackWallState`, `WFCircularMotion::_renewCrossObsByLegsEvents` (`fish tail action trigger`) | changes the wall-tracking value, so probably how close the robot follows the wall. Not looked at in detail |
| `gap_mop` | `WallFollowDataMngr::GetIsGapEnvStatus`, `FindwallFSM::RotateByDegreeState::react` | |
| `legs_circular` | `WFCircularMotion::_isNeedLegsCircular` | |
| `ai_circular` | `TrackingMotion::_isVirtualBumperTrigger`, `WallFollowDecision::_ableCrossAIObstacle` | |

### Side brush hardware

`planner_node` has `BrushCommand::SetExtendSideBrushAction` /
`SetBrushStretchAction` (called from `MotionManager::Run` via
`SendBrushAndObsWheelCommandToMcu`). `data_node` has a
`side_brush_right_control` mission server, right side brush angle
calibration (`_sideBrushRightBrushAngleTo45`, `CalibrationManager`) and the
topic `mcu-request-set-right-side-brush-raise`. `manager_node` knows the
errors `ERROR_CONTRACT_SIDE_BRUSH_RIGHT` and `ERROR_BUMPER_SIDE_BRUSH_RIGHT`.
The code supports a right side brush that swings out.

**The J15 Pro Ultra doesn't have it.** The extending side brush is a
feature of the J15 Max Ultra (confirmed by the owner, 2026-11-04). The
firmware is shared between models, and the saved logs contain no side brush
angle feedback and no `BrushCommand` lines, which fits. Keep
`wf_side_brush_action_enable` off on the Pro Ultra. That rules out the
`10 C` inner-corner manoeuvre in vacuum-only mode.

## Options

1. **Turn on Valetudo's "Collision-avoidant navigation" switch.** No patch
   needed. It enables edge deep vacuum for vacuum-only cleans. It's the
   safest first test.
2. **Override `planner.json`** with a bind mount over `/usr/navi/planner.json`
   (as planned for `manager_node`, see
   [room-order-investigation.md](room-order-investigation.md#packaging-planned)).
   Changes to try one at a time:
   - `wf_fish_tailing_enable: true`;
   - the lidar wall-tracking distances (`wf_lidar_crtl_SET_DISTANCE` 200,
     `wf_lidar_tracking_value` 190, `virtual_bumper` distances 170–227 mm):
     smaller values bring the robot closer to walls. This is riskier: more
     bumps and getting stuck.

   Keys that a runtime switch controls (edge deep vacuum and cleaning, gap,
   legs, mop extension) are overwritten by the switch, so set those through
   Valetudo instead. `planner_node` has to be restarted after mounting.
3. **Patching `libmotion.so` / `planner_node` code.** Not needed for any of
   the above.

## Verification

1. Note the current value: `GET_STATUS` → `edge_deep_vacuum_switch` in
   Valetudo, or the `planner` log line
   `PlannerCore::EnableEdgeDeepVacuum - [receive] enable_edge_deep_vacuum=`.
2. Turn on Collision-avoidant navigation and run a **vacuum-only** room
   clean. Expect `enable_edge_deep_vacuum=1` at the start, then
   `edge deep vacuum occur,backward 25 mm` and `WFMopping::_enterStart - 10 ...`
   lines at corners.
3. Compare the corners against a clean with the switch off (same room).

## Where things are

| What | Where |
|---|---|
| 0x9C handler | `manager_node` `CIotCommunicationHandler::handleIotMsg0x02_0x9C` (`0x81d390`), ID table `0xac9440`, jump table `0xac8920` |
| Mode gating | `manager_node` `CCentralController::_updatePlannerSwitchForSweepMopMode` (`0x77cc50`), `_edgeDeepVacuumAction` (`0x77d910`) |
| Runtime → config | `planner_node` `PlannerRuntime::SetEnableEdgeDeepVacuum` (`0x5bcb50`) and siblings, `PlannerConfig::set_motion_wallfollow_config` (`0x5707a0`), `WallFollowConfig::LoadConfig` |
| Corner routines | `libmotion.so` `BackwardMotion::_enterBackward`, `_isEdgeDeepVacuumTrigger`, `WallFollowDataMngr::IsEdgeDeepVacuumTrigger`, `MoppingMotion::{_enterStart, _isInnerRightAngleEnv, _isOuterRightAngleEnv, _isArrivedConner}` |
| Planner logs | `/userdata/logs/app/planner/planner.*.log[.gz]` (`[COV] WFMopping`, `WFBackwardMotion`, `PlannerCore::Enable*`) |
| Valetudo | `MideaCollisionAvoidantNavigationControlCapability.js`, `MideaMopTwistControlCapabilityV2.js`, `MideaMopExtension*.js` |
