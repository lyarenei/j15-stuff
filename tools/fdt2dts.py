#!/usr/bin/env python3
"""Dump a flattened device tree blob (.dtb) as readable text, without dtc.

    ssh root@<robot-ip> 'cat /sys/firmware/fdt' > dumps/devicetree.dtb
    tools/fdt2dts.py dumps/devicetree.dtb > dumps/devicetree.dts

Phandles are printed as raw numbers; search for `phandle = <0x..>` to
resolve them.
"""

import struct
import sys


def fmt(v):
    if v and v[-1] == 0 and all(32 <= c < 127 or c == 0 for c in v[:-1]) and b"\0\0" not in v:
        return " = " + ", ".join('"%s"' % x.decode() for x in v[:-1].split(b"\0")) + ";"
    if not v:
        return ";"
    if len(v) % 4 == 0:
        return " = <" + " ".join("0x%x" % x for x in struct.unpack(">%dI" % (len(v) // 4), v)) + ">;"
    return " = [" + " ".join("%02x" % c for c in v) + "];"


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    d = open(sys.argv[1], "rb").read()
    magic, _, off_struct, off_str = struct.unpack(">4I", d[:16])
    if magic != 0xD00DFEED:
        sys.exit("not a flattened device tree")

    def name_at(o):
        e = d.index(b"\0", off_str + o)
        return d[off_str + o : e].decode()

    p, depth = off_struct, 0
    while True:
        tok, = struct.unpack(">I", d[p : p + 4])
        p += 4
        if tok == 1:  # FDT_BEGIN_NODE
            e = d.index(b"\0", p)
            print("  " * depth + (d[p:e].decode() or "/") + " {")
            p = (e + 4) & ~3
            depth += 1
        elif tok == 2:  # FDT_END_NODE
            depth -= 1
            print("  " * depth + "};")
        elif tok == 3:  # FDT_PROP
            ln, no = struct.unpack(">II", d[p : p + 8])
            p += 8
            print("  " * depth + name_at(no) + fmt(d[p : p + ln]))
            p = (p + ln + 3) & ~3
        elif tok == 9:  # FDT_END
            break


if __name__ == "__main__":
    main()
