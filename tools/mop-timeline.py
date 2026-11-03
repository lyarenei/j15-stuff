#!/usr/bin/env python3
"""Print a timeline of mop-related events from J15 planner/data logs.

Inputs can be log files (.log or .log.gz), directories containing them, or a
.tar from `./install.sh collect-logs`. Only planner and data logs are read.

    tools/mop-timeline.py j15-logs-20261104-101500.tar
    tools/mop-timeline.py logs.tar --around "1104 10:12" --window 3
    tools/mop-timeline.py userdata/logs/app/planner --errors

See docs/mop-lift-investigation.md for what the messages mean.
"""

import argparse
import datetime
import gzip
import io
import os
import re
import sys
import tarfile

# glog line: I1102 20:44:55.621824   645] [COV] Class::Func - message
LINE_RE = re.compile(r"^([IWEF])(\d{4}) (\d\d:\d\d:\d\d)\.(\d+)\s+\d+\] (.*)$")

EVENTS = [
    # planner: state reported by the MCU
    r"_toPlannerMcuStatus - .*error=",
    r"_checkMopStatus - (left|right)_mop_lift_state:",
    r"_checkMopStatus - mop_stretch_state:",
    r"_checkMopStatus - is_mop_retract_up_action_finish:",
    r"ProcMopStatus - ",
    # planner: commands
    r"HandleMopUpDown - set motor action",
    r"SetMopSpeed - ",
    r"SetTurnPlateRaise - ",
    r"SetMopLiftUpInplace - ",
    r"SetMopStretchAction - ",
    r"SendMopCommandToMcu - ",
    r"SetLocalPlannerMopLift - ",
    r"_set_mop_lift - ",
    r"mop fail",
    # data_node
    r"RightMopRetractLock",
    r"left_mop_lift_up=",
    r"MopInOutStateCallBack",
    r"_mcuSetMopMotorActionCallback",
]
EVENT_RE = re.compile("|".join(EVENTS))
# "mop fail, change to Circular" is a wall-follow mode fallback, not a hardware
# fault, so it isn't treated as an error.
ERROR_RE = re.compile(r"error=|[Tt]imeout")
LOG_NAME_RE = re.compile(r"(^|/)(planner|data)\.\d{8}-\d{6}\.log(\.gz)?$")


def read_text(name, data):
    if name.endswith(".gz"):
        try:
            data = gzip.decompress(data)
        except (OSError, EOFError):
            # Logs rotated while the robot was running are often truncated.
            data = _gunzip_partial(data)
    return data.decode("utf-8", "replace")


def _gunzip_partial(data):
    out = io.BytesIO()
    try:
        with gzip.GzipFile(fileobj=io.BytesIO(data)) as f:
            while True:
                chunk = f.read(65536)
                if not chunk:
                    break
                out.write(chunk)
    except (OSError, EOFError):
        pass
    return out.getvalue()


def iter_sources(paths):
    for path in paths:
        if os.path.isdir(path):
            for root, _, files in os.walk(path):
                for f in sorted(files):
                    full = os.path.join(root, f)
                    if LOG_NAME_RE.search(full):
                        with open(full, "rb") as fh:
                            yield full, fh.read()
        elif tarfile.is_tarfile(path):
            with tarfile.open(path) as tar:
                for m in tar.getmembers():
                    if m.isfile() and LOG_NAME_RE.search(m.name):
                        yield m.name, tar.extractfile(m).read()
        else:
            with open(path, "rb") as fh:
                yield path, fh.read()


def parse(paths):
    seen = set()
    events = []
    for name, data in iter_sources(paths):
        source = "data" if "/data." in name or name.startswith("data.") else "planner"
        for line in read_text(name, data).splitlines():
            m = LINE_RE.match(line)
            if not m or not EVENT_RE.search(m.group(5)):
                continue
            key = (m.group(2), m.group(3), m.group(4), m.group(5))
            if key in seen:  # the same line can appear in overlapping log files
                continue
            seen.add(key)
            events.append((m.group(2), m.group(3), m.group(4), m.group(1), source, m.group(5)))
    events.sort()
    return events


def to_dt(mmdd, hms):
    # glog omits the year; one is assumed so times can be compared.
    return datetime.datetime.strptime(f"2000{mmdd} {hms}", "%Y%m%d %H:%M:%S")


def clean(msg):
    msg = re.sub(r"^\[[A-Z]+\] ", "", msg)
    return re.sub(r"\s+TaskId.*$", "", msg)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("paths", nargs="+", help="log files, directories or collect-logs .tar")
    ap.add_argument("--around", metavar="'MMDD HH:MM'", help="only show events near this time")
    ap.add_argument("--window", type=float, default=5, help="minutes before/after --around (default 5)")
    ap.add_argument("--errors", action="store_true", help="only show errors, failures and timeouts")
    args = ap.parse_args()

    events = parse(args.paths)
    if not events:
        sys.exit("no mop events found (expected planner.*.log[.gz] / data.*.log[.gz])")

    if args.around:
        mmdd, hm = args.around.split()
        center = to_dt(mmdd, hm + ":00")
        delta = datetime.timedelta(minutes=args.window)
        events = [e for e in events if abs(to_dt(e[0], e[1]) - center) <= delta]
    if args.errors:
        events = [e for e in events if ERROR_RE.search(e[5])]

    last, repeat = None, 0
    for mmdd, hms, us, level, source, msg in events:
        text = clean(msg)
        if text == last:
            repeat += 1
            continue
        if repeat:
            print(f"{'':24}(repeated {repeat}x)")
        repeat = 0
        last = text
        print(f"{mmdd} {hms}.{us[:3]} {level} {source:7} {text}")
    if repeat:
        print(f"{'':24}(repeated {repeat}x)")


if __name__ == "__main__":
    main()
