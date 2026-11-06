# Investigation: wide berth around obstacles

**Status:** cause found (static analysis and logs from one clean). Nothing
built or tested yet. Started 2026-11-06.

## Symptom

The robot keeps more distance than needed from obstacles and leaves the
floor right around them uncleaned.

## Summary

For objects the camera recognises (shoes, scales, pet bowls, furniture and so
on), `planner_node` brakes and turns away at a fixed distance that depends on
the object type, measured from the robot's centre:

| Level | Distance (centre) | Gap to the bumper (radius ≈ 175 mm) | Types (planner `AiType`) |
|---|---|---|---|
| 0, 1 | none (types never trigger) | | 5, 9–13, 19–22, 27 |
| 2 | **350 mm** | ≈ 17.5 cm | 1–4, 7, 17, 23, 24, 26, 28, 29, 31, 32, 35–38 |
| 3 | **350 mm** | ≈ 17.5 cm | 0, 14–16, 18 |
| 4 | **400 mm** | ≈ 22.5 cm | 6, 8, 25, 30, 33, 34 (and 9 when a config flag at `PlannerConfig+0x443` is set) |

That 17–22 cm gap is the uncleaned ring around obstacles. The values are
hard-coded, not in `planner.json`, so no setting changes them. The
"AI Obstacle Classification" quirk (normal/smart/super) isn't read on this
path at all.

The type numbers match Valetudo's `AI_OBSTACLE_IDS` (`MideaConst.js`) and the
obstacle images in `/userdata/aiimgs/<type>-…jpg`: 1 shoes, 2 trash can,
3 pet bowl, 4 weighing scale, 5 textiles, 6 entrapping furniture, 7 electric
wire, 8 charging base, 9 feces, 18 pedestal, 24 power strip. The overlap is
consistent with the logs, but that the planner's `AiType` uses the same
numbering is an inference.

## Evidence

### Logs (one clean, 2026-11-06, about 60 k planner lines)

`_updateAIVirtualBumper - ai trigger, type = T , dis = D` is logged only when
`D` < the type's threshold (see the code below). Observed:

| Type | Lines | `dis` range (mm) | Threshold |
|---|---|---|---|
| 3 | 1269 | 272–349 | 350 |
| 4 | 163 | 284–349 | 350 |
| 1 | 39 | 326–349 | 350 |
| 6 | 100 | 357–378 | 400 |

Every maximum sits just below its threshold, so the threshold is what
triggers the turn.

Other avoidance sources in the same log are tighter. Source 1 (probably lidar)
`virtual bumper dis` is 189–262 mm, and `planner.json`
`virtual_bumper_max_distance` is 227 mm.

### Code (`planner_node`, sha256 `8a378562…c47669`)

- `AIMapHelper::Init` (`0x64e0b0`) fills three hash maps:
  - `AiType → VirtualBumperLevel` from the 39 `{type, level}` pairs at
    `0x7e5408`;
  - `VirtualBumperLevel → distance (mm)` from the 5 pairs at **`0x7e5540`**:
    `{0,0} {1,0} {2,350} {3,350} {4,400}`. The 24 bytes from `0x7e5550`
    (`02 00 00 00 5e 01 00 00 03 00 00 00 5e 01 00 00 04 00 00 00 90 01 00 00`)
    occur only once in the file;
  - `AiType → minimum confidence` from `0x7e5568`: 0.6 for every type.

  If `PlannerConfig+0x443` is set, type 9 (feces) is raised to level 4.
- `AIMapHelper::GetFrontVirtualBumperInfo` (`0x64f3c0`) runs only when
  `PlannerConfig+0x440` is set and the mode at `+0x400` is 3. It walks the AI
  rects, computes the distance and bearing from the robot centre, and keeps the
  nearest rect that is within −90°…+60°, has confidence > 0.6 and level > 1,
  and is still unconfirmed (`+0x90` < 0.05). It returns the type, the distance
  and the level's threshold from the table above.
- `VirtualBumperUpdate::_updateAIVirtualBumper` (`0x66a8f0`) stores that and
  logs the trigger when distance < threshold.

`docs/corner-cleaning-investigation.md` maps `+0x440` to
`wf_ai_circular_enable`, which is `false` in `planner.json`. The triggers in
the logs show that the path does run, so either something sets the flag at
runtime or that mapping is off. Not resolved.

### Not the cause

- `c_b` / `r_b` in `_semanticMapCallBack` lines are confidence values from the
  semantic SLAM node, passed through as floats. They aren't buffers.
- Valetudo settings at the time: obstacle avoidance on, AI classification
  "smart", pet avoidance off, Big Object Recognition on, Edge Deep Vacuum on,
  route "deep".

## Possible fix

Patch the level → distance table in a copy of `planner_node` and bind-mount
it over `/usr/navi/planner_node`, the same way `roomorder` handles
`manager_node`: a separate component with its own install and uninstall,
re-applied per firmware version. For example, 350 → 270 and 400 → 320 would
leave a gap of about 9.5 cm and 14.5 cm.

Trade-off: these objects get avoided because the robot shouldn't touch them
(wires, feces, scales it could climb). A lower threshold gives it less room to
stop and turn. The first test should lower only levels 2 and 3, leave level 4,
and watch wires and shoes.

## Open questions

- Large objects of types 1000–1007 (Valetudo shows "Unknown ID 100x", from
  Big Object Recognition) go to `SemanticCostmap2DLayer`, not to this
  virtual bumper. Does that layer keep the coverage path away from them too?
  Cheap test: one clean with Big Object Recognition off, then compare.
- What sets `PlannerConfig+0x440` at runtime?
- Does the planner's `AiType` numbering really match the IDs Valetudo shows?

## Method

Logs: `/userdata/logs/app/planner/planner.*.log*` copied off the robot during
a clean, read-only. Code: Ghidra via REA on `dumps/x2/usr/navi/planner_node`
(same sha256 as the robot's), plus a Python read of the `.rodata` tables.
