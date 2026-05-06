#!/usr/bin/env python3
"""
Generate two PNGs from the CSVs produced by ratios-to-csv.py:

  - <prefix>-macro.png   : temporal scatter (X = midpoint timestamp).
  - <prefix>-scatter.png : hour-of-day scatter (X = local hour) with
                           shaded US peak-hour bands.

One color per account (vendor:account), marker size proportional to delta_5h
on the range (proxy for ratio reliability).

Dependency: matplotlib. See scripts/README.md for the venv setup.

Usage:
    ./ratios-to-png.py <prefix> [--out-prefix <out>]

    <prefix>      : prefix used by ratios-to-csv.py
                    (reads <prefix>-macro.csv and <prefix>-scatter.csv)
    --out-prefix  : output PNG prefix (default: same as <prefix>)
"""

import argparse
import csv
from datetime import datetime
from pathlib import Path

import matplotlib.dates as mdates
import matplotlib.pyplot as plt
from matplotlib.lines import Line2D
from matplotlib.patches import Patch

# (vendor:account) -> (display label, color). Adjust for your accounts.
SERIES = {
    "claude:personal@example.com": ("Claude Pro", "#3b82f6"),
    "claude:work@example.com": ("Claude Teams Premium", "#ec4899"),
    "codex:personal@example.com": ("Codex Plus", "#10b981"),
}

PEAK_COLOR = "#fbbf24"
PEAK_LABEL = "US peak hours (15-01 Paris)"
SIZE_REFS = (10, 50, 100)


def load_csv(path: Path, x_parser):
    with path.open() as f:
        rows = list(csv.DictReader(f))
    data = {s: {"x": [], "ratio": [], "delta": []} for s in SERIES}
    for r in rows:
        x_col = next(iter(r))
        x = x_parser(r[x_col])
        for s in SERIES:
            ratio = r.get(s)
            d5 = r.get(f"{s}:delta_5h")
            if ratio:
                data[s]["x"].append(x)
                data[s]["ratio"].append(float(ratio))
                data[s]["delta"].append(float(d5))
    return data


def marker_sizes(deltas):
    # Area (points^2) proportional to delta_5h (%), with a small floor for visibility.
    return [max(5, d * 5) for d in deltas]


def color_handles():
    return [
        Line2D([0], [0], marker="o", color="w", markerfacecolor=color,
               markersize=10, label=label)
        for _, (label, color) in SERIES.items()
    ]


def size_handles():
    return [
        Line2D([0], [0], marker="o", color="w", markerfacecolor="gray",
               alpha=0.55, markersize=(d * 5) ** 0.5, label=f"delta_5h = {d}%")
        for d in SIZE_REFS
    ]


def plot_macro(csv_path: Path, png_path: Path):
    data = load_csv(csv_path, lambda v: datetime.fromisoformat(v.replace("Z", "+00:00")))
    fig, ax = plt.subplots(figsize=(14, 6))
    for s, (_, color) in SERIES.items():
        d = data[s]
        if not d["x"]:
            continue
        ax.scatter(d["x"], d["ratio"], s=marker_sizes(d["delta"]), color=color,
                   alpha=0.7, edgecolors="white", linewidth=0.6)

    ax.set_xlabel("Time (UTC, range midpoint)")
    ax.set_ylabel("Macro ratio (x 5h windows to fill the 7d window)")
    ax.set_title("Macro 5h <-> 7d ratios — marker size = delta_5h on the range")
    ax.grid(True, alpha=0.3)
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%d %b"))
    ax.xaxis.set_major_locator(mdates.DayLocator(interval=2))
    ax.legend(handles=color_handles() + size_handles(),
              loc="center left", bbox_to_anchor=(1.01, 0.5),
              framealpha=0.9, fontsize=9)
    plt.xticks(rotation=30)
    plt.tight_layout()
    plt.savefig(png_path, dpi=130, bbox_inches="tight")
    plt.close()


def plot_scatter(csv_path: Path, png_path: Path):
    data = load_csv(csv_path, float)
    fig, ax = plt.subplots(figsize=(14, 6))
    ax.axvspan(15, 24, color=PEAK_COLOR, alpha=0.18)
    ax.axvspan(0, 1, color=PEAK_COLOR, alpha=0.18)
    for s, (_, color) in SERIES.items():
        d = data[s]
        if not d["x"]:
            continue
        ax.scatter(d["x"], d["ratio"], s=marker_sizes(d["delta"]), color=color,
                   alpha=0.7, edgecolors="white", linewidth=0.6)

    peak_handle = Patch(facecolor=PEAK_COLOR, alpha=0.35, label=PEAK_LABEL)

    ax.set_xlabel("Hour of day (Paris, CEST)")
    ax.set_ylabel("Macro ratio (x 5h windows to fill the 7d window)")
    ax.set_title("5h <-> 7d ratio vs hour of day — marker size = delta_5h on the range")
    ax.set_xticks(range(0, 25, 2))
    ax.set_xlim(-0.5, 24.5)
    ax.grid(True, alpha=0.3)
    ax.legend(handles=color_handles() + [peak_handle] + size_handles(),
              loc="center left", bbox_to_anchor=(1.01, 0.5),
              framealpha=0.9, fontsize=9)
    plt.tight_layout()
    plt.savefig(png_path, dpi=130, bbox_inches="tight")
    plt.close()


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prefix", type=Path,
                    help="Prefix used by ratios-to-csv.py (without -macro.csv/-scatter.csv)")
    ap.add_argument("--out-prefix", type=Path, default=None,
                    help="Output PNG prefix (default: same as prefix)")
    args = ap.parse_args()

    out_prefix = args.out_prefix or args.prefix
    macro_csv = args.prefix.with_name(args.prefix.name + "-macro.csv")
    scatter_csv = args.prefix.with_name(args.prefix.name + "-scatter.csv")
    macro_png = out_prefix.with_name(out_prefix.name + "-macro.png")
    scatter_png = out_prefix.with_name(out_prefix.name + "-scatter.png")

    for p in (macro_csv, scatter_csv):
        if not p.exists():
            raise SystemExit(f"CSV not found: {p}")

    plot_macro(macro_csv, macro_png)
    plot_scatter(scatter_csv, scatter_png)
    print(f"PNGs written: {macro_png}, {scatter_png}")


if __name__ == "__main__":
    main()
