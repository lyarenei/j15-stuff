# Research workflow

How the findings in these docs were produced, so the analysis can be
repeated or extended on another firmware version.

## Keep dumps out of git

Firmware and log dumps contain Wi-Fi credentials, device keys, cloud tokens
and vendor binaries. Put them in `dumps/` in this repo, which is
gitignored, along with `*.tar`, `*.bin`, `*.dtb` and `*.h264`.

The maintainer's local `dumps/` (from the 2026-11 sessions) is laid out like
this:

| Path | Contents |
|---|---|
| `rootfs.tar` | `/etc /opt /usr /lib /bin /sbin` from the robot |
| `x2/` | full extraction of `rootfs.tar` (the binaries analysed) |
| `x/`, `x3/` | partial extractions (subsets of `x2/`) |
| `logs.tar`, `logs/` | `/userdata/logs` and `/var/log` before the camera fix, and its extraction |
| `dmesg.txt`, `dmesg-boot.txt` | `dmesg` after 37 days of uptime (camera broken), and right after a reboot |
| `devicetree.dtb`, `devicetree.dts` | live device tree, and its text form |
| `filelist.txt`, `ps.txt`, `mounts.txt`, `lsmod.txt` | inventory |
| `stream.bin` | first `camera_stream` dump (32-byte shared-memory descriptors) |
| `camstream-prototype/` | pre-repo version of `camstream` |

## Getting data off the robot

The robot's dropbear has no `scp`/`sftp`, so everything goes over plain ssh.

```sh
R="root@<robot-ip>"   # add -i <key> etc. as needed

# Filesystem (binaries, libraries, configs). /oem and /userdata hold device secrets.
ssh $R 'tar -cf - /etc /opt /usr /lib /bin /sbin 2>/dev/null' > dumps/rootfs.tar

# Logs (RAM-backed, lost at reboot) + dmesg
./install.sh collect-logs <robot-ip>

# Live device tree
ssh $R 'cat /sys/firmware/fdt' > dumps/devicetree.dtb

# Inventory
ssh $R 'ps w; mount; df -h; lsmod; ls -la /tmp /dev/shm' > dumps/inventory.txt
ssh $R 'find / \( -path /proc -o -path /sys -o -path /dev \) -prune -o -print' > dumps/filelist.txt
```

## Tools

| Task | Tool |
|---|---|
| Exported symbols (C++ class/method names) | `llvm-nm -D --defined-only <bin>` (`xcrun -f llvm-nm` on macOS) |
| Shared-library dependencies | `llvm-objdump -p <bin> \| grep NEEDED` |
| Disassembly | `llvm-objdump -d --no-show-raw-insn <bin>` |
| Decompiling | Hopper / Ghidra (used via the REA MCP server in these sessions) |
| Log strings | `strings -a -n 6 <bin> \| grep ...` |
| Device tree | [`tools/fdt2dts.py`](../tools/fdt2dts.py) turns the `.dtb` into text (no `dtc` needed) |
| Cross-compiling | `zig cc -target aarch64-linux-gnu.2.17` (see the README's Building section) |

## Techniques that worked

**Start from log strings.** The firmware logs almost everything with the
function name (`MopCommand::SetMopSpeed - ...`). Search a string, find its
references in the disassembly, and you land in the right function.

**Watch `/tmp` and `/dev/shm`.** Every IPC topic is a socket in `/tmp`.
Shared-memory topics also have a buffer in `/dev/shm`. Comparing listings
before and after triggering something (for example `start_push`) shows which
topics it uses. The buffer size is `2 × data_size + 64`.

**Dump before decoding.** A tiny subscriber that saves raw messages to a
file (the first version of `camstream -d` did exactly this) shows the real
message layout faster than static analysis. That's how the 32-byte shared-memory descriptor was
found.

**Find struct layouts at the allocation site.** Search the disassembly for
the struct size as an immediate (`mov x0, #0x24; movk x0, #0x10, lsl #16`
for `0x100024`), then read the stores into the new object. This is how the
`VideoFrame` offsets were found.

**Reading static tables from the ELF.** For example, the planner's
MCU-to-planner enum maps are arrays of `(int, int)` pairs passed to
`std::unordered_map` constructors. Find the constructor call, work out the
array address from the `adrp`/`add` pair and the copy length, then read it:

```python
import struct
d = open("planner_node", "rb").read()
phoff, = struct.unpack_from("<Q", d, 0x20)
phentsize, phnum = struct.unpack_from("<HH", d, 0x36)
segs = []
for i in range(phnum):
    t, _, off, va, _, fsz, _, _ = struct.unpack_from("<IIQQQQQQ", d, phoff + i * phentsize)
    if t == 1:  # PT_LOAD
        segs.append((va, off, fsz))

def read(va, n):
    for v, o, s in segs:
        if v <= va < v + s:
            return d[o + va - v : o + va - v + n]

b = read(0x81a1f8, 13 * 8)  # MopStretchState map, 13 pairs
print([struct.unpack_from("<ii", b, i * 8) for i in range(13)])
```

**Analysing logs over time.** glog lines are
`<I|W|E|F>MMDD HH:MM:SS.micro <tid>] [<TAG>] Class::Func - message`. There's
no year, and rotated `.gz` files are often truncated (read as much as
decompresses). [`tools/mop-timeline.py`](../tools/mop-timeline.py) is an
example: it filters, sorts, de-duplicates and collapses repeats.

## Binaries examined

Addresses in these docs are for these exact builds:

| File | sha256 |
|---|---|
| `/usr/navi/video_node` | `e2b7334b8f4fe00ce9b095b3ae01985b8ec231bf26486341527c375e4939ffb2` |
| `/usr/navi/planner_node` | `8a3785620d62c74676b38f30b695da1eb616b61513a0a8f51f23458301c47669` |
| `/usr/lib/libsample_plugin.so` | `5b3fbca5d8421e71cdf0ffe893587ce089f7970507eacf97abfa0276d66480f1` |

Check with `sha256sum` on the robot before trusting any address.
