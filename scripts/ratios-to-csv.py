#!/usr/bin/env python3
"""
Convert the JSONL produced by analyze-token-ratios.py into two CSV files
ready for Google Sheets:

  - <prefix>-macro.csv    : 1 row per range, X = midpoint timestamp (ISO),
                            one (ratio, delta_5h) column pair per account.
                            -> use for line / temporal scatter charts.

  - <prefix>-scatter.csv  : 1 row per range, X = hour of day
                            (decimal, in the timezone given by --tz-offset),
                            same column structure.
                            -> use for "ratio vs hour" scatter charts.

Usage:
    ./ratios-to-csv.py <ratios.jsonl> [--prefix out] [--tz-offset 2]
"""

import argparse
import csv
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def parse_ts(ts: str) -> datetime:
    return datetime.fromisoformat(ts.replace("Z", "+00:00"))


def midpoint(start_ts: str, end_ts: str) -> datetime:
    a = parse_ts(start_ts)
    b = parse_ts(end_ts)
    return a + (b - a) / 2


def hour_of_day(dt: datetime, tz_offset_hours: float) -> float:
    local = dt.astimezone(timezone(timedelta(hours=tz_offset_hours)))
    return round(local.hour + local.minute / 60 + local.second / 3600, 4)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("jsonl", type=Path, help="JSONL produced by analyze-token-ratios.py")
    ap.add_argument("--prefix", type=Path, default=Path("ratios"),
                    help="Output file prefix (default: ratios)")
    ap.add_argument("--tz-offset", type=float, default=2.0,
                    help="Timezone offset in hours for the 'hour of day' column (default: +2 = CEST/Paris summer time)")
    args = ap.parse_args()

    if not args.jsonl.exists():
        sys.exit(f"File not found: {args.jsonl}")

    rows = []
    series_set = set()
    for line in args.jsonl.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("macro_ratio") is None:
            continue
        series = f"{e['vendor']}:{e['account']}"
        series_set.add(series)
        mid = midpoint(*e["time_range"]["values"])
        rows.append({
            "series": series,
            "midpoint_utc": mid,
            "hour": hour_of_day(mid, args.tz_offset),
            "ratio": e["macro_ratio"],
            "delta_5h": e["metric_5h"]["delta"],
        })

    series_cols = sorted(series_set)

    def expanded_header(x_col):
        cols = [x_col]
        for s in series_cols:
            cols.append(s)
            cols.append(f"{s}:delta_5h")
        return cols

    def expanded_row(x_val, r):
        row = [x_val]
        for s in series_cols:
            if r["series"] == s:
                row.append(r["ratio"])
                row.append(r["delta_5h"])
            else:
                row.extend(["", ""])
        return row

    # Macro CSV: X = midpoint ISO (UTC), one (ratio, delta_5h) pair per series
    macro_path = args.prefix.with_name(args.prefix.name + "-macro.csv")
    with macro_path.open("w", newline="") as fp:
        w = csv.writer(fp)
        w.writerow(expanded_header("midpoint_utc"))
        for r in sorted(rows, key=lambda r: r["midpoint_utc"]):
            x = r["midpoint_utc"].strftime("%Y-%m-%dT%H:%M:%SZ")
            w.writerow(expanded_row(x, r))

    # Scatter CSV: X = decimal hour (local), one (ratio, delta_5h) pair per series
    scatter_path = args.prefix.with_name(args.prefix.name + "-scatter.csv")
    with scatter_path.open("w", newline="") as fp:
        w = csv.writer(fp)
        w.writerow(expanded_header("hour_of_day"))
        for r in sorted(rows, key=lambda r: r["hour"]):
            w.writerow(expanded_row(r["hour"], r))

    print(f"{len(rows)} ranges -> {macro_path}, {scatter_path}", file=sys.stderr)


if __name__ == "__main__":
    main()
