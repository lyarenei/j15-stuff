# Investigation: reflashing the firmware and brick risk

**Status:** static analysis done, nothing run or flashed on the robot.
Started 2026-11-04. Open questions and the next (read-only) steps are at the
end.

The question: could the firmware itself (kernel, rootfs, U-Boot) be
modified, and how easily could a mistake brick the robot **permanently**,
even with precautions?

Tags: **[C]** confirmed from code, strings or logs; **[I]** inferred, or
general Rockchip knowledge not checked on this unit.

## Verdict

- **Permanent brick by a careful user is unlikely, as long as the
  bootloader is never touched and a few partitions are backed up first.**
  The stock update chain recovers by itself from power loss while boot or
  rootfs is written, and nothing in Linux can even reach the first-stage
  loader.
- What can't be undone without a backup is **data loss**, not a dead SoC:
  `vnvm` (MAC, cloud license, product keys) and the `oem` UBI volume
  (sensor calibration, identity copies).
- What can't be undone without **hardware access** (micro-USB in MaskROM,
  or the debug UART): a broken U-Boot, or a kernel/rootfs that boots but
  never reaches ssh/adb.
- Unknown and decisive for custom bootloaders only: whether Rockchip secure
  boot is fused. Reflashing **stock** images is fine either way.

| Change | Worst case | Recovery |
|---|---|---|
| rootfs (squashfs in UBI) | no ssh/adb | `recovery` partition (stock OTA flow), or UART/MaskROM |
| boot (kernel + DTB) | kernel doesn't boot | U-Boot still alive → recovery via BCB, UART, or `rockusb` |
| recovery partition | none while unused | rewritten by the next update |
| `uboot` partition | no U-Boot | MaskROM over USB only (needs a Rockchip loader; signed if secure boot is fused) |
| IDBlock (first 2 MiB) | no boot at all | MaskROM only; not writable from Linux anyway |
| `vnvm`, `license`, `oem` | identity, license, calibration gone | only from a backup |
| MCU / dock / BLE firmware | motors or dock dead | Linux re-flash if the MCU bootloader answers; otherwise SWD |
| SoC OTP fuses | irreversible | none; never write them |

## Flash layout [C]

From the kernel cmdline (`mtdparts=rk-nand:...`) and `dmesg`. NAND is
`FMND4G08U3C`, 512 MiB SLC, 128 KiB erase blocks, 2 KiB pages, generic MTD
driver (not `rkflash`).

| mtd | Name | Offset | Size | Contents |
|---|---|---|---|---|
| (none) | IDBlock | `0x000000` | 2 MiB | DDR init + SPL; **no MTD device covers it** |
| mtd0 | vnvm | `0x200000` | 1 MiB | Rockchip MTD vendor storage |
| mtd1 | uboot | `0x300000` | 6 MiB | U-Boot (+ trust/OP-TEE, [I]) |
| mtd2 | misc | `0x900000` | 1 MiB | bootloader control block (BCB) |
| mtd3 | license | `0xa00000` | 1 MiB | unknown; no Linux reader |
| mtd4 | recovery | `0xb00000` | 16 MiB | Rockchip recovery kernel + ramdisk |
| mtd5 | boot | `0x1b00000` | 16 MiB | kernel + DTB |
| mtd6 | rootfs | `0x2b00000` | 128 MiB | UBI, one squashfs volume (`ubiblock0_0`) |
| mtd7 | userdata | `0xab00000` | ~340 MiB | UBI: vol 0 `oem`, vol 1 `userdata` |

- Because nothing maps `0x0–0x200000`, Linux can't read or write the
  IDBlock, by accident or on purpose.
- `/dev/mtd0` is **vnvm**, not the whole chip. Some vendor code assumes
  otherwise (see [Hazards](#hazards)).
- `/oem` is not its own partition; it's a UBI volume inside mtd7.
  Formatting mtd7 wipes `/oem` too.

## Stock update chain [C]

```
cloud ─▶ iot_node ─(MD5, writes .sha256)─▶ /tmp/midea_ota_socket ─▶ midea_ota
           midea_ota: dock, BLE, line laser, voice, IMU, MCU, then navi *_ota.img
             └─▶ /usr/bin/update ota <img>  =  updateEngine --update --reboot --image_url=<img>
                   phase 1 (live): flash recovery partition, MD5-verify, write BCB "boot-recovery" to misc, reboot
                   phase 2 (recovery): re-write BCB, flash uboot/trust/boot/rootfs/oem present in the image,
                                       MD5-verify each, clear BCB, reboot
```

- `updateEngine` is stock Rockchip **V1.1.5**, non-A/B (`MiscUpdate`
  @`0x405ebc`). Default partition mask `0x3F0000` = uboot, trust, boot,
  recovery, rootfs, oem. **Loader (IDBlock) and parameter are excluded**
  ("OTA not support upgrade loader and parameter").
- Each partition write (`mtd_write` @`0x404c98`) is
  `flash_erase /dev/mtdN 0 0` then `dd ... | nandwrite -p /dev/mtdN`.
  The return codes are ignored, but each partition is then MD5-checked with
  `nanddump | md5sum`.
- `recovery` (main @`0x4021e0`) re-writes the BCB first, so a power cut
  during phase 2 lands back in recovery. The package is deleted only on
  success, so it simply runs again. Result goes to
  `/userdata/update_rst.txt`, log to `/userdata/recovery/last_log` (both
  exist on the examined robot, so this path has run before).
- **No signature check anywhere on the SoC path.** `updateEngine` and
  `midea_ota` import only MD5/SHA-256; `recovery` imports no crypto. The
  package MD5 in `midea_ota` (`package_verify` @`0x40ea94`) is the first
  32-character alphanumeric run **in the file name**. `iot_node` contains
  `FileSignVerify`/`VerifyRsa2048WithSha256` and `/etc/formal/public.pem`
  ships, but nothing calls them directly ([I] dead code).
- `midea_ota` forks an `ota_watchdog` that reboots after 900 s regardless.
- No A/B, no rollback. The recovery partition is the only fallback.

### Power loss during an update

| Moment | Effect |
|---|---|
| download, unzip, module flashing | SoC flash untouched |
| phase 1 (recovery partition) | BCB not set yet, normal boot works |
| phase 2, boot or rootfs | BCB still set → recovery re-runs → heals [I: U-Boot honours the BCB, standard Rockchip] |
| phase 2, `uboot` | whole partition erased first → **brick window**, MaskROM needed. Unknown whether Midea packages include `uboot` (none captured) |
| write/verify fails without power loss | BCB cleared anyway → boots a half-written partition |

## Recovery paths

### Micro-USB (OTG) [C/I]

- The only enabled USB controller is `dwc3@fcc00000` (`/usbdrd`,
  `dr_mode = "otg"`), the SoC's OTG port. `adbd` runs on it in device mode
  (`/usr/bin/switch_adbd.sh`, gated on `/oem/laserconfig.ini`).
- Valetudo roots this robot through adb on its **micro-USB port** (under a
  cover, no teardown; https://valetudo.cloud/pages/installation/midea/).
  [I] That is the OTG port, which is also the port the RK3566 BootROM uses
  for MaskROM, and U-Boot for `rockusb`. So USB recovery is physically
  reachable without opening the board.
- `reboot loader` / `reboot bootloader` (magic `0x5242c301` through
  `/syscon/reboot-mode`) should drop into U-Boot's rockusb mode while Linux
  still works. [I] Untested. Not useful if Linux is what's broken.
- Getting into **MaskROM** itself needs the BootROM to find no valid
  IDBlock, which on a working unit means shorting a NAND line or a MaskROM
  pad. The location on this board is unknown.
- [I] Unverified: whether `rkdeveloptool`/`upgrade_tool` can write raw
  parallel SLC NAND on RK356x with a stock Rockchip loader
  (`rk356x_spl_loader` NAND variant). No public confirmation found.

### Debug UART [C]

- `/fiq-debugger`: UART2 (`0xfe660000`, `uart2m0-xfer`, GPIO0_D0/D1) at
  **1,500,000 baud**. Kernel console is `ttyFIQ0`.
- [I] If U-Boot's autoboot can be interrupted there, its console offers
  `rockusb`/`download` and booting recovery by hand, which covers a broken
  kernel or rootfs. Pads, `bootdelay` and whether the console is enabled are
  unknown.

### Stock firmware image

- No public Midea `update.img` or full NAND dump found. The only stock
  images would be our own backups, or an OTA package caught in
  `/userdata/ota_images/` / `/userdata/ota_firmwares/` during a vendor
  update (which Valetudo advises against: updates can add new locks).

## Secure boot

- `androidboot.verifiedbootstate=orange` on the cmdline [C]. [I] AVB isn't
  enforcing on `boot`.
- OP-TEE 3.13 runs (`optee: revision 3.13`) [C]. `otp@fe38c000`
  (`rockchip,rk3568-otp`) exposes only the non-secure OTP; the secure-boot
  enable bit isn't visible from Linux.
- **`F1 signature OK` is not a boot log line on this robot.** It appears
  only in `S98_lunch_init:276` as a `grep` pattern
  (`dmesg | grep "F1 signature OK" ... > /tmp/apversion`), with zero matches
  in any dmesg dump. Earlier docs overstated it as evidence of signature
  checks.
- Whether the BootROM checks the loader signature can't be told from the
  dumps. If it's fused, MaskROM recovery needs a Midea-signed loader and a
  modified U-Boot won't boot. A dump of the `uboot` partition (strings like
  `SecureBoot`, FIT `required` signature nodes) or the UART boot log would
  answer it.

## Per-device data

- **vnvm (mtd0)** = MTD vendor storage (`mtd vendor storage:20200313 ret = 0`).
  Per `midea_licrw` help: Wi-Fi MAC (ID 2), Midea cloud license (ID 16),
  Meizhi/Tuya product ID, UUID and auth key (IDs 12–14). Readers:
  `vendor_storage`, `midea_licrw`, `iot_node*`, `midea_robot`,
  `libmziot.so`. A copy of the license is also at `/oem/midea/device.lic`.
- **license (mtd3):** no Linux reader found; purpose unknown.
- **Calibration** lives on `/oem` (`/oem/vendor_conf/` line-laser extrinsics,
  `/oem/slam/`, `/oem/midea/device.type`). IMU calibration is probably on
  the MCU ([I]).
- **misc (mtd2):** only the BCB. Erasing it is harmless (normal boot).

## MCU, dock and BLE firmware

- No module firmware ships in the rootfs; it arrives in OTA zips
  (`image.bin` MCU, `image_imu.bin`, `image_ld.bin`/`image_eai.bin` line
  laser, `voice.bin`, `station_*.bin` dock, `ble_module_x9.bin`).
- MCU protocol (strings in `midea_ota`, `midea_mcu_usb_ota`): version query,
  "firmware ready" (the MCU can refuse: wrong device type, not a higher
  version), the MCU pulls frames, verifies (`verify failed, refuse switch!`),
  then switches. [I] An MCU-resident bootloader with staging, so an
  interrupted transfer keeps the old firmware; a valid-but-wrong image would
  still be accepted.
- [I] Linux can re-flash the MCU only if its bootloader still answers and
  the SoC still has power, and the MCU seems to control power
  (`mcu-request-set-mcu-power-off`, the "prevent mcu power failure" wait).
  Otherwise SWD. Dock and BLE are flashed over BLE with type/version checks;
  recoverability unknown.

## Hazards

- **`/userdata/ota_firmwares/` is a live drop folder.** `midea_ota` watches
  it with inotify (`IN_CLOSE_WRITE`, `FUN_0040e228`). Writing `image.bin`,
  `image_imu.bin`, `voice.bin`, `image_ld.bin` or `image_eai.bin` there
  immediately runs `mcu_ota_killer.sh` (stops the nav stack) and flashes
  that module. `station_*.bin` and `ble_module_x9.bin` flash the dock or BLE
  module. After a successful MCU flash, an existing `/userdata/navi_ota.img`
  is also installed. Never stage files there.
- **SD-card update paths write `/dev/mtd0`.** `updateEngine`
  (`ota_recovery_cmds` @`0x408d9c`: `nandwrite -p /dev/mtd0 -s ...`) and
  `recovery` (`flash_erase /dev/mtd0 0x0 0`, `flashcp ... /dev/mtd0`) assume
  mtd0 is the whole chip. Here they'd destroy vnvm. Not reachable normally
  (SD and USB host are disabled in the DT), but never drive them by hand.
- **`flash_otp_write`/`flash_otp_lock` are on the robot.** These are NAND
  OTP, not SoC fuses, but equally irreversible.
- `updateEngine --partition` with bit 23 (loader) would write the IDBlock
  through `WriteIDBlock`. Never pass a mask that includes loader or uboot.
- Formatting mtd7 or a recovery "wipe data" destroys `/oem`.

## Offline reflash [C]

`updateEngine --update --reboot --image_url=/userdata/<x>.img` (what
`/usr/bin/update ota` runs) installs a Rockchip RKFW `update.img` with a
valid MD5 trailer, no cloud and no signature. Pass `--partition` to limit it
(e.g. boot+rootfs only, never uboot). The image also has to pass the model
check against `/etc/version.conf`.

Lower-level alternative: `ubiupdatevol` on the rootfs volume, or
`flash_erase` + `nandwrite -p` on boot. Same risk profile, but without the
recovery self-healing.

## Precautions before any flash experiment

1. Back up, read-only, and keep off the robot:
   - `nanddump --bb=skipbad -f <file> /dev/mtdN` for mtd0–mtd5
   - `/dev/ubiblock0_0` (rootfs squashfs) and a file-level tar of `/oem`
   - `midea_licrw`/`vendor_storage` reads of the vendor IDs
   Sanitize per [research-workflow.md](research-workflow.md) before keeping
   anything in `dumps/`.
2. Never write the IDBlock, `uboot`, `vnvm`, `license` or any OTP.
3. Leave the recovery partition stock, so the stock update path keeps
   working as a fallback.
4. Have a way in that doesn't depend on Linux: confirm the micro-USB
   `rockusb`/MaskROM path and/or the 1.5 Mbaud UART **before** the first
   flash.

## Open questions / next steps

- Dump `uboot` (mtd1) read-only and look for secure boot, FIT signature
  enforcement, `bootdelay`, rockusb support and how it picks recovery.
- Check `/proc/mtd`, `ls /dev/mtd*`, and whether `reboot loader` brings up a
  Rockchip USB device on a computer (`rkdeveloptool ld`).
- Find the UART2 pads and the MaskROM short point on the main board.
- Confirm rkdeveloptool NAND support on RK356x with a stock loader.
- Find out what reads the `license` partition.

## Method and binaries

Static analysis of `dumps/x2`, `dumps/dmesg-boot.txt`,
`dumps/devicetree.dts`, `dumps/filelist.txt`: `strings`, `llvm-nm -D`,
`llvm-objdump -d`, Ghidra (via REA) on `updateEngine`, `recovery` and
`midea_ota`. All three are non-PIE aarch64, so addresses are file virtual
addresses. Web sources: Valetudo's Midea install guide and supported-robots
page, Rockchip/Radxa/Pine64 MaskROM docs, 3mdeb's RK3566 secure boot notes.

| File | sha256 |
|---|---|
| `/usr/bin/updateEngine` | `e6b3113a57134e99ca07ab6e11d336200d57d6c0b2d738f2454a7867edb88e38` |
| `/usr/bin/recovery` | `bc33af3f15bdccac3cb0ff5120099d51a6e23098514952bbbea80e8de952d09a` |
| `/usr/bin/midea_ota` | `ccce129ab5c3fcf36f94a6d0e2adce394f34f4fb3c35f63b60038b6fc3aa7804` |
