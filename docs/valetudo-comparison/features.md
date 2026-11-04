# Mismatch E: capability and feature fit, Valetudo J15 Pro Ultra vs firmware

Static analysis only. Binaries: `dumps/x2/usr/navi/manager_node` (sha256 `049e9d56…`), `planner_node`, product dirs `dumps/x2/etc/formal/product/*`. Valetudo `06cfc72`. Addresses are `manager_node` unless noted.

## Model and firmware facts used below

- **One firmware image for all J15 variants.** `/etc/formal/product/{j15_eureka, v15_japan, v15_TW, j15_ultra_eureka_*, j15s_pro_ultra_eureka_*, J15_evo_ultra*, v15}/config.ini` are byte-identical. Only `product_diff.ini` differs (SN8, servers, Wi-Fi country, sound). `start-dushu` picks `common-V15Overseas.json` by `/oem/midea/device.type` (`MD-DUSHU-MA-RB-01`), not by SN8.
- So the firmware decides per-model features at runtime, from the MCU-reported **RobotType** and the dock's **StationType**: `clean_robot::ManagerRuntime::UpdateRobotCapability` (`0x7df810`), a switch on `+0xf0` (robot type) and `+0xf1` (station type). This robot logs `MCUStatus::RobotType enum value: 26` (recognition2 log). For type `0x1a` (case at `0x7dfe54`), the named flags from the log format `eleWater carpetBoost waterBox liftMop collDust ERP DOE waterStationLed carpetInfoShow innerWaterBox dualFluid selfFreq` (`+0x100…+0x10c`) come out as `0 1 0 1 1 1 1 1 0 1 1 1`. Station type 3 additionally sets eleWater. Bytes `+0x10d…+0x132` are set too but have no names. Type `0x1d` sets a strict superset (`+0x12c…0x132`), probably a newer or bigger model.
- The cloud capability frame is ACTION `0x59` (`handleIotMsg0x03_0x59`, `0x803070`): a constant bitmask, plus IsWSSupportEleWater, IsSupportCarpetBoost, GetSuctionConfigType, IsSupportSelfCleanFreq, IsSupportMopAutoDry, GetStationCapability, IsSupportDialect, IsImageSupportEnc. Valetudo doesn't read it (its comment in `MSmartConst.js` says "maybe feature bits").
- Hardware (owner and docs): no swing-out side brush (Max Ultra only), mop extension, mop lift, dock with clean and dirty tanks plus a dust bag, SC035HGS camera 640×480, line lasers (`common-V15Overseas.json`: front_left, front_right, side_wall, ssl_linelaser), one ultrasonic sensor, 6 cliff sensors, `voice:false`.

## (a) Feature table

| Feature | Firmware support (evidence) | Valetudo J15 Pro Ultra exposure | Match? |
|---|---|---|---|
| Fan speed | `data-V15Overseas.json` suction quiet/soft/standard/strong/max; MotorSpeedDecoder | FanSpeedControlV2 MIN=4 LOW=1 MED=2 HIGH=3 (MAX=5 hidden on purpose) | yes |
| Water grade | `InfiniteWaterSpeedEncoder`; per-room `infinite_water_speed` | WaterUsageControlV2, high-res 101…130 | yes |
| Operation mode | VacuumMopModeDecoder | OperationModeControlV2 (0…3) | yes |
| Mop extension | 0x9C `0x26` SetMopExtendSwitch; hardware has it | MopExtensionControl | yes |
| Furniture legs | 0x9C `0x2f`, `wf_legs_circular_enable` | MopExtensionFurnitureLegHandlingControl | yes |
| Gap deep cleaning | 0x9C `0x2e`, `wf_gap_mop_enable` | **MopTwistControl V2** | name only (see M2) |
| Edge deep vacuum | 0x9C `0x31`, short back-off at inner corners ([corner doc](../corner-cleaning-investigation.md)) | **CollisionAvoidantNavigationControl** | **no** (M1) |
| Mop lift on carpet | liftMop=1 (type 0x1a); SET `0x5E` carpet_behavior | CarpetSensorModeV2 off/avoid/lift | mostly (M6) |
| Carpet boost | carpetBoost=1; `0x5E` bit2 → `boost_on_carpet` | CarpetModeControlV3 | yes |
| Carpet first / precise | `0x5E` bit0 `sweep_carpet_first`, bit1 `sweep_carpet_precisely` | quirks CARPET_FIRST, DEEP_CARPET_CLEANING | yes |
| `0x5E` bit3 | `ai_avoid_carpet` (key `carpet-setting-ai-aviod`). The camera adds carpets to the costmap (`SlamCostmap2DLayer - enable ai carpet`) | quirk "Increased Carpet Avoidance: stay further away" | label doubtful (M7) |
| Clean route | kRouteTypeDecoder IoT 0→2(fast), 1→1, 2→3 (`0xad24e8+0x2e8`); planner `IsFastRouteActive` = type 2 | CleanRouteControl quick/normal/deep, `oneTime:[quick]` | yes; oneTime not confirmed (M8) |
| Floor material | GroundMaterialTypeDecoder accepts 0…4 (`0xad24e8+0x2c0`) | MapSegmentMaterial generic=0, wood=2, tile=3 | partial (M9) |
| Mop wash temperature | SET `0xC5` accepts 0…2 | MopDockMopWashTemperature cold=0/hot=1/warm=2 | range ok; whether the dock heats is unconfirmed |
| Mop drying time | SET `0x9B` accepts modes 0…7; table `0xb5b210` (below) | MopDockMopDryingTime 5=2h, 6=3h, 7=cold | partial (M4) |
| Mop auto dry | 0x9C `0x14` | MopDockMopAutoDryingControl | yes |
| Auto-empty interval | SET `0x56` type 1 (any value), 0x9C `0x33` middle-goback-dust (empties mid-clean, `MiddleBackStation`) | AutoEmptyIntervalV3 off/normal/infrequent/frequent | ok (M10, minor) |
| Auto-empty duration | SET `0xC7` accepts 1…3 (`sub w0,w23,#1; cmp #2; b.hi err`) | AutoEmptyDurationV2 1/2/3 | yes |
| Hair cutting | C9 sub 1/6; firmware checks the dock capability (`unsupport cut hair. capability=%d`) | quirks HAIR_CUTTING(+TURBO) | yes (dock-dependent) |
| AI obstacle avoidance | 0x9C `0x0f`, `0x2c` | ObstacleAvoidanceControl | yes |
| AI classification level | 0x9C `0x15` super-obstacle | quirk AI_OBSTACLE_CLASSIFICATION | yes |
| Pet mode | 0x9C `0x0e`. When a pet is detected, the AI mask changes and the planner slows down (`SpeedCommand - Enter PetMode need slow-down`). It also toggles `stain-clean` | PetObstacleAvoidanceControl | yes |
| Stain cleaning | 0x9C `0x08` | quirk STAIN_CLEANING | yes |
| Obstacle images | 0x9C `0x35` live-photo, `/userdata/aiimgs/%d-%lu-%s.jpg`, 640×480 | ObstacleImages JPG 640×480 | yes |
| Camera fill light | `pwm_fill_light_control`, 0x9C `0x0b` | CameraLightControl | yes |
| Live video | `/dev/video5` mainpath 640×480 | LinuxDuststreaming 640×480 | yes |
| Large AI model | `detect_control_node` → `/userdata/ai_models/cod-detect-large.bin`, cloud-delivered `aimodel.zip` | MissingResource event | yes |
| Threshold recognition / boost | 0x9C `0x3a`, `0x1c` | quirks | yes |
| Cliff sensors | SET `0x63` stairless | quirk CLIFF_SENSORS | yes |
| Child lock | 0x9C `0x01` | KeyLockCapabilityV2 | yes |
| Dock tanks / bag | BLE `sensor_status` (water-tank doc) | dock components clean/dirty/dustbag | yes |
| Detergent | dualFluid=1; 0x9C `0x04`/`0x05` inject fluid / soft fluid; `is_fluid`/`is_agent` bits read 0 in logs | none (no DETERGENT component, no toggles) | missing (U) |
| Room selection | SET `0x03` reads only id and count per room (+ first room's mode byte) | MapSegmentationV2 sends fan/water per room | harmless (M3) |
| Per-room settings | SET `0x2B` → `CCentralController::SetRoomInfo` (fan +4, water +5, route +7 via kRouteTypeDecoder) | none | missing (U) |
| Active segments | no ACTION `0x30` handler in the `0x03_*` list | not polled on Pro (only Max) | yes |
| Wi-Fi scan | `/usr/sbin/iw`, `iwlist` present, `wlan0` | registered on Max only | missing on Pro (M11) |
| Swing-out side brush | code present (`ExtendSideBrushMode`, `SideBrushExtend` aging test); not on Pro hardware | not registered (nor on Max) | yes |

Mop dry-mode table (`std::map<MopDryMode, pair<DryMopMethod, seconds>>`, init `0x710940`, data `0xb5b210`; read by `CStationCtrl::_getMopDryMethod`/`_getMopDryTotalTime`):

| mode | 0 | 1 | 2 | 3 | 4 | 5 | 6 | 7 |
|---|---|---|---|---|---|---|---|---|
| method | 2 | 1 | 1 | 1 | 2 | 1 | 1 | 2 |
| time | 6 h | 3 h | 1 h | 100 min | 3 h | 2 h | 3 h | 6 h |

Unknown mode falls back to 14400 s. Station work mode 2 halves the time. Method 2 is presumably unheated ("cold"); Valetudo's 7=cold agrees with that.

## (b) Mismatches

| # | Area | Valetudo says/does | Firmware/hardware actually | Impact | Evidence | Confidence |
|---|---|---|---|---|---|---|
| M1 | CollisionAvoidantNavigation | Toggle `0x31`, named "collision-avoidant" (gentler driving) | `edge-deep-vacuum`: backs off only 25 mm at inner corners and does a corner manoeuvre, so it cleans *closer* to walls. Vacuum-only mode only | Misleading label; users may leave it off | handler `0x81f230`; [corner doc](../corner-cleaning-investigation.md) | confirmed |
| M2 | MopTwist | V2 = toggle `0x2e` | "Gap deep cleaning" (`wf_gap_mop_enable`, gap detection). The real tail-swing (`wf_fish_tailing_enable`, `SetEnableSwingTailCleaning`) has no IoT sender; `0x16` is unsupported | Name mismatch; behaviour is a gap routine, not a twist | jump table `0x16`→default `0x81d528` | confirmed |
| M3 | Segment clean payload | Sends operationMode, fanSpeed and waterGrade per room | `handleIotMsg0x02_0x03` (`0x80d000`) loops `w19=14; +=10; <0x72` and reads only `id`,`count` per slot, plus frame byte 16 (first room's mode) as a global sweep mode. Fan/water bytes are ignored | None today (Valetudo sends the global values). No per-room parameters are possible via `0x03` | disasm `0x80d058…0x80d1a0` | confirmed |
| M4 | Mop drying time | Supports modes 5/6/7 only; `getDuration` **throws** on any other mode | Firmware accepts 0…7 (`cmp w24,#7; b.hi err`) with 8 table entries (1 h, 100 min, 3 h, 6 h…). A mode left by the Midea app or by firmware default (0…4) makes the Valetudo capability error out | UI error, and 1 h / 100 min options are not offered | `0x7ffe90`, table `0xb5b210` | confirmed (code); default mode unknown |
| M5 | Model/feature source | Hard-codes capabilities per SN8 class | Same image and config for all J15 SKUs; features come from RobotType/StationType (`UpdateRobotCapability`) and ACTION `0x59`. The Pro, Max and Ultra classes register the same 15 capabilities and 14 quirks | Valetudo can't tell what the attached dock supports (hot wash, hair cut, eleWater, detergent) | `0x7df810`, `0x803070` | confirmed |
| M6 | CarpetSensorMode | AVOID is written as raw 3 ("cross"); raw 0 ("avoid always") is read as AVOID too | Firmware decodes byte 13 through a map (`0x5E` handler `0x819a20`) into `CarpetStrategySetting.type`. Exact enum semantics not decoded here | Possible read/write asymmetry (0 reads as avoid; writing avoid gives 3) | handler + `SetGlobalCarpetStrategy` | likely |
| M7 | Quirk "Increased Carpet Avoidance" | bit 3 of `0x5E` = "stay further away from carpets" | bit3 → `ai_avoid_carpet` (CarpetStrategySetting byte 4), i.e. camera-based carpet avoidance (`SlamCostmap2DLayer - enable ai carpet`). Separate 0x9C `0x22` `SetAICarpetAvoidSwitch` also exists | Description probably wrong | `CPlannerNode::SetGlobalCarpetStrategy` log arg order (byte0 type, 1 first, 2 precisely, 3 boost, 5 global) | likely |
| M8 | CleanRoute | QUICK marked `oneTime` | Planner keeps `route_type_`/`next_route_type_`. No auto-reset of fast route found. Fast route (planner 2) also defers wall-follow switches (`IsFastRouteActive`). Logs show the robot booting with planner route 3 (= Valetudo DEEP) and zigzag gap 2 grids | If QUICK doesn't reset, the UI hint is wrong | `0x5bc790` (planner) | speculative |
| M9 | MapSegmentMaterial | generic=0, wood=2, tile=3 | Decoder accepts 0…4. Values 1 and 4 unexposed (meaning unknown). Material only feeds manager-side `[AiClean]`/adaptive params; no planner use found | Minor; two materials missing | `0xad24e8+0x2c0`, handler `0x02_0x31` | confirmed (range), meaning speculative |
| M10 | AutoEmpty FREQUENT | interval 1 + `0x33`=1 | `0x33` = empty mid-clean when vacuum area reaches a target (`need middle back station collect dust`). "Frequent" is semantically fine, but NORMAL and FREQUENT both write interval 1 | none | strings `MiddleBackStation`, `0x56` handler | confirmed |
| M11 | Wi-Fi scan | Registered for Max Ultra only | Pro Ultra has the same `wlan0` (RTL8723DS) and ships `iw`/`iwlist`/`wpa_cli` | Missing convenience capability | filelist | likely |
| M12 | Detection naming | Max Ultra = SN8 `750Y0013/14` | Firmware product dir for those SN8s is `j15s_pro_ultra_eureka_*`; Pro Ultra SN8s map to `j15_eureka` (R), `v15_japan` (U), `v15_TW` (Y) | Naming only; the lists are disjoint | `product_diff.ini` | confirmed |

## (c) Firmware features with no Valetudo exposure

0x9C toggles (id → setting; handler names from the jump table `0xac8920`; status fields already parsed by `MSmartStatusDTO`):
- `0x00` continuous clean (resume after recharge, "smart breakpoint"); `0x02` child lock follows DND; `0x04`/`0x05` dock injects detergent / softener (dualFluid=1); `0x10` station self fluid 2.
- `0x07` carpet evade, `0x23` carpet evade adaptive, `0x22` AI carpet avoidance; SET `0xD2` global carpet strategy; SET `0x32` per-carpet settings (`SaveCarpetCleanStrategy`, carpet id, attribute, shape).
- `0x0a` cross bridge (`planner.json cross_bridge`); `0x0c` 3D map; `0x0d` "10 s exit dock" (`StationFirstFastWash`); `0x12` hot-dry charge plate; `0x17` rotate interval (u8); `0x18` pound-sign (#, probably criss-cross; planner `EnableCrisscrossClean`); `0x1d` narrow-zone recharge; `0x1e` verification map; `0x1f` exhibition mode; `0x21` wake-up (voice; `voice:false` on Overseas); `0x24` stuck mark; `0x27` zigzag to end; `0x32` big-object (furniture) recognition; `0x34` **fall-down detect** (person-fall AI class `FALLDOWN`/`humanseg.bin`); `0x39` stain recog method; `0x3b` curtain detect; `0x3e` stain detect (`HandleStainDetect`); `0x13` telnet and `0x3c` adb pull (debug).
- Per-room settings: SET `0x2B` → `SetRoomInfo` (per room: id, fan +4 via MotorSpeedDecoder, water +5, route +7 via kRouteTypeDecoder, other bytes unnamed). This is probably the packet that sets `cleanSeq` (room-order doc open question). SET `0x2A` room type (RoomTypeDecoder); `ThingsModel::CommandRoomInfo` (JSON).
- Map objects: SET `0x33` thresholds/door sills, `0x34` curtains (add/delete); SET `0x5D` beautify map grade; SET `0x28` multi-floor switch, `0x29` new house map.
- Dock: TRIGGER_STATION_ACTION mode 3 / SET `0x5B` dock self-clean start/stop; SET `0x57` reset dust counter; SET `0x54` electrolysed water (eleWater=0 on this type unless station type 3); mop dry modes 0–4; C9 `turbidity_re_mop` (turbidity meter reads 65535, so probably not fitted).
- "AiClean"/AdaptiveClean per-room parameters (cloud room-info JSON) and `SetCustomizedClean`.
- ACTION `0x59` capability bitmask (could drive per-unit capability registration).

## (d) Open questions

1. Is RobotType 26 in recognition2's `MCUStatus` the same enum as `ManagerRuntime+0xf0`? What is this dock's StationType (`_stationType:%d` debug-level, not in logs)? Names of capability bytes `+0x10d…+0x132`?
2. Does the Pro Ultra dock actually heat wash water (Valetudo exposes cold/warm/hot) and cut hair? Firmware gates both on dock capability, not checked here.
3. The firmware default for `mop-smart-dry-mode`, and whether mode 0 is a "smart"/ambient-temperature mode (`manager.json MopHotDry` table 2–3.5 h) despite the 6 h table entry.
4. Meaning of GroundMaterialType 1 and 4, and of the exact `0x5E` carpet_behavior enum.
5. Does QUICK route auto-revert after one clean?
6. Full `0x2B` per-room layout (which byte is `cleanSeq`, `vacuum_mop_mode`, `cleanCount`). Does `StartRoomClean` apply stored CRoomItem fan/route over the global settings when `SetCustomizedClean` is on?
7. Detection: Valetudo's lists are disjoint, so no misdetection is possible. SKUs with no Valetudo class: `J15_evo_ultra` (`750Y001D/E`) and Midea-brand V15 variants (`7500…` SN8s). The actual `/oem/midea/device.sn8` of this unit wasn't in the dumps.
