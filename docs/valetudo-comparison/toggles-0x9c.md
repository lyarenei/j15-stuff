# SET_VARIOUS_TOGGLES (MSmart SETTING 0x9C): firmware vs Valetudo

Firmware: `manager_node` sha256 049e9d56…50da. The handler is `CIotCommunicationHandler::handleIotMsg0x02_0x9C` at `0x81d390`.
Valetudo: Hypfer/Valetudo `06cfc72`. Paths below are relative to `backend/lib/`.
This is static analysis only. The saved logs contain no 0x9C or IoT-switch lines, so nothing here is confirmed at runtime.

## How the handler works

- Frame byte 13 (Valetudo payload `[aa 01 9c id val]`, index 3) is the id, and byte 14 is the value. Payload index p equals frame offset minus 10.
- The id is looked up in the `std::map<u8,u8>` built from `0xac9440`, which holds 46 byte pairs with id == case. The handler then jumps through the int16 table at `0xac8920`.
- The reply is `RespIotCmd<int,u8,u8>(2, 0x9c, result, id, value)`, where result `w27` is 0 for OK and 1 for error. Ids missing from the map, and table slots pointing at `0x81d528`, get result=1.
- **Valetudo ignores the result byte.** `BEightParser.js:24-38` has no case for typeId 0x9C. A rejected toggle (unknown id or out-of-range value) therefore fails silently (likely).
- If frame byte 11 bit 4 is set (Valetudo sends `0x01`, so it isn't), the handler pushes a status (`UpToIotMsg0x04_0x01`) after replying. It also passes `w26==5` into `SetChildLockMode`.

### Where the stored values live (needed for the readback checks)

`CommonSettingWrap` stores settings as a byte array indexed by key. I recovered the indices from the ctor `0x7e1fa0` and checked them against 10 known offsets:

`0 live-photo-switch, 1 ai-avoidance, 2 collect-dust-mode, 3 goback_wash_area, 4 volume, 6 save-map, 7 carpet-detect, 8 carpet-evade, 9 carpet-evade-adaptive, 10 continuous-clean, 11 initial_childLock_switch, 12 verfiction-map, 13 beautify_map_grade, 14 carpet-strategy, 15–18 carpet-setting-*, 19 recognition, 20 super-obstacle, 21 stain-clean, 22 pet-mode-switch, 23 big-object-switch, 24 bridge-boost, 25 childLock-followDND-switch, 26 cross-bridge, 27 cuthair-super-switch, 28 edge-deep-vacuum, 29 enable_telnet, 30 exhibition-mode, 31 threshold-detect, 32 curtain-detect, 33 stain-recog-method`

Two components keep a copy of this array:

| Copy | Base address | Field = base + index |
|---|---|---|
| `CIotCommunicationHandler` | `+0x124` | e.g. `+0x125` ai-avoidance, `+0x140` edge-deep-vacuum |
| `CCentralController` | `+0xd98` (`_settingCallback` `0x795ae0` copies it out to `+0x7xx` fields) | e.g. `+0x7a8`/`+0x7a9` ← index 8/9, `+0x7be` ← 20, `+0x7c5` ← 28 |

## (a) All firmware 0x9C ids

The "Valetudo use" column covers every 0x9C sender in Valetudo. "Reg?" means registered on `MideaJ15ProUltraValetudoRobot` (directly or through `MideaModernValetudoRobot`).

| id | Firmware meaning (log string / callee / key) | Values accepted | Valetudo use | Reg? | Mismatch? |
|---|---|---|---|---|---|
| 0x00 | "smart breakpoint clean" → key `continuous-clean`; skipped if unchanged | 0–1 | – | – | – |
| 0x01 | "child lock mode" → `SetChildLockSwitchUserSetting` + `SetChildLockMode`; skipped if unchanged | 0–1 | KeyLockCapabilityV2 | yes | no |
| 0x02 | "child lock follow DND" → key `childLock-followDND-switch`; adjusts child lock if DND silent | 0–1 | – | – | – |
| 0x03 | unsupported (not in map) | – | – | – | – |
| 0x04 | "station inject fluid" → `SetStationInjectFluidSwitch` | 0–1 | – | – | – |
| 0x05 | "station inject soft fluid" → `SetStationInjectFluid2Switch` | 0–1 | – | – | – |
| 0x06 | in map, but the case is a no-op returning OK (`0x81fb94`) | any | – | – | – |
| 0x07 | "carpet evade" → key **`carpet-strategy`** = (v==1 ? 1 : 3). Not the `carpet-evade` key | 0–1 | CarpetSensorModeControlCapabilityV1 (AVOID=1/OFF=0) | no (J12 Ultra only) | yes, M5 (not J15PU) |
| 0x08 | "Stain Clean" → key `stain-clean`; skipped if unchanged | 0–1 | Quirk STAIN_CLEANING | yes | no |
| 0x09 | "AI Obstacle" → key `ai-avoidance` (same key as 0x2c) | 0–1 | – (Valetudo uses 0x2c) | – | – |
| 0x0a | "Cross Bridge" → key `cross-bridge` | 0–1 | – | – | – |
| 0x0b | "Camera Led" → `SetCameraLedSwitch` | 0–1 | CameraLightControlCapability | yes | no |
| 0x0c | "3D MAP" → `Set3DMapSwitch` | 0–1 | – | – | – |
| 0x0d | "10s exit docker" → `SetStationFirstFastWash` | 0–1 | – | – | – |
| 0x0e | "PetModeSwitch" → key `pet-mode-switch` | 0–1 | PetObstacleAvoidanceControlCapability | yes | no |
| 0x0f | "Recognition" (AI master switch) → key `recognition`. **v=0 also forces `ai-avoidance`=false** | 0–1 | Used inside ObstacleAvoidanceControl.enable() (sets 1 if off) | yes (indirect) | no (side effect noted) |
| 0x10 | "StationSelfFluid2" → `SetStationSelfFluid2Switch` | 0–1 | – | – | – |
| 0x11 | "SlamNodeVersion" → `SetSlamVersion`, `sync()`, early reply, then `SetLDSReboot` | 0–1 | – | – | – |
| 0x12 | "HotDryChargePlate" → `SetHotDryChargePlateSwitch` | 0–1 | – | – | – |
| 0x13 | "telnet" → key `enable_telnet` | 0–1 | – | – | – |
| 0x14 | "mop auto dry" → `SetMopAutoDrySwitch` (CC+0x7b9, `mop-auto-dry`, station) | 0–1 | MopDockMopAutoDryingControlCapability | yes | no |
| 0x15 | "Super Obstacle" → key `super-obstacle`; skipped if unchanged | **0–2** | Quirk AI_OBSTACLE_CLASSIFICATION (off=0/high=1/normal=2) | yes | **labels, M2** |
| 0x16 | unsupported | – | MopTwistControlCapabilityV1 ("SUPER_TAIL_FLICK_CLEANING") | no (J12 Ultra only) | M6 (not J15PU) |
| 0x17 | "rotate interval" → `CC::SetRotationInterval` + `RotateAction::SetRotationInterval`. **No range check** | any u8 | – | – | – |
| 0x18 | "pound sign mode" → `SetPoundSignSwitch` | 0–1 | – | – | – |
| 0x19–0x1b | unsupported | – | – | – | – |
| 0x1c | "[IOT]switch bridge boost" → key `bridge-boost` | 0–1 | Quirk BRIDGE_BOOST ("Threshold Boost") | yes | no |
| 0x1d | "narrow zone recharge" → `SetNarrowZoneRechargeSwitch` | 0–1 | – | – | – |
| 0x1e | "verfiction map" → key `verfiction-map` | 0–1 | – | – | – |
| 0x1f | "[IOT]Exhibition mode" → key `exhibition-mode` | **0–5** | – | – | – |
| 0x20 | unsupported | – | – | – | – |
| 0x21 | "WakeUpSwitch" → `SetWakeUpSwitch` | 0–1 | – | – | – |
| 0x22 | "AICarpetAvoidance" → `SetAICarpetAvoidSwitch` | 0–1 | – | – | – |
| 0x23 | "carpet evase adaptive" → key **`carpet-strategy`** = (v!=0 ? 3 : 1). Same setting as 0x07 with the polarity inverted | 0–1 | – | – | – |
| 0x24 | "stuck mark" → `SetStuckMarkSwitch` | 0–1 | – | – | – |
| 0x25 | unsupported | – | – | – | – |
| 0x26 | "mop extend" → `SetMopExtendSwitch` (sent to the planner only while mopping) | 0–1 | MopExtensionControlCapability | yes | no |
| 0x27 | "zigzag to end" → `SetZigzagToEndSwitch` | 0–1 | – | – | – |
| 0x28–0x2b | unsupported | – | – | – | – |
| 0x2c | "switch ai avoidance" → key `ai-avoidance`; written even if unchanged | 0–1 | ObstacleAvoidanceControlCapability | yes | no |
| 0x2d | unsupported | – | – | – | – |
| 0x2e | "gap deep cleaning" → `SetGapDeepCleaningSwitch` (mopping only) | 0–1 | MopTwistControlCapabilityV2 | yes | naming only, M3 |
| 0x2f | "furniture legs cleaning" → `SetFurnitureLegsCleaningSwitch` (mopping only) | 0–1 | MopExtensionFurnitureLegHandlingControlCapability | yes | no |
| 0x30 | unsupported | – | – | – | – |
| 0x31 | "edge deep vacuum" → key `edge-deep-vacuum` (applied to the planner only in vacuum-only mode) | 0–1 | CollisionAvoidantNavigationControlCapability | yes | **yes, M1** |
| 0x32 | "big object AI recognize" → key `big-object-switch` | 0–1 | – | – | – |
| 0x33 | "middle goback dust" → `SetMiddleGobackDustSwitch` | 0–1 | AutoEmptyDockAutoEmptyIntervalControlCapabilityV3 (FREQUENT ⇒ 1, else 0) | yes | no |
| 0x34 | "fall down detect" → `SetFallDownDetectSwitch` | 0–1 | – | – | – |
| 0x35 | "live photo" → key `live-photo-switch` | 0–1 | ObstacleImagesCapability | yes | no |
| 0x36–0x38 | unsupported | – | – | – | – |
| 0x39 | "stain recog method" → key `stain-recog-method` + `BlackBoard::Set` | **0–3** | – | – | – |
| 0x3a | "threshold detect" → key `threshold-detect` | 0–1 | Quirk THRESHOLD_RECOGNITION | yes | no |
| 0x3b | "curtain detect" → key `curtain-detect` | 0–1 | – | – | – |
| 0x3c | "adb pull" → `BlackBoard::Pub("GOLBAL::adb_pull_switch")` | 0–1 | – | – | – |
| 0x3d | unsupported | – | – | – | – |
| 0x3e | "stain detect" → `CCentralController::HandleStainDetect(bool)` | 0–1 | – | – | – |

Case addresses come from the jump table (target = `0x81d554 + 4*entry`), for example `0x15`→`0x81e580`, `0x23`→`0x81ed14`, `0x31`→`0x81f230`. The full list is reproducible from the int16 table at `0xac8920`.

### Readback check (Valetudo field → GET_STATUS 0x01 bit → what the firmware actually puts there)

The status builder is `handleIotMsg0x03_0x01` at `0x815eb0`.

| Valetudo getter | Field (BEightParser.js line) | Status bit | Firmware source | OK? |
|---|---|---|---|---|
| KeyLockV2 | `child_lock_enabled` (386) | p45 b0 | `GetChildLockMode()` | yes |
| CameraLight | `camera_led_switch` (405) | p53 b3 | `GetCameraLedSwitch()` | yes |
| ObstacleAvoidance | `ai_avoidance_switch` (448) | p68 b3 | IoT `+0x125` = `ai-avoidance` (also mirrored in p53 b1 `ai_obstacle_switch`) | yes |
| ObstacleAvoidance precheck | `ai_recognition_switch` (410) | p53 b5 | `GetRecognitionSwitch()` = CC+0x7b5 ← `recognition` | yes |
| MopAutoDrying | `mop_auto_dry_switch` (420) | p56 b4 | vtable+0x1e0 = `GetMopAutoDrySwitch()` (CC+0x7b9) | yes |
| PetObstacleAvoidance | `pet_mode_switch` (397) | p50 b7 | `GetPetModeSwitch()` = CC+0x7b7 ← `pet-mode-switch` | yes |
| MopTwistV2 | `gap_deep_cleaning_switch` (449) | p68 b4 | `GetGapDeepCleaningSwitch()` | yes |
| FurnitureLeg | `furniture_legs_cleaning_switch` (450) | p68 b5 | `GetFurnitureLegsCleaningSwitch()` | yes |
| CollisionAvoidantNav | `edge_deep_vacuum_switch` (451) | p68 b7 | IoT `+0x140` = `edge-deep-vacuum` | yes (the bit matches; the meaning doesn't, see M1) |
| ObstacleImages | `obstacle_image_upload_switch` (462) | p70 b3 | IoT `+0x124` = `live-photo-switch` | yes |
| MopExtension | `mop_extend_switch` (442) | p65 b5 | `GetMopExtendSwitch()` | yes |
| AutoEmpty V3 | `frequent_auto_empty` (460) | p70 b1 | `GetMiddleGobackDustSwitch()` | yes |
| Quirk STAIN_CLEANING | `stain_clean_switch` (402) | p53 b0 | `GetStainCleanSwitch()` = CC+0x7aa ← `stain-clean` | yes |
| Quirk THRESHOLD | `threshold_recognition_switch` (463) | p70 b6 | IoT `+0x143` = `threshold-detect` | yes |
| Quirk BRIDGE_BOOST | `bridge_boost_switch` (432) | p63 b3 | `GetBridgeBoostSwitch()` = CC+0x7bb ← `bridge-boost` | yes |
| Quirk AI_OBSTACLE_CLASSIFICATION | `ai_grade_avoidance_mode` from CleaningSettings1 (0xAA) p9 (721) | – | `handleIotMsg0x03_0xAA` `0x80b8d8`: `GetAiGradeAvoidanceMode()` = CC+0x7be ← `super-obstacle` (full byte) | yes |
| CarpetSensorModeV1 (J12 only) | `carpet_evade_switch` (395) | p50 b4 | vtable+0x1a0 = `GetCarpetEvadeSwitch()` = CC+0x7a8 ← key **`carpet-evade` (8)** | **no, M5** |
| MopTwistV1 (J12 only) | `tail_sweep_clean_switch` (422) | p56 b6 | never set by the status builder (always 0) | yes (consistent with "unsupported") |

## (b) Mismatches

| # | Area | What Valetudo says/does | What the firmware actually does | Impact | Evidence | Confidence |
|---|---|---|---|---|---|---|
| M1 | 0x31 naming/semantics | `CollisionAvoidantNavigationControlCapability` sends `[0x31,1/0]` and reads `edge_deep_vacuum_switch`. The name implies gentler, collision-avoiding driving | Sets `edge-deep-vacuum`. In vacuum-only mode the wall-follow code backs off only 25 mm at inner corners and runs corner manoeuvres, so the robot gets *closer* to walls (see [corner-cleaning-investigation.md](../corner-cleaning-investigation.md)). No effect while mopping | Users who enable "collision-avoidant navigation" get more aggressive edge/corner cleaning, which is roughly the opposite of the label. The id and the readback are correct | fw `0x81f230` (log "switch edge deep vacuum", key `0xaafb38`); status p68 b7 ← IoT+0x140 (`0x816bb0`); `robots/midea/capabilities/MideaCollisionAvoidantNavigationControlCapability.js:25,40-43,58-61`; `MideaJ15ProUltraValetudoRobot.js:37` | confirmed (static) |
| M2 | 0x15 AI obstacle classification labels | Quirk options: `off`=0, `high`=1, `normal`=2 | `_superObstacleAction` (`0x77d4e0`) maps the value through table `0xaa7b08` {0→2, 1→0, 2→1} to `PlannerNode::SetAvoidanceMode`. The planner enum is `SUPER=0 SMART=1 NORMAL=2` (planner_node string "avoidance_mode=%d [SUPER=0 SMART=1 NORMAL=2]"). So 0 = NORMAL, 1 = SUPER, 2 = SMART | "off" is not off: it selects planner NORMAL avoidance, which is presumably the non-AI baseline, and other AI switches stay on. "normal" (2) actually selects SMART. The order high > normal > off is plausibly right as SUPER > SMART > NORMAL, but the labels are misleading. The value range is fine (fw accepts ≤2) | fw `0x81e5b0` (`cmp w25,#2; b.ls`), key `super-obstacle` `0x81fc54`; table `0xaa7b08` (34 identical copies, one per TU); `MideaQuirkFactory.js:126-180` | confirmed mapping; label meaning likely |
| M3 | 0x2e naming | Exposed as `MopTwistControl` (V2) | "gap deep cleaning" (`SetGapDeepCleaningSwitch`, planner `wf_gap_mop_enable`), applied only while mopping | Name only; the setting and readback are correct | fw `0x81f1a0`; status p68 b4; `MideaMopTwistControlCapabilityV2.js:23,38` | confirmed |
| M4 | Error handling (all ids) | Capabilities `await sendCommand` and never inspect the 0x9C reply | The firmware replies with result=1 for an unknown id, an out-of-range value (`b.hi` paths) or an unsupported case | Failed toggles report success in the UI until the next status poll shows the old value | fw `0x81d474`-`0x81d48c` (RespIotCmd with w27); `msmart/BEightParser.js:24-38` (no 0x9C case) | likely |
| M5 | 0x07 carpet evade (J12 Ultra class only; this J15PU fw used as a proxy) | `CarpetSensorModeControlCapabilityV1`: AVOID→`[0x07,1]`, OFF→`[0x07,0]`; reads `carpet_evade_switch` (p50 b4) | 0x07 writes `carpet-strategy` (1 if v==1, else **3**), not 0. The status bit reads key `carpet-evade` (index 8), which no 0x9C/0x02 handler writes (only defaults and load in `_dataLoad`). 0x23 writes the same key with inverted polarity | On this firmware OFF would select strategy 3 (adaptive?) instead of off, and the readback would never change. Not registered on J15PU (J15PU uses CarpetSensorModeV2 via 0x5E/carpet behaviour) | fw `0x81db8c-0x81dbb8` (`csel w24,w24,#3,eq`), `0x81ed40-0x81ed74`; CC getter `0x770d60` reads +0x7a8 ← settings[8] (`0x795b78`); xrefs to `carpet-evade` `0xabf300` only in `CommonSettingWrap` ctor/`_dataLoad`; `MideaCarpetSensorModeControlCapabilityV1.js:24,54-57`; `MideaJ12UltraValetudoRobot.js:32` | confirmed for this fw; speculative for the J12's own fw |
| M6 | 0x16 tail flick (J12 only) | `MopTwistControlCapabilityV1` sends `[0x16,v]`, reads p56 b6 | id 0x16 is not in the map (error reply), and p56 b6 is never set | No effect on J15PU (not registered). If this code base matches the J12, the toggle would silently fail there too | jump slot 0x16 → `0x81d528`; status builder sets p56 b0–b5,b7 only; `MideaJ12UltraValetudoRobot.js:33` | confirmed for this fw |
| M7 | 0x0f side effect | ObstacleAvoidance.enable() sends `[0x0f,1]` first only if recognition is off; disable sends only `[0x2c,0]` | `[0x0f,0]` also forces `ai-avoidance`=false (Write<bool> flush). Recognition is the AI master switch | Harmless with current Valetudo code (never sends 0x0f=0). Worth knowing if a recognition toggle is ever added | fw `0x81e398-0x81e3ec` | confirmed |
| M8 | Status field naming | `MSmartStatusDTO.furniture_identify_switch` = p70 b0; `ai_grade_avoidance_mode` = p56 b5 (bool) | p70 b0 = `GetBigObjectDetectSwitch()` (0x32 "big object AI recognize"); p56 b5 = `GetAiGradeAvoidanceMode()!=0` | Cosmetic. Neither is used by J15PU capabilities. The bool `ai_grade_avoidance_mode` shares a name with the numeric CleaningSettings1 field the quirk uses | `0x816c1c`, `0x81696c`; `BEightParser.js:421,458` | confirmed |

Things I checked that showed no mismatch:
- **Value ranges:** every value Valetudo sends is within the firmware range. Only 0x15 uses 2, and the firmware accepts ≤2.
- **Polarity:** 1 means on for all 12 J15PU 0x9C users.
- **Readback:** all J15PU readbacks point at the same setting that the 0x9C id writes (see the readback table).

Mode gating is documented in [corner-cleaning-investigation.md](../corner-cleaning-investigation.md):
- 0x31 reaches the planner only in vacuum-only mode.
- 0x26/0x2e/0x2f reach it only while mopping.
- The stored value and the status bit update regardless of mode.

## (c) Firmware toggles that Valetudo does not expose at all

0x00 continuous-clean (Valetudo only reads `continuous_clean_mode`), 0x02 child lock follows DND, 0x04/0x05 station auto-inject detergent/softener, 0x09 (duplicate of ai-avoidance), 0x0a cross-bridge, 0x0c 3D map, 0x0d first fast wash ("10s exit docker"), 0x0f recognition (only as a helper), 0x10 station self-fluid 2, 0x11 SLAM version (**reboots the LDS**; don't expose casually), 0x12 hot-dry charge plate, 0x13 telnet, 0x17 rotation interval (u8, no range check), 0x18 pound-sign (criss-cross) pattern, 0x1d narrow-zone recharge, 0x1e verification map, 0x1f exhibition mode (0–5), 0x21 wake-up, 0x22 AI carpet avoidance, 0x23 carpet evade adaptive (same `carpet-strategy` key as 0x07), 0x24 stuck mark, 0x27 zigzag-to-end, 0x32 big-object AI recognition, 0x34 fall-down detection, 0x39 stain recognition method (0–3), 0x3b curtain detection, 0x3c adb pull, 0x3e stain detect. 0x06 is a no-op.

Most relevant for cleaning quality: 0x18 pound-sign, 0x27 zigzag-to-end, 0x22 AI carpet avoidance, 0x3b curtain detect, 0x32 big-object recognition, 0x24 stuck mark.

## Open questions

1. **AvoidanceMode meanings (M2).** What do NORMAL, SMART and SUPER actually do in planner_node? I didn't trace `PlannerCore::SetAvoidanceMode` (`planner 0x59bf50`) further. This decides whether "off" is really an AI-free mode and whether "high"/"normal" are apt names.
2. **carpet-strategy values.** What do values 1 and 3 mean (evade vs adaptive?), and is a value of 0 or 2 reachable through 0x5E? Who, if anyone, writes the legacy `carpet-evade`/`carpet-evade-adaptive` keys (indices 8/9) at runtime? Only the defaults and the load path were found.
3. **Reply handling (M4).** Does `MSmartDummycloud.sendCommand` surface the 0x9C reply anywhere? I only checked BEightParser.
4. **0x1f exhibition mode.** What do values 2–5 mean? It writes `exhibition-mode` through an ostringstream (string-valued setting); not traced.
5. **0x39 stain-recog-method (0–3).** Status p73 b2 may be `static_stain_recognition_switch`. I didn't map it, see [status-packet.md](status-packet.md).
6. **Runtime confirmation.** None of the above is confirmed at runtime. Info logs from `CIotCommunicationHandler` ("------switch …") aren't in the saved logs.
