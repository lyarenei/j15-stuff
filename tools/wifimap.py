#!/usr/bin/env python3
"""Draw a Wi-Fi signal heatmap over the Valetudo map from wifimap samples.

Fetches the samples recorded by wifimap on the robot (over ssh) and the map
from Valetudo (over HTTP), and writes one self-contained HTML file.

    tools/wifimap.py 192.168.1.50
    tools/wifimap.py -o living.html --cell 20 192.168.1.50 -i ~/.ssh/robot -p 2222
    tools/wifimap.py --samples ./jobs --map map.json

Options of this tool go before the robot address; everything after the address
is passed to ssh unchanged.

See https://github.com/lyarenei/j15-stuff/wiki/wifi-heatmap-investigation for how it works.
"""

import argparse
import csv
import glob
import io
import json
import math
import os
import subprocess
import sys
import tarfile
import urllib.request

# Options that take a value, so the robot address can be told apart from them.
OWN_OPTIONS = {"-o", "--output", "--cell", "--offset-x", "--offset-y", "--job", "--samples", "--map"}

# A jump larger than this within JUMP_S seconds is the robot relocalising, not moving.
JUMP_MM = 1500
JUMP_S = 2


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def split_args(argv):
    """Own options up to the robot address; the rest belongs to ssh."""
    own, i = [], 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            own.append(a)
        elif a in OWN_OPTIONS:
            own += argv[i:i + 2]
            i += 1
        elif a.startswith("--") and "=" in a and a.split("=", 1)[0] in OWN_OPTIONS:
            own.append(a)
        else:
            break
        i += 1
    return own, argv[i:]


def parse_job(text):
    rows = []
    for r in csv.DictReader(io.StringIO(text)):
        try:
            rows.append({
                "t": int(r["t"]),
                "x": int(r["x_mm"]),
                "y": int(r["y_mm"]),
                "dbm": int(float(r["dbm"])) if r["dbm"] not in ("", None) else None,
                "bssid": r["bssid"] or "",
            })
        except (KeyError, TypeError, ValueError):
            continue  # a half-written last line
    return rows


def fetch_jobs_ssh(robot, ssh_opts):
    cmd = ["ssh", *ssh_opts, "-o", "ConnectTimeout=10", f"root@{robot}",
           "cd /userdata/wifimap && tar -cf - job-*.csv"]
    p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if p.returncode != 0 or not p.stdout:
        die("could not read /userdata/wifimap on the robot (is wifimap installed, "
            "and has the robot cleaned since?): " + p.stderr.decode(errors="replace").strip())
    jobs = {}
    with tarfile.open(fileobj=io.BytesIO(p.stdout)) as tf:
        for m in tf.getmembers():
            if m.isfile():
                jobs[os.path.basename(m.name)] = parse_job(tf.extractfile(m).read().decode(errors="replace"))
    return jobs


def read_jobs_dir(path):
    jobs = {}
    for f in sorted(glob.glob(os.path.join(path, "job-*.csv"))):
        with open(f, encoding="utf-8", errors="replace") as fh:
            jobs[os.path.basename(f)] = parse_job(fh.read())
    if not jobs:
        die(f"no job-*.csv files in {path}")
    return jobs


def load_map(robot, path):
    if path:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    url = f"http://{robot}/api/v2/robot/state/map"
    try:
        with urllib.request.urlopen(url, timeout=15) as r:
            return json.load(r)
    except OSError as e:
        die(f"could not fetch the map from {url}: {e}")


def map_data(m):
    """Layers as run lists in map pixels, plus charger and pixel size in cm."""
    charger = None
    for e in m.get("entities", []):
        if e.get("type") == "charger_location" and e.get("points"):
            charger = e["points"][:2]
            break
    if charger is None:
        die("the map has no charger_location entity, so samples can't be placed")
    layers = []
    for layer in m.get("layers", []):
        kind = layer.get("type")
        if kind not in ("floor", "wall", "segment"):
            continue
        runs = list(layer.get("compressedPixels") or [])
        px = layer.get("pixels") or []
        for i in range(0, len(px) - 1, 2):
            runs += [px[i], px[i + 1], 1]
        name = (layer.get("metaData") or {}).get("name") or ""
        layers.append({"type": kind, "name": name, "runs": runs})
    return {"pixel_size": m.get("pixelSize", 5), "charger": charger, "layers": layers}


def build_samples(jobs, charger, off_x, off_y):
    """Samples in Valetudo cm: [x, y, dbm or null, bssid index, t]. Returns also the number dropped."""
    out, bssids, dropped = [], [], 0
    for name in sorted(jobs):
        rows, kept, prev = jobs[name], [], None
        for r in rows:
            jump = (prev is not None and r["t"] - prev["t"] <= JUMP_S
                    and math.hypot(r["x"] - prev["x"], r["y"] - prev["y"]) > JUMP_MM)
            prev = r
            if jump:
                dropped += 1
                continue
            if r["bssid"] and r["bssid"] not in bssids:
                bssids.append(r["bssid"])
            kept.append([
                round(charger[0] + off_x + r["x"] / 10, 1),
                round(charger[1] + off_y - r["y"] / 10, 1),
                r["dbm"],
                bssids.index(r["bssid"]) if r["bssid"] else -1,
                r["t"],
            ])
        if kept:
            out.append({"name": name, "samples": kept})
    return out, sorted(bssids), dropped


def main():
    own, rest = split_args(sys.argv[1:])
    ap = argparse.ArgumentParser(
        prog="wifimap.py",
        usage="wifimap.py [options] [robot-ip [ssh options...]]",
        description="Draw a Wi-Fi signal heatmap over the Valetudo map from wifimap samples.")
    ap.add_argument("-o", "--output", default="wifimap.html", help="output HTML file (default wifimap.html)")
    ap.add_argument("--cell", type=float, default=25, metavar="CM", help="heatmap cell size in cm (default 25)")
    ap.add_argument("--offset-x", type=float, default=40, metavar="CM", help="planner to map x offset from the charger (default 40)")
    ap.add_argument("--offset-y", type=float, default=5, metavar="CM", help="planner to map y offset from the charger (default 5)")
    ap.add_argument("--job", default="all", metavar="latest|NAME", help="job to show first (default: all jobs merged)")
    ap.add_argument("--samples", metavar="DIR", help="read job-*.csv from DIR instead of the robot")
    ap.add_argument("--map", metavar="FILE", help="read the map JSON from FILE instead of Valetudo")
    args = ap.parse_args(own)

    robot = rest[0] if rest else None
    ssh_opts = rest[1:]
    if (not args.samples or not args.map) and not robot:
        ap.error("robot address needed unless both --samples and --map are given")

    jobs = read_jobs_dir(args.samples) if args.samples else fetch_jobs_ssh(robot, ssh_opts)
    m = map_data(load_map(robot, args.map))
    jobs_out, bssids, dropped = build_samples(jobs, m["charger"], args.offset_x, args.offset_y)
    if not jobs_out:
        die("no usable samples")

    first = "all"
    if args.job != "all":
        names = [j["name"] for j in jobs_out]
        want = names[-1] if args.job == "latest" else args.job
        if want not in names and f"job-{want}.csv" in names:
            want = f"job-{want}.csv"
        if want not in names:
            die(f"no such job '{args.job}' (have: {', '.join(names)})")
        first = want

    data = {"map": m, "jobs": jobs_out, "bssids": bssids, "cell": args.cell, "first": first}
    page = TEMPLATE.replace("__DATA__", json.dumps(data, separators=(",", ":")).replace("</", "<\\/"))
    with open(args.output, "w", encoding="utf-8") as fh:
        fh.write(page)

    dbm = [s[2] for j in jobs_out for s in j["samples"] if s[2] is not None]
    total = sum(len(j["samples"]) for j in jobs_out)
    print(f"jobs: {len(jobs_out)}")
    print(f"samples: {total} ({total - len(dbm)} without a signal, {dropped} dropped as position jumps)")
    if dbm:
        print(f"dBm: {min(dbm)} to {max(dbm)}, mean {sum(dbm) / len(dbm):.1f}")
    print(f"access points: {len(bssids)}")
    print(f"wrote {args.output}. It contains your floor plan; don't publish it.")


TEMPLATE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Wi-Fi heatmap</title>
<style>
:root {
  --bg: #f6f6f8; --fg: #1c1d21; --muted: #5f6370; --card: #ffffff; --border: #d4d6dc;
  --floor: #e4e6ec; --wall: #2b2d33; --charger: #d9480f;
}
@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #15161a; --fg: #e8e9ed; --muted: #9a9eab; --card: #1e2025; --border: #34373f;
    --floor: #3a3d46; --wall: #c9ccd4; --charger: #ff922b;
  }
}
:root[data-theme="dark"] {
  --bg: #15161a; --fg: #e8e9ed; --muted: #9a9eab; --card: #1e2025; --border: #34373f;
  --floor: #3a3d46; --wall: #c9ccd4; --charger: #ff922b;
}
* { box-sizing: border-box; }
body { margin: 0; padding: 16px; background: var(--bg); color: var(--fg);
  font: 15px/1.45 system-ui, -apple-system, "Segoe UI", sans-serif; }
main { max-width: 1000px; margin: 0 auto; }
h1 { font-size: 20px; margin: 0 0 12px; }
.controls { display: flex; flex-wrap: wrap; gap: 8px 16px; margin-bottom: 12px; }
label { display: flex; flex-direction: column; font-size: 13px; color: var(--muted); gap: 2px; min-width: 0; }
select { font: inherit; color: var(--fg); background: var(--card); border: 1px solid var(--border);
  border-radius: 6px; padding: 6px 8px; max-width: 100%; }
.stage { position: relative; background: var(--card); border: 1px solid var(--border); border-radius: 8px; overflow: hidden; }
canvas { display: block; width: 100%; touch-action: pan-y; }
#tip { position: absolute; pointer-events: none; display: none; background: var(--card); color: var(--fg);
  border: 1px solid var(--border); border-radius: 6px; padding: 6px 8px; font-size: 13px;
  box-shadow: 0 2px 8px rgba(0,0,0,.25); white-space: nowrap; z-index: 2; }
#tip b { font-weight: 600; }
.legend { margin-top: 12px; }
.bar { height: 14px; border-radius: 4px; border: 1px solid var(--border); }
.ticks { position: relative; height: 18px; font-size: 12px; color: var(--muted); }
.ticks span { position: absolute; transform: translateX(-50%); }
.key { display: flex; flex-wrap: wrap; gap: 4px 16px; align-items: center; font-size: 13px; margin: 6px 0; }
.swatch { display: inline-block; width: 16px; height: 16px; vertical-align: -3px; margin-right: 6px;
  border: 1px solid var(--border); border-radius: 3px; }
.note, #stats { color: var(--muted); font-size: 13px; margin: 6px 0 0; }
</style>
</head>
<body>
<main>
<h1>Wi-Fi heatmap</h1>
<div class="controls">
  <label>Job <select id="job"></select></label>
  <label id="bssidBox" hidden>Access point <select id="bssid"></select></label>
</div>
<div class="stage"><canvas id="c"></canvas><div id="tip"></div></div>
<div class="legend">
  <div class="bar" id="bar"></div>
  <div class="ticks" id="ticks"></div>
  <div class="key">
    <span><i class="swatch" id="swNone"></i>no signal (hatched)</span>
    <span><i class="swatch" style="background:var(--charger)"></i>dock</span>
  </div>
  <p class="note">Mean signal per cell. At -67 dBm or better video calls and streams work well; at -80 dBm or worse the link is unreliable. Hatched cells contain samples where the robot had no Wi-Fi link.</p>
  <p id="stats"></p>
</div>
</main>
<script type="application/json" id="data">__DATA__</script>
<script>
"use strict";
const D = JSON.parse(document.getElementById("data").textContent);
const BAD = -90, GOOD = -30;
// viridis, low (bad) to high (good)
const STOPS = ["#440154", "#472d7b", "#3b528b", "#2c728e", "#21918c", "#28ae80", "#5ec962", "#addc30", "#fde725"];
const $ = id => document.getElementById(id);
const cv = $("c"), ctx = cv.getContext("2d"), tip = $("tip");
const css = n => getComputedStyle(document.documentElement).getPropertyValue(n).trim();

function rgb(hex) { return [1, 3, 5].map(i => parseInt(hex.substr(i, 2), 16)); }
const STOP_RGB = STOPS.map(rgb);
function colorAt(dbm) {
  const f = Math.min(1, Math.max(0, (dbm - BAD) / (GOOD - BAD))) * (STOPS.length - 1);
  const i = Math.min(STOPS.length - 2, Math.floor(f)), k = f - i;
  const c = STOP_RGB[i].map((v, j) => Math.round(v + (STOP_RGB[i + 1][j] - v) * k));
  return "rgb(" + c.join(",") + ")";
}

// Map geometry, in map pixels.
const PS = D.map.pixel_size;
let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
function grow(x, y) { x0 = Math.min(x0, x); y0 = Math.min(y0, y); x1 = Math.max(x1, x); y1 = Math.max(y1, y); }
for (const L of D.map.layers) {
  for (let i = 0; i + 2 < L.runs.length; i += 3) { grow(L.runs[i], L.runs[i + 1]); grow(L.runs[i] + L.runs[i + 2], L.runs[i + 1] + 1); }
}
for (const j of D.jobs) for (const s of j.samples) grow(s[0] / PS, s[1] / PS);
grow(D.map.charger[0] / PS, D.map.charger[1] / PS);
x0 = Math.floor(x0) - 4; y0 = Math.floor(y0) - 4; x1 = Math.ceil(x1) + 4; y1 = Math.ceil(y1) + 4;
const MW = x1 - x0, MH = y1 - y0;

let cells = new Map(), view = {scale: 1, w: 1, h: 1};

function select() {
  const jv = $("job").value, bv = $("bssid").value;
  const out = [];
  for (const j of D.jobs) {
    if (jv !== "all" && j.name !== jv) continue;
    for (const s of j.samples) if (bv === "all" || s[3] === +bv) out.push(s);
  }
  return out;
}

function aggregate(samples) {
  const m = new Map(), C = D.cell;
  for (const s of samples) {
    const cx = Math.floor(s[0] / C), cy = Math.floor(s[1] / C), key = cx + "," + cy;
    let c = m.get(key);
    if (!c) { c = {cx, cy, n: 0, sum: 0, nd: 0, min: 0, max: 0, none: 0, ap: new Map()}; m.set(key, c); }
    c.n++;
    if (s[2] === null) c.none++;
    else {
      if (c.nd === 0 || s[2] < c.min) c.min = s[2];
      if (c.nd === 0 || s[2] > c.max) c.max = s[2];
      c.sum += s[2]; c.nd++;
    }
    if (s[3] >= 0) c.ap.set(s[3], (c.ap.get(s[3]) || 0) + 1);
  }
  return m;
}

const mapCanvas = document.createElement("canvas");
mapCanvas.width = MW; mapCanvas.height = MH;
function drawMapLayer() {
  const g = mapCanvas.getContext("2d");
  g.clearRect(0, 0, MW, MH);
  for (const kind of ["floor", "segment", "wall"]) {
    g.fillStyle = kind === "wall" ? css("--wall") : css("--floor");
    for (const L of D.map.layers) {
      if (L.type !== kind) continue;
      for (let i = 0; i + 2 < L.runs.length; i += 3) g.fillRect(L.runs[i] - x0, L.runs[i + 1] - y0, L.runs[i + 2], 1);
    }
  }
}

function hatch() {
  const p = document.createElement("canvas"); p.width = p.height = 8;
  const g = p.getContext("2d");
  g.strokeStyle = css("--fg"); g.lineWidth = 1.5; g.globalAlpha = 0.75;
  g.beginPath(); g.moveTo(-2, 10); g.lineTo(10, -2); g.moveTo(-2, 2); g.lineTo(2, -2); g.moveTo(6, 10); g.lineTo(10, 6); g.stroke();
  return ctx.createPattern(p, "repeat");
}

function draw() {
  const dpr = window.devicePixelRatio || 1;
  const cssW = cv.parentElement.clientWidth, cssH = Math.round(cssW * MH / MW);
  cv.width = Math.round(cssW * dpr); cv.height = Math.round(cssH * dpr); cv.style.height = cssH + "px";
  const s = cv.width / MW;   // canvas px per map px
  view = {scale: s, w: cv.width, h: cv.height, dpr};
  ctx.setTransform(1, 0, 0, 1, 0, 0);
  ctx.clearRect(0, 0, cv.width, cv.height);
  ctx.imageSmoothingEnabled = false;
  ctx.drawImage(mapCanvas, 0, 0, cv.width, cv.height);

  const C = D.cell / PS * s, pat = hatch();
  for (const c of cells.values()) {
    const px = (c.cx * D.cell / PS - x0) * s, py = (c.cy * D.cell / PS - y0) * s;
    ctx.globalAlpha = 0.85;
    ctx.fillStyle = c.nd ? colorAt(c.sum / c.nd) : css("--muted");
    ctx.fillRect(px, py, C, C);
    ctx.globalAlpha = 1;
    if (c.none) { ctx.fillStyle = pat; ctx.fillRect(px, py, C, C); }
  }
  const ch = D.map.charger, r = Math.max(4 * dpr, 2.5 * s);
  ctx.fillStyle = css("--charger"); ctx.strokeStyle = css("--bg"); ctx.lineWidth = 2 * dpr;
  ctx.beginPath(); ctx.arc((ch[0] / PS - x0) * s, (ch[1] / PS - y0) * s, r, 0, 7); ctx.fill(); ctx.stroke();
}

function refresh() {
  const samples = select();
  cells = aggregate(samples);
  const d = samples.filter(s => s[2] !== null).map(s => s[2]);
  $("stats").textContent = samples.length + " samples in " + cells.size + " cells" +
    (d.length ? ", " + Math.min(...d) + " to " + Math.max(...d) + " dBm, mean " + (d.reduce((a, b) => a + b, 0) / d.length).toFixed(1) : "") +
    "; " + (samples.length - d.length) + " without a signal.";
  draw();
}

function setup() {
  const jobSel = $("job");
  const total = D.jobs.reduce((a, j) => a + j.samples.length, 0);
  jobSel.add(new Option("All jobs merged (" + D.jobs.length + ", " + total + " samples)", "all"));
  for (const j of D.jobs) {
    const t = j.samples[0][4];
    jobSel.add(new Option(new Date(t * 1000).toLocaleString() + " (" + j.samples.length + " samples)", j.name));
  }
  jobSel.value = D.first;
  if (D.bssids.length > 1) {
    $("bssidBox").hidden = false;
    $("bssid").add(new Option("All access points", "all"));
    D.bssids.forEach((b, i) => $("bssid").add(new Option(b, String(i))));
  } else {
    $("bssid").add(new Option("all", "all"));
  }
  jobSel.onchange = refresh; $("bssid").onchange = refresh;

  $("bar").style.background = "linear-gradient(to right," + STOPS.join(",") + ")";
  for (const v of [-90, -80, -67, -60, -50, -40, -30]) {
    const s = document.createElement("span");
    s.style.left = (v - BAD) / (GOOD - BAD) * 100 + "%"; s.textContent = v;
    $("ticks").appendChild(s);
  }
  $("ticks").lastChild.style.transform = "translateX(-100%)";
  $("ticks").firstChild.style.transform = "translateX(0)";
}

function theme() {
  drawMapLayer();
  $("swNone").style.background = css("--muted");
  refresh();
}

function point(e) {
  const r = cv.getBoundingClientRect();
  const mx = (e.clientX - r.left) / r.width * MW + x0, my = (e.clientY - r.top) / r.height * MH + y0;
  return {mx, my, r};
}
function show(e) {
  const {mx, my, r} = point(e);
  const c = cells.get(Math.floor(mx * PS / D.cell) + "," + Math.floor(my * PS / D.cell));
  if (!c) { tip.style.display = "none"; return; }
  const aps = [...c.ap.entries()].map(([i, n]) => D.bssids[i] + " (" + n + ")").join(", ");
  tip.innerHTML = (c.nd ? "<b>" + (c.sum / c.nd).toFixed(1) + " dBm</b> mean, " + c.min + " min, " + c.max + " max<br>" : "<b>no signal</b><br>") +
    c.n + " samples" + (c.none ? ", " + c.none + " without a signal" : "") + (aps ? "<br>" + aps : "");
  tip.style.display = "block";
  const x = e.clientX - r.left + 12, y = e.clientY - r.top + 12;
  tip.style.left = Math.max(0, Math.min(x, r.width - tip.offsetWidth)) + "px";
  tip.style.top = Math.max(0, Math.min(y, r.height - tip.offsetHeight)) + "px";
}
cv.addEventListener("pointermove", show);
cv.addEventListener("pointerdown", show);
cv.addEventListener("pointerleave", () => { tip.style.display = "none"; });

setup();
theme();
window.addEventListener("resize", draw);
window.matchMedia("(prefers-color-scheme: dark)").addEventListener("change", theme);
</script>
</body>
</html>
"""


if __name__ == "__main__":
    main()
