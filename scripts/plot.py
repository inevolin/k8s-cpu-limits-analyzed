#!/usr/bin/env python3
"""Regenerate assets/results-*.svg from results/run.jsonl.

stdlib only, deterministic (no timestamps, no randomness). Keeps the
hand-drawn house style: #faf9f6 background, monospace labels, thin axes,
value labels above/inside bars.

Run from anywhere:  python3 scripts/plot.py
"""
from __future__ import annotations

import json
import math
import os

FONT = "ui-monospace, SFMono-Regular, Menlo, monospace"
BG = "#faf9f6"
INK = "#111111"
AXIS = "#222222"
GRID = "#eeeeee"
TICK = "#cccccc"
MUTED = "#888888"
TRACK = "#e4ddd2"

# limit = red/danger, no-limit/request = green
LIMIT_COLOR = "#c4473a"  # red: 500m limit
OPEN_COLOR = "#5a9a5a"  # green: no limit

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RESULTS = os.path.join(ROOT, "results", "run.jsonl")
ASSETS = os.path.join(ROOT, "assets")


def load_rows():
    rows = []
    if not os.path.exists(RESULTS):
        return rows
    with open(RESULTS, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            rows.append(json.loads(line))
    return rows


def legs_by_job(rows):
    out = {}
    for r in rows:
        if r.get("kind") == "leg":
            out[r.get("job")] = r
    return out


def esc(s: str) -> str:
    return (
        str(s)
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


def text(x, y, s, size=11, fill=INK, extra=""):
    return (
        f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" '
        f'fill="{fill}" {extra}>{esc(s)}</text>'
    )


def rect(x, y, w, h, fill):
    return f'<rect x="{x:.1f}" y="{y:.1f}" width="{w:.1f}" height="{h:.1f}" fill="{fill}"/>'


def line(x1, y1, x2, y2, stroke, extra=""):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{stroke}" {extra}/>'


def legend(x, y, items):
    out = []
    cx = x
    for label, color in items:
        out.append(rect(cx, y, 12, 12, color))
        out.append(text(cx + 18, y + 10, label, size=11))
        cx += 18 + 12 + len(label) * 7 + 24
    return "\n  ".join(out)


def svg_wrap(width, height, body):
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}">\n'
        f'  <rect width="{width}" height="{height}" fill="{BG}"/>\n'
        f"  {body}\n"
        f"</svg>\n"
    )


def y_axis(x0, y0, y1, x1, y_max, step, unit):
    """Plot area x0..x1, y0 (top) .. y1 (bottom, baseline). y_max at top."""
    parts = [line(x0, y0, x0, y1, TICK), line(x0, y1, x1, y1, AXIS)]
    n_steps = int(round(y_max / step))
    for i in range(n_steps + 1):
        val = i * step
        y = y1 - (val / y_max) * (y1 - y0)
        if i == 0:
            parts.append(text(x0 - 24, y1 + 4, "0", size=10))
        else:
            parts.append(line(x0, y, x1, y, GRID))
            label = f"{val:g}"
            parts.append(text(x0 - 10 - len(label) * 6, y + 4, label, size=10))
    parts.append(
        text(
            x0 - 60,
            (y0 + y1) / 2,
            unit,
            size=10,
            fill=MUTED,
            extra=f'transform="rotate(-90 {x0 - 60} {(y0 + y1) / 2})"',
        )
    )
    return "\n  ".join(parts)


# ---------------------------------------------------------------------------
# results-burst.svg: latency CDF (two curves) if raw latencies are present,
# else fall back to the p50/p95/p99 bar-pair chart.
# ---------------------------------------------------------------------------

def cdf_points(latencies):
    if not latencies:
        return []
    xs = sorted(latencies)
    n = len(xs)
    return [(xs[i], (i + 1) / n) for i in range(n)]


def plot_burst(legs):
    limit = legs.get("burst-limit")
    openn = legs.get("burst-open")
    if limit is None or openn is None:
        return None

    lat_l = limit.get("latencies") or []
    lat_o = openn.get("latencies") or []

    if lat_l and lat_o:
        return plot_burst_cdf(limit, openn)
    return plot_burst_bars(limit, openn)


def plot_burst_cdf(limit, openn):
    width, height = 720, 320
    x0, x1 = 90, 680
    y0, y1 = 50, 250

    all_lat = (limit.get("latencies") or []) + (openn.get("latencies") or [])
    x_max = max(all_lat) if all_lat else 1.0
    # round up to a friendly bound
    x_max = math.ceil(x_max / 10.0) * 10.0 or 10.0

    body = [
        text(24, 28, "burst latency CDF  ·  ~400m offered, 500m cap", size=13),
    ]
    body.append(y_axis(x0, y0, y1, x1, 1.0, 0.25, "fraction"))

    # x-axis ticks (ms)
    x_step = x_max / 4.0
    for i in range(5):
        v = i * x_step
        x = x0 + (v / x_max) * (x1 - x0)
        body.append(line(x, y1, x, y1 + 5, AXIS))
        body.append(text(x - 6, y1 + 18, f"{v:g}", size=10))
    body.append(text((x0 + x1) / 2 - 30, height - 40, "latency (ms)", size=11, fill=MUTED))

    def curve(latencies, color):
        pts = cdf_points(latencies)
        if not pts:
            return ""
        coords = []
        for ms, frac in pts:
            x = x0 + (min(ms, x_max) / x_max) * (x1 - x0)
            y = y1 - frac * (y1 - y0)
            coords.append(f"{x:.1f},{y:.1f}")
        path = "M" + " L".join(coords)
        return f'<path d="{path}" fill="none" stroke="{color}" stroke-width="2"/>'

    body.append(curve(limit.get("latencies") or [], LIMIT_COLOR))
    body.append(curve(openn.get("latencies") or [], OPEN_COLOR))

    body.append(legend(x0, height - 24, [("500m limit", LIMIT_COLOR), ("no limit", OPEN_COLOR)]))

    return svg_wrap(width, height, "\n  ".join(body))


def plot_burst_bars(limit, openn):
    width, height = 720, 300
    x0, y0, x1, y1 = 80, 50, 680, 230
    metrics = [("p50", limit.get("p50", 0), openn.get("p50", 0)),
               ("p95", limit.get("p95", 0), openn.get("p95", 0)),
               ("p99", limit.get("p99", 0), openn.get("p99", 0))]
    y_max = max(v for _, l, o in metrics for v in (l, o)) or 10.0
    y_max = math.ceil(y_max / 20.0) * 20.0 or 20.0

    body = [text(24, 28, "burst latency  ·  ~400m offered, 500m cap", size=13)]
    body.append(y_axis(x0, y0, y1, x1, y_max, y_max / 3.0, "ms"))

    group_w = (x1 - x0) / len(metrics)
    bar_w = 48
    for i, (label, lval, oval) in enumerate(metrics):
        gx = x0 + i * group_w + group_w / 2 - bar_w
        lh = (lval / y_max) * (y1 - y0)
        oh = (oval / y_max) * (y1 - y0)
        body.append(rect(gx, y1 - lh, bar_w, lh, LIMIT_COLOR))
        body.append(rect(gx + bar_w + 8, y1 - oh, bar_w, oh, OPEN_COLOR))
        body.append(text(gx + 4, y1 - lh - 6, f"{lval:g}", size=10, fill=LIMIT_COLOR))
        body.append(text(gx + bar_w + 12, y1 - oh - 6, f"{oval:g}", size=10, fill=OPEN_COLOR))
        body.append(text(gx + 14, y1 + 20, label, size=12))
    body.append(text(x0, y1 + 40, "x-axis: latency percentile  ·  y-axis: latency (ms)", size=10, fill=MUTED))
    body.append(legend(x0, height - 28, [("500m limit", LIMIT_COLOR), ("no limit", OPEN_COLOR)]))
    return svg_wrap(width, height, "\n  ".join(body))


# ---------------------------------------------------------------------------
# results-spike.svg
# ---------------------------------------------------------------------------

def plot_spike(legs):
    sbl = legs.get("spike-base-limit")
    sl = legs.get("spike-limit")
    sbo = legs.get("spike-base-open")
    so = legs.get("spike-open")
    if not all([sbl, sl, sbo, so]):
        return None

    width, height = 720, 300
    x0, y0, x1, y1 = 80, 50, 680, 230
    metrics = [
        ("quiet p99", sbl.get("p99", 0), sbo.get("p99", 0)),
        ("spike p50", sl.get("p50", 0), so.get("p50", 0)),
        ("spike p99", sl.get("p99", 0), so.get("p99", 0)),
    ]
    y_max = max(v for _, l, o in metrics for v in (l, o)) or 10.0
    y_max = math.ceil(y_max / 20.0) * 20.0 or 20.0

    body = [text(24, 28, "spike  ·  quiet then load spike on /mixed", size=13)]
    body.append(y_axis(x0, y0, y1, x1, y_max, y_max / 4.0, "ms"))

    group_w = (x1 - x0) / len(metrics)
    bar_w = 48
    for i, (label, lval, oval) in enumerate(metrics):
        gx = x0 + i * group_w + group_w / 2 - bar_w
        lh = (lval / y_max) * (y1 - y0)
        oh = (oval / y_max) * (y1 - y0)
        body.append(rect(gx, y1 - lh, bar_w, lh, LIMIT_COLOR))
        body.append(rect(gx + bar_w + 8, y1 - oh, bar_w, oh, OPEN_COLOR))
        body.append(text(gx + 4, y1 - lh - 6, f"{lval:g}", size=10, fill=LIMIT_COLOR))
        body.append(text(gx + bar_w + 12, y1 - oh - 6, f"{oval:g}", size=10, fill=OPEN_COLOR))
        body.append(text(gx, y1 + 20, label, size=12))
    body.append(text(x0, y1 + 40, "x-axis: phase / percentile  ·  y-axis: latency (ms)", size=10, fill=MUTED))
    body.append(legend(x0, height - 28, [("500m limit", LIMIT_COLOR), ("no limit", OPEN_COLOR)]))
    return svg_wrap(width, height, "\n  ".join(body))


# ---------------------------------------------------------------------------
# results-throttle.svg: fraction bars annotated with counts.
# ---------------------------------------------------------------------------

def throttle_row(y, label, leg, color):
    parts = [text(24, y, label, size=12)]
    bar_y = y + 10
    parts.append(rect(24, bar_y, 670, 22, TRACK))
    if leg is not None:
        d_p = leg.get("cgPeriods", 0)
        d_t = leg.get("cgThrottled", 0)
        pct = leg.get("throttlePct", 0.0)
        frac_w = 670 * (pct / 100.0)
        frac_w = max(0.0, min(670.0, frac_w))
        if frac_w > 0:
            parts.append(rect(24, bar_y, frac_w, 22, color))
        parts.append(text(36, bar_y + 15, f"{d_t}/{d_p}  {pct:g}%", size=11, fill=INK))
    else:
        parts.append(text(36, bar_y + 15, "no data", size=11, fill=MUTED))
    return "\n  ".join(parts), bar_y + 22


def plot_throttle(legs):
    rows = [
        ("burst  (limit pod, under the cap)", "burst-limit"),
        ("burst  (open pod, no cap)", "burst-open"),
        ("spike  (limit pod, over the cap)", "spike-limit"),
        ("spike  (open pod, no cap)", "spike-open"),
    ]
    present = [(label, job) for label, job in rows if job in legs]
    if not present:
        return None

    width = 720
    row_h = 56
    height = 50 + len(present) * row_h + 20

    body = [text(24, 28, "how often: CPU throttling  ·  cgroup nr_throttled / nr_periods", size=13)]
    y = 50
    for label, job in present:
        leg = legs.get(job)
        color = LIMIT_COLOR if "limit" in job else OPEN_COLOR
        chunk, y_after = throttle_row(y, label, leg, color)
        body.append(chunk)
        y = y_after + row_h - 32
    return svg_wrap(width, height, "\n  ".join(body))


# ---------------------------------------------------------------------------
# results-hog.svg: grouped bars, no hog / gentle hog / saturated node.
# ---------------------------------------------------------------------------

def plot_hog(legs):
    off = legs.get("hog-off")
    on = legs.get("hog-on")
    sat = legs.get("saturate")
    if off is None or on is None:
        return None

    groups = [("no hog", off, OPEN_COLOR)]
    groups.append(("gentle hog", on, "#c98a3f"))
    if sat is not None:
        groups.append(("saturated node", sat, "#a8462e"))

    width = 720
    height = 260
    x0, y0, x1, y1 = 80, 50, 680, 200

    vals = [g[1].get("p99", 0) for g in groups]
    y_max = max(vals) if vals else 10.0
    y_max = math.ceil(y_max / 20.0) * 20.0 or 20.0

    body = [text(24, 28, "a pod burning CPU next door  ·  app has no CPU limit", size=13)]
    body.append(y_axis(x0, y0, y1, x1, y_max, y_max / 4.0, "ms"))

    n = len(groups)
    group_w = (x1 - x0) / n
    bar_w = min(80, group_w - 40)
    for i, (label, leg, color) in enumerate(groups):
        p99 = leg.get("p99", 0)
        gx = x0 + i * group_w + (group_w - bar_w) / 2
        h = (p99 / y_max) * (y1 - y0)
        body.append(rect(gx, y1 - h, bar_w, h, color))
        body.append(text(gx, y1 - h - 8, f"{p99:g} ms", size=12, fill=color))
        body.append(text(x0 + i * group_w + group_w / 2 - len(label) * 3.2, y1 + 24, label, size=12))
    body.append(text(x0, height - 8, "x-axis: scenario  ·  y-axis: p99 latency (ms)", size=10, fill=MUTED))
    if sat is None:
        body.append(
            text(
                x0,
                44,
                "(saturate leg not present in run.jsonl yet — needs a cluster run)",
                size=10,
                fill=MUTED,
            )
        )
    return svg_wrap(width, height, "\n  ".join(body))


def main():
    rows = load_rows()
    legs = legs_by_job(rows)

    outputs = {
        "results-burst.svg": plot_burst(legs),
        "results-spike.svg": plot_spike(legs),
        "results-throttle.svg": plot_throttle(legs),
        "results-hog.svg": plot_hog(legs),
    }

    for name, svg in outputs.items():
        if svg is None:
            print(f"skip {name}: missing data in run.jsonl")
            continue
        path = os.path.join(ASSETS, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write(svg)
        print(f"wrote {path}")


if __name__ == "__main__":
    main()
