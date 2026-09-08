#!/usr/bin/python3
# <xbar.title>Memory</xbar.title>
# <xbar.version>1.0</xbar.version>
# <xbar.author>David Pena</xbar.author>
# <xbar.desc>Memory used vs. installed, Activity Monitor style, with six menu bar looks.</xbar.desc>
# <xbar.dependencies>python3</xbar.dependencies>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideSwiftBar>false</swiftbar.hideSwiftBar>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>
"""
Memory menu bar item for SwiftBar.

"Used" matches Activity Monitor: app memory (anonymous - purgeable) + wired
+ compressed. Six looks for the menu bar, switchable from the dropdown:

  text     memorychip  30.4 GB / 36 GB
  percent  memorychip  84%
  bar      [======  ]  30.4 GB          rendered pill, colored by pressure
  ring     (o)  30 / 36                 rendered ring gauge
  graph    /\/\__/  84%                 rendered sparkline of the last hour
  icon     memorychip                   symbol only, tinted by pressure

All graphics are drawn in pure Python (no PIL) as retina PNGs.

  memory.5s.py                    # SwiftBar entry point
  memory.5s.py --set style bar    # switch look (used by the dropdown)
  memory.5s.py --dump DIR         # write rendered PNGs to DIR for inspection
"""
import base64
import json
import math
import os
import re
import struct
import subprocess
import sys
import time
import zlib

# --------------------------------------------------------------------------- #
# Configuration / state
# --------------------------------------------------------------------------- #

CONFIG_DIR = os.path.expanduser("~/.config/mac-utilities")
CONFIG_PATH = os.path.join(CONFIG_DIR, "memory-menubar.json")
CACHE_DIR = os.path.expanduser("~/.cache/mac-utilities")
HISTORY_PATH = os.path.join(CACHE_DIR, "memory-history.txt")
HISTORY_KEEP = 720            # samples kept (1 hour at 5 s)
GRAPH_WINDOW_S = 60 * 60      # seconds shown in the sparkline

STYLES = [
    ("text", "Text", "30.4 GB / 36 GB"),
    ("percent", "Percent", "84%"),
    ("bar", "Bar", "pill gauge + GB"),
    ("ring", "Ring", "ring gauge + GB"),
    ("graph", "Graph", "last hour sparkline + %"),
    ("icon", "Icon only", "symbol tinted by pressure"),
]
DEFAULT_CONFIG = {"style": "text"}

GiB = float(1 << 30)


def load_config():
    cfg = dict(DEFAULT_CONFIG)
    try:
        with open(CONFIG_PATH) as fh:
            cfg.update(json.load(fh))
    except (OSError, ValueError):
        pass
    if cfg["style"] not in [s[0] for s in STYLES]:
        cfg["style"] = DEFAULT_CONFIG["style"]
    return cfg


def save_config(cfg):
    os.makedirs(CONFIG_DIR, exist_ok=True)
    tmp = CONFIG_PATH + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(cfg, fh, indent=2)
    os.replace(tmp, CONFIG_PATH)


def append_history(pct):
    """Keep a rolling log of 'epoch pct' lines; returns the recent samples."""
    now = int(time.time())
    rows = []
    try:
        with open(HISTORY_PATH) as fh:
            for line in fh:
                parts = line.split()
                if len(parts) == 2:
                    rows.append((int(parts[0]), float(parts[1])))
    except (OSError, ValueError):
        rows = []
    rows.append((now, pct))
    rows = rows[-HISTORY_KEEP:]
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        tmp = HISTORY_PATH + ".tmp"
        with open(tmp, "w") as fh:
            fh.write("".join("%d %.1f\n" % r for r in rows))
        os.replace(tmp, HISTORY_PATH)
    except OSError:
        pass
    return [r for r in rows if now - r[0] <= GRAPH_WINDOW_S]


# --------------------------------------------------------------------------- #
# Memory statistics
# --------------------------------------------------------------------------- #

def sh(*cmd):
    return subprocess.run(cmd, capture_output=True, text=True).stdout


def read_memory():
    total = int(sh("sysctl", "-n", "hw.memsize").strip() or 0)

    vm = sh("vm_stat")
    m = re.search(r"page size of (\d+) bytes", vm)
    page = int(m.group(1)) if m else 16384
    pages = {}
    for line in vm.splitlines()[1:]:
        if ":" not in line:
            continue
        key, val = line.split(":", 1)
        val = val.strip().rstrip(".")
        if val.isdigit():
            pages[key.strip().strip('"')] = int(val) * page

    anon = pages.get("Anonymous pages", 0)
    purgeable = pages.get("Pages purgeable", 0)
    wired = pages.get("Pages wired down", 0)
    compressed = pages.get("Pages occupied by compressor", 0)
    cached = pages.get("File-backed pages", 0)

    app = max(anon - purgeable, 0)
    used = app + wired + compressed
    free = max(total - used - cached, 0)

    level = sh("sysctl", "-n", "kern.memorystatus_vm_pressure_level").strip()
    pressure = {"1": "normal", "2": "warning", "4": "critical"}.get(level, "normal")

    swap_total = swap_used = 0.0
    sw = sh("sysctl", "-n", "vm.swapusage")
    m = re.search(r"total = ([\d.]+)M\s+used = ([\d.]+)M", sw)
    if m:
        swap_total = float(m.group(1)) * (1 << 20)
        swap_used = float(m.group(2)) * (1 << 20)

    return {
        "total": total, "used": used, "app": app, "wired": wired,
        "compressed": compressed, "cached": cached, "free": free,
        "pct": (100.0 * used / total) if total else 0.0,
        "pressure": pressure, "swap_total": swap_total, "swap_used": swap_used,
    }


def top_processes(n=6):
    """Resident memory grouped by app (helpers folded into their parent)."""
    groups = {}
    for line in sh("ps", "-Aceo", "rss=,comm=").splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) != 2 or not parts[0].isdigit():
            continue
        rss = int(parts[0]) * 1024
        name = re.sub(r"\s+Helper.*$", "", parts[1]).strip()
        name = re.sub(r"^com\.apple\.", "", name)
        g = groups.setdefault(name, [0, 0])
        g[0] += rss
        g[1] += 1
    rows = sorted(groups.items(), key=lambda kv: kv[1][0], reverse=True)
    return [(name, rss, count) for name, (rss, count) in rows[:n]]


def gb(nbytes, decimals=1):
    v = nbytes / GiB
    if decimals == 0 or abs(v - round(v)) < 0.05:
        return "%d" % round(v)
    return "%.*f" % (decimals, v)


# --------------------------------------------------------------------------- #
# Tiny anti-aliased PNG renderer (pure Python)
# --------------------------------------------------------------------------- #

class Canvas:
    """RGBA canvas in points; rasterised at `scale`x with `ss`x`ss` supersampling."""

    def __init__(self, w_pt, h_pt, scale=2, ss=3):
        self.scale, self.ss = scale, ss
        self.w, self.h = int(round(w_pt * scale)), int(round(h_pt * scale))
        self.px = [[0.0, 0.0, 0.0, 0.0] for _ in range(self.w * self.h)]
        self._offs = [(i + 0.5) / ss for i in range(ss)]

    def _blend(self, p, color, cov):
        r, g, b, a = color
        sa = a * cov
        if sa <= 0:
            return
        da = p[3]
        oa = sa + da * (1 - sa)
        p[0] = (r * sa + p[0] * da * (1 - sa)) / oa
        p[1] = (g * sa + p[1] * da * (1 - sa)) / oa
        p[2] = (b * sa + p[2] * da * (1 - sa)) / oa
        p[3] = oa

    def fill(self, inside, color, bbox, inner=None):
        """inside(x, y) -> bool in point space. `inner` = bbox known to be fully covered."""
        s, n = self.scale, self.ss * self.ss
        X0, Y0 = max(0, int(math.floor(bbox[0] * s))), max(0, int(math.floor(bbox[1] * s)))
        X1, Y1 = min(self.w, int(math.ceil(bbox[2] * s))), min(self.h, int(math.ceil(bbox[3] * s)))
        if inner:
            ix0, iy0 = int(math.ceil(inner[0] * s)), int(math.ceil(inner[1] * s))
            ix1, iy1 = int(math.floor(inner[2] * s)), int(math.floor(inner[3] * s))
        for Y in range(Y0, Y1):
            row = Y * self.w
            for X in range(X0, X1):
                if inner and ix0 <= X < ix1 and iy0 <= Y < iy1:
                    self._blend(self.px[row + X], color, 1.0)
                    continue
                c = 0
                for oy in self._offs:
                    py = (Y + oy) / s
                    for ox in self._offs:
                        if inside((X + ox) / s, py):
                            c += 1
                if c:
                    self._blend(self.px[row + X], color, c / n)

    def mask(self, inside, bbox):
        """Multiply alpha by coverage of a shape (used to round the ends of a stacked bar)."""
        s, n = self.scale, self.ss * self.ss
        for Y in range(self.h):
            row = Y * self.w
            for X in range(self.w):
                p = self.px[row + X]
                if p[3] == 0:
                    continue
                c = 0
                for oy in self._offs:
                    py = (Y + oy) / s
                    for ox in self._offs:
                        if inside((X + ox) / s, py):
                            c += 1
                p[3] *= c / n

    # ---- shapes ---------------------------------------------------------- #

    def rounded_rect(self, x, y, w, h, r, color):
        r = min(r, w / 2, h / 2)
        x1, y1 = x + w, y + h

        def inside(px, py):
            if px < x or px > x1 or py < y or py > y1:
                return False
            dx = max(x + r - px, px - (x1 - r), 0.0)
            dy = max(y + r - py, py - (y1 - r), 0.0)
            return dx * dx + dy * dy <= r * r

        self.fill(inside, color, (x, y, x1, y1), inner=(x + r, y + r, x1 - r, y1 - r))

    def rect(self, x, y, w, h, color):
        x1, y1 = x + w, y + h
        self.fill(lambda px, py: x <= px <= x1 and y <= py <= y1, color,
                  (x, y, x1, y1), inner=(x, y, x1, y1))

    def ring(self, cx, cy, ro, ri, frac, color, caps=True):
        """Arc from 12 o'clock clockwise covering `frac` of the circle."""
        frac = max(0.0, min(1.0, frac))
        if frac <= 0:
            return
        end = frac * 2 * math.pi
        rm, rc = (ro + ri) / 2, (ro - ri) / 2
        ex, ey = cx + rm * math.sin(end), cy - rm * math.cos(end)

        def inside(px, py):
            dx, dy = px - cx, py - cy
            d2 = dx * dx + dy * dy
            if ri * ri <= d2 <= ro * ro:
                ang = math.atan2(dx, -dy)
                if ang < 0:
                    ang += 2 * math.pi
                if ang <= end or frac >= 1.0:
                    return True
            if caps and frac < 1.0:
                if dx * dx + (py - (cy - rm)) ** 2 <= rc * rc:
                    return True
                if (px - ex) ** 2 + (py - ey) ** 2 <= rc * rc:
                    return True
            return False

        self.fill(inside, color, (cx - ro, cy - ro, cx + ro, cy + ro))

    def area(self, xs, ys, baseline, color):
        """Fill under a polyline (xs ascending)."""
        def yat(px):
            if px <= xs[0]:
                return ys[0]
            if px >= xs[-1]:
                return ys[-1]
            lo, hi = 0, len(xs) - 1
            while hi - lo > 1:
                mid = (lo + hi) // 2
                if xs[mid] <= px:
                    lo = mid
                else:
                    hi = mid
            t = (px - xs[lo]) / (xs[hi] - xs[lo] or 1)
            return ys[lo] + t * (ys[hi] - ys[lo])

        self.fill(lambda px, py: yat(px) <= py <= baseline, color,
                  (xs[0], min(ys), xs[-1], baseline))

    def line(self, xs, ys, width, color):
        """Stroke a polyline (approximate distance-to-segment test)."""
        hw = width / 2

        def inside(px, py):
            for i in range(len(xs) - 1):
                x0, y0, x1, y1 = xs[i], ys[i], xs[i + 1], ys[i + 1]
                if px < min(x0, x1) - hw or px > max(x0, x1) + hw:
                    continue
                vx, vy = x1 - x0, y1 - y0
                l2 = vx * vx + vy * vy or 1e-9
                t = max(0.0, min(1.0, ((px - x0) * vx + (py - y0) * vy) / l2))
                dx, dy = px - (x0 + t * vx), py - (y0 + t * vy)
                if dx * dx + dy * dy <= hw * hw:
                    return True
            return False

        self.fill(inside, color, (xs[0] - hw, min(ys) - hw, xs[-1] + hw, max(ys) + hw))

    # ---- output ---------------------------------------------------------- #

    def png(self):
        raw = bytearray()
        for Y in range(self.h):
            raw.append(0)
            for X in range(self.w):
                r, g, b, a = self.px[Y * self.w + X]
                raw += bytes((int(r * 255 + 0.5), int(g * 255 + 0.5),
                              int(b * 255 + 0.5), int(a * 255 + 0.5)))

        def chunk(tag, data):
            body = tag + data
            return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

        ppm = int(round(72 * self.scale / 0.0254))  # pixels per metre => NSImage sizes in points
        return (b"\x89PNG\r\n\x1a\n"
                + chunk(b"IHDR", struct.pack(">IIBBBBB", self.w, self.h, 8, 6, 0, 0, 0))
                + chunk(b"pHYs", struct.pack(">IIB", ppm, ppm, 1))
                + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
                + chunk(b"IEND", b""))

    def b64(self):
        return base64.b64encode(self.png()).decode("ascii")


# --------------------------------------------------------------------------- #
# Palette
# --------------------------------------------------------------------------- #

def rgb(hexstr, a=1.0):
    return (int(hexstr[0:2], 16) / 255, int(hexstr[2:4], 16) / 255, int(hexstr[4:6], 16) / 255, a)


def appearance():
    ap = os.environ.get("OS_APPEARANCE")
    if not ap:
        ap = "Dark" if "Dark" in sh("defaults", "read", "-g", "AppleInterfaceStyle") else "Light"
    return ap


class Palette:
    def __init__(self, dark):
        fg = "ffffff" if dark else "000000"
        self.fg = rgb(fg)
        self.track = rgb(fg, 0.22)
        self.soft = rgb(fg, 0.30)
        self.blue = rgb("0a84ff" if dark else "007aff")
        self.orange = rgb("ff9f0a" if dark else "ff9500")
        self.purple = rgb("bf5af2" if dark else "af52de")
        self.red = rgb("ff453a" if dark else "ff3b30")
        self.green = rgb("30d158" if dark else "34c759")
        self.gray = rgb("8e8e93", 0.55)
        self.hex = {
            "app": "#0a84ff" if dark else "#007aff",
            "wired": "#ff9f0a" if dark else "#ff9500",
            "compressed": "#bf5af2" if dark else "#af52de",
            "cached": "#8e8e93",
            "free": "#8e8e93",
            "green": "#30d158" if dark else "#34c759",
            "orange": "#ff9f0a" if dark else "#ff9500",
            "red": "#ff453a" if dark else "#ff3b30",
        }

    def pressure_color(self, pressure):
        return {"warning": self.orange, "critical": self.red}.get(pressure, self.fg)

    def pressure_hex(self, pressure):
        return {"warning": self.hex["orange"], "critical": self.hex["red"]}.get(pressure, self.hex["green"])


# --------------------------------------------------------------------------- #
# Renderers
# --------------------------------------------------------------------------- #

def render_bar(mem, pal):
    w, h = 26.0, 16.0
    c = Canvas(w, h)
    bh, r = 7.0, 3.5
    y = (h - bh) / 2
    c.rounded_rect(0, y, w, bh, r, pal.track)
    fill_w = max(bh, w * mem["pct"] / 100.0)
    c.rounded_rect(0, y, fill_w, bh, r, pal.pressure_color(mem["pressure"]))
    return c


def render_ring(mem, pal):
    s = 16.0
    c = Canvas(s, s)
    cx = cy = s / 2
    ro, ri = 7.5, 5.3
    c.ring(cx, cy, ro, ri, 1.0, pal.track, caps=False)
    c.ring(cx, cy, ro, ri, mem["pct"] / 100.0, pal.pressure_color(mem["pressure"]))
    return c


def render_graph(samples, pal, pressure):
    w, h = 36.0, 16.0
    c = Canvas(w, h)
    top, bottom = 1.5, h - 1.5
    c.rounded_rect(0, bottom - 0.5, w, 1.0, 0.5, pal.track)
    if len(samples) < 2:
        return c
    t0, t1 = samples[0][0], samples[-1][0]
    span = float(max(t1 - t0, 1))
    xs = [1.0 + (w - 2.0) * (t - t0) / span for t, _ in samples]
    ys = [bottom - (bottom - top) * min(max(p, 0.0), 100.0) / 100.0 for _, p in samples]
    col = pal.pressure_color(pressure)
    c.area(xs, ys, bottom, (col[0], col[1], col[2], 0.28))
    c.line(xs, ys, 1.4, col)
    return c


def render_breakdown(mem, pal, width=250.0):
    h = 8.0
    c = Canvas(width, h)
    total = float(mem["total"] or 1)
    x = 0.0
    for key, col in (("app", pal.blue), ("wired", pal.orange),
                     ("compressed", pal.purple), ("cached", pal.gray), ("free", pal.track)):
        seg = width * mem[key] / total
        if seg > 0:
            c.rect(x, 0, seg, h, col)
            x += seg
    c.mask(lambda px, py: (0 <= px <= width and 0 <= py <= h and
                           (max(h / 2 - px, px - (width - h / 2), 0.0) ** 2
                            + (py - h / 2) ** 2 <= (h / 2) ** 2)), None)
    return c


# --------------------------------------------------------------------------- #
# Output
# --------------------------------------------------------------------------- #

def esc(s):
    return s.replace("|", "∣")


def title_line(style, mem, samples, pal):
    used, total = gb(mem["used"]), gb(mem["total"], 0)
    pct = "%d%%" % round(mem["pct"])
    tint = "" if mem["pressure"] == "normal" else " sfcolor=" + pal.pressure_hex(mem["pressure"])
    if style == "text":
        return "%s GB / %s GB | sfimage=memorychip%s" % (used, total, tint)
    if style == "percent":
        return "%s | sfimage=memorychip%s" % (pct, tint)
    if style == "icon":
        return " | sfimage=memorychip sfsize=15%s" % tint
    if style == "bar":
        return "%s GB | image=%s" % (used, render_bar(mem, pal).b64())
    if style == "ring":
        return "%s / %s | image=%s" % (used, total, render_ring(mem, pal).b64())
    if style == "graph":
        return "%s | image=%s" % (pct, render_graph(samples, pal, mem["pressure"]).b64())
    return "%s GB / %s GB" % (used, total)


def main():
    argv = sys.argv[1:]

    if len(argv) >= 3 and argv[0] == "--set":
        cfg = load_config()
        cfg[argv[1]] = argv[2]
        save_config(cfg)
        return

    dump_dir = None
    if len(argv) >= 2 and argv[0] == "--dump":
        dump_dir = argv[1]
        os.makedirs(dump_dir, exist_ok=True)

    cfg = load_config()
    mem = read_memory()
    samples = append_history(mem["pct"])
    pal = Palette(appearance() == "Dark")
    me = os.path.abspath(sys.argv[0])

    if dump_dir:
        for name, canvas in (("bar", render_bar(mem, pal)), ("ring", render_ring(mem, pal)),
                             ("graph", render_graph(samples, pal, mem["pressure"])),
                             ("breakdown", render_breakdown(mem, pal))):
            with open(os.path.join(dump_dir, name + ".png"), "wb") as fh:
                fh.write(canvas.png())

    out = []
    out.append(title_line(cfg["style"], mem, samples, pal))
    out.append("---")

    # Header ------------------------------------------------------------- #
    out.append("%s GB used of %s GB | size=15" % (gb(mem["used"]), gb(mem["total"], 0)))
    pressure_label = {"normal": "Normal", "warning": "Warning", "critical": "Critical"}[mem["pressure"]]
    pressure_sym = {"normal": "gauge.with.dots.needle.33percent",
                    "warning": "gauge.with.dots.needle.67percent",
                    "critical": "gauge.with.dots.needle.100percent"}[mem["pressure"]]
    out.append("Memory pressure: %s  ·  %d%% in use | sfimage=%s sfcolor=%s"
               % (pressure_label, round(mem["pct"]), pressure_sym, pal.pressure_hex(mem["pressure"])))
    out.append(" | image=%s" % render_breakdown(mem, pal).b64())

    # Breakdown ---------------------------------------------------------- #
    out.append("---")
    for key, label in (("app", "App Memory"), ("wired", "Wired Memory"),
                       ("compressed", "Compressed"), ("cached", "Cached Files"), ("free", "Free")):
        sym = "circle.fill" if key != "free" else "circle"
        out.append("%-16s%6s GB | sfimage=%s sfcolor=%s font=Menlo size=12"
                   % (label, gb(mem[key]), sym, pal.hex[key]))
    if mem["swap_total"] > 0:
        swap_col = pal.hex["red"] if mem["swap_used"] / mem["swap_total"] > 0.8 else pal.hex["cached"]
        out.append("%-16s%6s GB of %s GB | sfimage=arrow.left.arrow.right.circle sfcolor=%s font=Menlo size=12"
                   % ("Swap Used", gb(mem["swap_used"]), gb(mem["swap_total"]), swap_col))

    # Top processes ------------------------------------------------------ #
    out.append("---")
    out.append("Top Processes | size=11 color=gray")
    for name, rss, count in top_processes():
        suffix = "  ×%d" % count if count > 1 else ""
        short = name if len(name) <= 24 else name[:23] + "…"
        out.append("%-24s%6s GB%s | font=Menlo size=12 trim=false"
                   % (esc(short), gb(rss), suffix))

    # Style picker ------------------------------------------------------- #
    out.append("---")
    out.append("Menu Bar Style | sfimage=paintpalette")
    for key, label, hint in STYLES:
        checked = " checked=true" if key == cfg["style"] else ""
        out.append("--%s | bash=\"%s\" param1=--set param2=style param3=%s terminal=false refresh=true "
                   "tooltip=\"%s\"%s" % (label, me, key, hint, checked))

    # Actions ------------------------------------------------------------ #
    out.append("---")
    out.append("Open Activity Monitor | sfimage=waveform.path.ecg.rectangle "
               "bash=/usr/bin/open param1=-a param2=\"Activity Monitor\" terminal=false")
    out.append("Refresh | sfimage=arrow.clockwise refresh=true")

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
