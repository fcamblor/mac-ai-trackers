#!/usr/bin/env python3
"""
Analyze token ratios between 5h and 7d windows from JSONL files produced by
ai-usages-tracker.

Usage:
    ./analyze-token-ratios.py <root_dir> [--out <output.jsonl>]

For each (vendor, account, 5h/7d metric pair), this script:
  1. Pairs the 5h and 7d samples by matching timestamps.
  2. Identifies the largest strictly monotonic time ranges
     (no decrease on either 5h or 7d -> no window reset in between).
  3. Emits one JSONL entry per range with:
       - the macro ratio (total_delta_5h / total_delta_7d)
       - the list of inner steps with their delta and micro ratio
"""

import argparse
import json
import os
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

METRIC_PAIRS = {
    "claude": ("5h sessions (all models)", "Weekly (all models)"),
    "codex": ("Session (5h)", "Weekly (7d)"),
}


def parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def load_series(root: Path):
    """Returns {(vendor, account, metric_name): [(ts_str, pct), ...]} sorted by ts."""
    series: dict[tuple[str, str, str], list[tuple[str, float]]] = defaultdict(list)
    for path in sorted(root.rglob("*.jsonl")):
        with path.open() as fp:
            for line in fp:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = entry.get("timestamp")
                if ts is None:
                    continue
                for acc in entry.get("accounts", []):
                    vendor = acc.get("vendor")
                    account = acc.get("account")
                    for m in acc.get("metrics", []):
                        pct = m.get("usagePercent")
                        if pct is None:
                            continue
                        series[(vendor, account, m["name"])].append((ts, float(pct)))
    for key in series:
        series[key].sort(key=lambda p: p[0])
    return series


def pair_series(s5: list[tuple[str, float]], s7: list[tuple[str, float]]):
    """Pairs 5h and 7d samples on matching timestamps. Returns [(ts, p5, p7), ...]."""
    map7 = dict(s7)
    paired = []
    for ts, p5 in s5:
        p7 = map7.get(ts)
        if p7 is not None:
            paired.append((ts, p5, p7))
    return paired


def split_monotonic_ranges(paired):
    """Splits into ranges where neither p5 nor p7 ever decreases.

    A decrease ends the current range; the decreasing sample starts the next.
    """
    ranges = []
    current = []
    for sample in paired:
        if not current:
            current.append(sample)
            continue
        _, prev5, prev7 = current[-1]
        _, p5, p7 = sample
        if p5 < prev5 or p7 < prev7:
            if len(current) >= 2:
                ranges.append(current)
            current = [sample]
        else:
            current.append(sample)
    if len(current) >= 2:
        ranges.append(current)
    return ranges


def safe_ratio(num: float, den: float):
    if den > 0:
        return round(num / den, 4)
    if num > 0:
        return None  # delta_7d is zero -> ratio undefined (typically due to integer rounding)
    return 0.0


def build_range_entry(vendor, account, metric5h, metric7d, samples):
    first_ts, first5, first7 = samples[0]
    last_ts, last5, last7 = samples[-1]
    total5 = round(last5 - first5, 4)
    total7 = round(last7 - first7, 4)
    duration = (parse_ts(last_ts) - parse_ts(first_ts)).total_seconds()

    steps = []
    for i in range(1, len(samples)):
        prev_ts, p5_prev, p7_prev = samples[i - 1]
        ts, p5, p7 = samples[i]
        d5 = round(p5 - p5_prev, 4)
        d7 = round(p7 - p7_prev, 4)
        step_duration = (parse_ts(ts) - parse_ts(prev_ts)).total_seconds()
        steps.append({
            "time_range": {"values": [prev_ts, ts], "delta_seconds": step_duration},
            "metric_5h": {"values": [p5_prev, p5], "delta": d5},
            "metric_7d": {"values": [p7_prev, p7], "delta": d7},
            "ratio": safe_ratio(d5, d7),
        })

    return {
        "vendor": vendor,
        "account": account,
        "metric_5h": {"name": metric5h, "values": [first5, last5], "delta": total5},
        "metric_7d": {"name": metric7d, "values": [first7, last7], "delta": total7},
        "time_range": {"values": [first_ts, last_ts], "delta_seconds": duration},
        "samples": len(samples),
        "macro_ratio": safe_ratio(total5, total7),
        "steps": steps,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("root", type=Path, help="Root directory to scan")
    ap.add_argument("--out", type=Path, default=None, help="Output JSONL file (stdout by default)")
    ap.add_argument("--min-duration", type=float, default=0,
                    help="Filter: keep only ranges lasting at least N seconds")
    ap.add_argument("--min-delta-5h", type=float, default=0,
                    help="Filter: keep only ranges where total delta_5h >= N percent")
    args = ap.parse_args()

    if not args.root.exists():
        sys.exit(f"Root not found: {args.root}")

    series = load_series(args.root)

    # Group by (vendor, account)
    by_account: dict[tuple[str, str], dict[str, list]] = defaultdict(dict)
    for (vendor, account, name), vals in series.items():
        by_account[(vendor, account)][name] = vals

    out_fp = args.out.open("w") if args.out else sys.stdout
    written = 0
    try:
        for (vendor, account), metrics in sorted(by_account.items()):
            pair = METRIC_PAIRS.get(vendor)
            if pair is None:
                continue
            metric5h, metric7d = pair
            if metric5h not in metrics or metric7d not in metrics:
                continue
            paired = pair_series(metrics[metric5h], metrics[metric7d])
            for samples in split_monotonic_ranges(paired):
                entry = build_range_entry(vendor, account, metric5h, metric7d, samples)
                if entry["time_range"]["delta_seconds"] < args.min_duration:
                    continue
                if entry["metric_5h"]["delta"] < args.min_delta_5h:
                    continue
                if entry["metric_7d"]["delta"] <= 0:
                    continue
                out_fp.write(json.dumps(entry, ensure_ascii=False) + "\n")
                written += 1
    finally:
        if args.out:
            out_fp.close()

    print(f"{written} ranges written" + (f" to {args.out}" if args.out else ""), file=sys.stderr)


if __name__ == "__main__":
    main()
