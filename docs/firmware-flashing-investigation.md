# Investigation: reflashing the firmware and brick risk

**Status:** static analysis done, plus read-only dumps of mtd0–mtd5 and,
over USB in MaskROM, of the first 2 MiB (2026-11-04,
[analysis below](#flash-dump-analysis)). Nothing flashed.
Started 2026-11-04. Open questions and next steps are at the end.

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
- Rockchip secure boot is **not enforced**: the BootROM accepted an
  unsigned loader over USB, the stock IDBlock (SPL) is itself unsigned, the
  U-Boot FIT is unsigned, and there's no AVB on boot/recovery. Stock or
  modified images of any stage boot.
- **MaskROM is reachable from Linux and works over the micro-USB port**,
  and the loader reads the NAND at plain flash offsets. So a full raw NAND
  image can be taken and written back over USB, which makes almost any
  software brick recoverable, as long as you can still get into MaskROM
  (from Linux, or by the BootROM itself when the IDBlock is broken).

| Change | Worst case | Recovery |
|---|---|---|
| rootfs (squashfs in UBI) | no ssh/adb | `recovery` partition (stock OTA flow), or UART/MaskROM |
| boot (kernel + DTB) | kernel doesn't boot | U-Boot still alive → recovery via BCB, UART, or `rockusb` |
| recovery partition | none while unused | rewritten by the next update |
| `uboot` partition | no U-Boot, IDBlock still valid → BootROM doesn't fall back to MaskROM | MaskROM needs a short or the ADC download key (location unknown) |
| IDBlock (first 2 MiB) | no boot at all | BootROM falls back to MaskROM by itself → rewrite over USB; not writable from Linux anyway |
| SPL key burn (signed FIT with `burn-key-hash`) | secure boot fused with your key, irreversible | none; never build signed images |
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
  `dr_mode = "otg"`), the SoC's OTG port. `adbd` runs on it in device mode.
  Tested 2026-11-04: with a data cable to a Mac the gadget enumerates as
  VID `0x2207`, vendor "world", product "robot", with an ADB and a CDC ACM
  interface, `adb devices` lists it, and `/sys/class/udc/*/state` is
  `configured`. That's with no `/oem/laserconfig.ini`, so that file (checked
  in `/usr/bin/switch_adbd.sh`) doesn't gate the gadget. A charge-only cable
  shows nothing at all, not even an unknown device.
- Valetudo roots this robot through adb on its **micro-USB port** (under a
  cover, no teardown; https://valetudo.cloud/pages/installation/midea/).
  [I] That is the OTG port, which is also the port the RK3566 BootROM uses
  for MaskROM, and U-Boot for `rockusb`. So USB recovery is physically
  reachable without opening the board.
- The loader magic (`0x5242c301` through `/syscon/reboot-mode`, PMU GRF
  `0xfdc20000` + `0x200`) should drop into U-Boot's rockusb mode while
  Linux still works. Not useful if Linux is what's broken.
- **`reboot loader` doesn't do that on this firmware.** Tested 2026-11-04:
  the robot just rebooted into Linux. [C] Neither stock tool passes the
  argument to the kernel:
  - `/sbin/reboot` is BusyBox v1.27.2, whose `reboot` takes no reboot
    argument.
  - `adbd`'s reboot service (@`0x40de30`) either runs
    `system("reboot loader")` (BusyBox again) or calls its `android_reboot`
    (@`0x415020`) with `ANDROID_RB_RESTART` (`0xdead0001`), which is plain
    `reboot(0x01234567)`. The `RESTART2` branch that would pass the string
    (syscall 142, @`0x415134`) is never taken. So `adb reboot loader` fails
    the same way.
  - What works [I, pending test]: `reboot(2)` with
    `LINUX_REBOOT_CMD_RESTART2` and `"loader"`. A 15-line static helper
    (`syscall(SYS_reboot, LINUX_REBOOT_MAGIC1, LINUX_REBOOT_MAGIC2,
    LINUX_REBOOT_CMD_RESTART2, argv[1])` after `sync()`, built with
    `zig cc -target aarch64-linux-musl -static`) does it. Like
    `reboot -f`, it skips the init shutdown, so only `sync` protects the
    UBIFS volumes; run it with the robot idle.
- **MaskROM is reachable from Linux, no shorting needed.** Tested
  2026-11-04: `reboot(2)` with `RESTART2 "loader"` makes the robot come up
  as `Vid=0x2207,Pid=0x350a ... Maskrom` in `rkdeveloptool ld`, i.e. the
  BootROM's USB mode, not U-Boot rockusb. [I] U-Boot took its
  `Enter rockusb failed, fallback to bootrom...` path. In MaskROM only
  `ld` works; `rci`, `rfi` and `rl` fail until a loader is pushed into RAM
  with `rkdeveloptool db <loader>` (RAM only, writes nothing).
- With a broken IDBlock the BootROM falls back to MaskROM by itself; with a
  broken U-Boot but intact IDBlock, getting there needs a short or the ADC
  download key (location unknown).
- **Never use Rockchip's `_nand` usbplug on this robot.**
  rkbin's `RK3566MINIALL_NAND.ini` pairs the DDR blob with
  `rk356x_usbplug_nand_v1.04.bin`, which contains Rockchip's legacy NAND FTL
  (`FTL version: 6.0.24 20210107`, `no sys info %x`, `ftl_low_format`). That
  FTL low-formats a NAND where it finds no FTL metadata, and this robot's
  NAND is raw MTD/UBI with none, so loading it would likely wipe the chip,
  vnvm and U-Boot included. [C strings, I behaviour]
- The generic usbplug (`rk356x_usbplug_v1.17.bin` in rkbin, or the one in
  Radxa's prebuilt `rk356x_spl_loader_ddr1056_v1.10.111.bin`, sha256
  `d7cfd619870cebe5a69e365796709d5ba1fc0294a84ae63357a9d189074dc100`, usbplug
  built Dec 9 2021) has no FTL format code: a raw SLC NAND driver
  (`nandc_flash_init`, `support nand flash type: slc`), and writes only in
  command handlers (`write_idblock`, `write vendor`, `prog gpt`). The Radxa
  loader's header has `sign_flag = 0` (unsigned), so a successful `db` also
  shows the BootROM doesn't enforce secure boot.
- `rkdeveloptool pack` (v1.32) fails on current rkbin `.ini` files
  (`parseLoader failed!`) and can't set the RK356x RC4-off flags anyway; use
  a prebuilt loader or Rockchip's `boot_merger`.
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
- The `uboot` dump makes fused secure boot unlikely; see
  [U-Boot](#uboot-mtd1). If it were fused, MaskROM recovery would need a
  Midea-signed loader and a modified U-Boot wouldn't boot.

## Flash dump analysis

Read-only `nanddump --bb=padbad` of mtd0–mtd5, `/dev/ubiblock0_0` and a tar
of `/oem`, taken 2026-11-04 with the commands in
[Precautions](#precautions-before-any-flash-experiment). Kept off the repo
(they contain the device identity). Checksums on the robot and locally
matched. `/proc/mtd` matches the cmdline layout; `/dev/mtdblock0–7` and
`/dev/mtdNro` exist.

### uboot (mtd1)

- Two identical copies of a FIT image, at `0x0` and `0x200000`; the last
  2 MiB are erased (`0xff`). [C]
- FIT description `"FIT Image with ATF/OP-TEE/U-Boot/MCU"`, timestamp
  2024-05-17. Images: `uboot` (load `0xa00000`), six `atf-*` (BL31),
  `optee`, `fdt`, each with a SHA-256 hash. The `uboot` hash matches the
  data. [C]
- Configuration `conf` (description `rk3568-evb`, `rollback-index = 0`) has
  a `signature` node (`algo = "sha256,rsa2048"`, `key-name-hint = "dev"`,
  `sign-images = fdt, firmware, loadables`) **but no `value` property**:
  the template from Rockchip's build scripts, never actually signed. [C]
  [I] Rockchip's secure boot chain (BootROM → signed SPL → SPL checks the
  FIT signature) would reject this FIT, so SPL isn't enforcing signatures,
  and Midea most likely never fused secure boot. The SPL itself (in the
  IDBlock) can't be read from Linux to confirm.
- U-Boot `2017.09-gefea4696-dirty`, built `May 17 2024 15:50:07 +0800`
  (Rockchip vendor tree). [C]
- `bootdelay=0`, but strings include `Hit key to stop autoboot('CTRL+C')`
  and `Hotkey: ctrl+%c`. [I] Rockchip's U-Boot hotkeys work with
  `bootdelay=0` when a key is held on the UART during boot (in the vendor
  source: ctrl+c command line, ctrl+d rockusb, ctrl+b BootROM download).
  Not tested.
- Download modes: `enter Rockusb!`, `Enter bootrom rockusb...`,
  `Enter rockusb failed, fallback to bootrom...`, `boot mode: loader`,
  `rockusb` command. So U-Boot can put the board into rockusb **and** into
  BootROM MaskROM itself, without shorting anything. [C strings]
- Its own device tree (FIT `fdt`) has an **`adc-keys` `volumeup-key`** on
  SARADC channel 0 (`press-threshold-microvolt = 9`, i.e. the channel pulled
  to ground), marked `u-boot,dm-spl`. That's the Rockchip download/recovery
  key (`download %skey pressed... entering download mode`). The Linux DT
  doesn't declare it. [C] Whether SARADC ch0 reaches a pad or button on
  this board is unknown.
- `chosen` → `stdout-path = "/serial@fe660000"` (UART2, the same debug
  UART) and `u-boot,spl-boot-order = dwmmc, sdhci, nandc, sfc`. [C]
- Also has AVB code (`bootavb`, `androidboot.verifiedbootstate=orange`
  string), and a `secure_otp@fe3a0000` driver node. [C]

### IDBlock region (first 2 MiB, read over USB)

Read in MaskROM after `rkdeveloptool db` of Radxa's
`rk356x_spl_loader_ddr1056_v1.10.111.bin` (RAM only):
`rkdeveloptool rl 0 0x1000 idb.bin`. [C]

- **The loader's LBA is the raw flash offset:** `rl 0x1000 0x800` (1 MiB at
  2 MiB) is byte-identical to the Linux `nanddump` of mtd0 (vnvm). So `rl`
  and `wl` address the same bytes as the kernel's mtdparts.
- `rci`: `38 36 35 33 ...` ("3568" reversed; RK3566 reports as RK3568).
  `rid`: `F8 DC 90 95 46` (same chip as dmesg). `rfi`: 1,047,552 sectors
  (the last 512 KiB are hidden, [I] the BBT), 128 KiB blocks, 2 KiB pages,
  16-bit ECC. It names the maker "TOSHIBA", a lookup-table quirk.
- `ld` still says `Maskrom` after `db`; the usbplug keeps the BootROM's
  USB ID.

| Block | Offset | Contents |
|---|---|---|
| 0 | `0x000000` | **GPT** (protective MBR + `EFI PART`) with the same 8 partitions as the kernel's `mtdparts` (`userdata` ends at `0x1ff7be00`). U-Boot uses it; Linux uses the cmdline |
| 1–3 | `0x020000` | IDB copy 1 (`RKNS`) |
| 4–6 | `0x080000` | IDB copy 2, identical to copy 1 |
| 7–15 | `0x0e0000` | erased |

- `RKNS` header (new IDB format): header size 384, 2 images, `boot_flag =
  0x1` = **SHA-256 hash, no signature**. Image 0 at `+0x800`, `0xd800`
  bytes (DDR init: `DDR V1.16 6f71c736ce typ 23/03/02-20:01:48`); image 1
  at `+0xe000`, `0x3b000` bytes (U-Boot SPL with `rk_nandc_v9` + MTD). Both
  image hashes match. [C]
- The SPL reads a secure-OTP "verified-boot" flag (`## Verified-boot: %d`,
  `Can't read verified-boot flag`) and contains secure-OTP **write**
  functions (`rk3568_secure_otp_write_2_bytes`). [I] That's Rockchip's
  key-burn path: a signed FIT with `burn-key-hash` makes the SPL fuse the
  key hash and turn on secure boot for good. Never boot a signed FIT on
  this robot.
- So the brick-critical region is blocks 0–6 (GPT + both IDBs) plus the
  `uboot` partition. A raw image of the whole NAND (`rl 0 0xffc00`) backs
  all of it up.

### boot (mtd5) and recovery (mtd4)

- Both are Android boot images v0 (`ANDROID!`), page size 2048, empty
  cmdline in the header (U-Boot supplies it). `boot`: kernel `0x817a7e`
  bytes, no ramdisk, second stage `0x26400` (Rockchip resource image, i.e.
  the DTB). `recovery`: kernel `0x81f5c0`, ramdisk `0x6e2973`, second
  `0x24600`. [C]
- **No AVB footer** (`AVBf`) or `AVB0` vbmeta in either, and no vbmeta
  partition exists, so nothing verifies them. Matches `orange`. [C]

### misc (mtd2) and license (mtd3)

- `misc` is all zero except a leftover path at offset `0x4344`:
  `/userdata/midea_rk_update_ota.img`. That's the stock OTA image name from
  an earlier update; the BCB command itself is cleared. [C]
- `license` is entirely `0xff` (erased). Nothing uses it on this unit. [C]

## Per-device data

- **vnvm (mtd0)** = MTD vendor storage (`mtd vendor storage:20200313 ret = 0`).
  Per `midea_licrw` help: Wi-Fi MAC (ID 2), Midea cloud license (ID 16),
  Meizhi/Tuya product ID, UUID and auth key (IDs 12–14). Readers:
  `vendor_storage`, `midea_licrw`, `iot_node*`, `midea_robot`,
  `libmziot.so`. A copy of the license is also at `/oem/midea/device.lic`.
- **license (mtd3):** no Linux reader found, and the partition is empty
  (all `0xff`) on the examined unit.
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

1. Back up, read-only, and keep it outside the repo (vnvm holds the MAC,
   license and keys, so it doesn't belong in `dumps/` either):

   ```sh
   R="root@<robot-ip>"
   B=~/j15-backup/$(date +%Y%m%d) && mkdir -p "$B" && cd "$B"
   ssh $R 'cat /proc/mtd; ls -l /dev/mtd* /dev/ubi*; cat /proc/cmdline; ubinfo -a' > inventory.txt
   for n in 0 1 2 3 4 5; do ssh $R "nanddump -q --bb=padbad /dev/mtd$n" > mtd$n.bin; done
   ssh $R 'cat /dev/ubiblock0_0' > rootfs.squashfs
   ssh $R 'tar -cf - /oem' > oem.tar
   ssh $R 'for n in 0 1 2 3 4 5; do nanddump -q --bb=padbad /dev/mtd$n | sha256sum; done; sha256sum /dev/ubiblock0_0' > robot.sha256
   shasum -a 256 mtd?.bin rootfs.squashfs | awk '{print $1}' | diff - <(awk '{print $1}' robot.sha256) && echo "checksums OK"
   ```

   `padbad` keeps offsets intact across bad blocks, so an image can be
   written back 1:1.
2. Never write the IDBlock, `uboot`, `vnvm`, `license` or any OTP.
3. Leave the recovery partition stock, so the stock update path keeps
   working as a fallback.
4. Have a way in that doesn't depend on Linux: confirm the micro-USB
   `rockusb`/MaskROM path and/or the 1.5 Mbaud UART **before** the first
   flash.

## Open questions / next steps

- Done 2026-11-04: `uboot` dump analysed (unsigned FIT, rockusb/BootROM
  download modes, ADC download key, hotkeys); `/proc/mtd` and `/dev/mtd*`
  checked.
- Test whether `RESTART2 "loader"` brings up U-Boot rockusb on a computer
  (`rkdeveloptool ld`, expect `Loader`, VID `0x2207`).
- Find the UART2 pads, SARADC channel 0 (download key) and the MaskROM
  short point on the main board.
- Done 2026-11-04: MaskROM from Linux, unsigned loader accepted, IDBlock
  read and decoded (unsigned).
- Take a full raw NAND image over USB (`rl 0 0xffc00`, 511.5 MiB) as the
  ultimate restore point.
- Confirm rkdeveloptool NAND support on RK356x with a stock loader.

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
| first 2 MiB (GPT + IDB, `rl 0 0x1000`) | `f512e522a9a3459f64ce7f12647a1e6373c260b4b7b271e4d4346ce5ec85f70d` |
| `uboot` partition dump (mtd1, 6 MiB) | `59ea6604a400ce3eef8857ed6f30755d3d580f7114e8c7f64c5112f36472cfcb` |

The FIT header and U-Boot DTB were decoded with
[`tools/fdt2dts.py`](../tools/fdt2dts.py) (FIT is a flattened device tree;
the DTB sits at FIT `data-position` `0x1d0e00`).
