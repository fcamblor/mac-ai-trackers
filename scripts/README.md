# scripts/

Utility scripts for the `mac-ai-trackers` project.

## 5h <-> 7d ratio analysis pipeline

These three scripts analyze the JSONL files produced by `ai-usages-tracker`
to estimate, per account, **how many times the 5h window must be saturated
to saturate the 7d window** (= macro ratio). They produce CSV and PNG outputs.

### Overview

```
~/.cache/ai-usages-tracker/usage-history/<year>/<month>/*.jsonl
    |
    |  analyze-token-ratios.py   (step 1)
    v
ratios.jsonl   (1 line = 1 strictly monotonic range, with macro ratio + steps)
    |
    |  ratios-to-csv.py          (step 2)
    v
ratios-macro.csv     ratios-scatter.csv
    |                        |
    |     ratios-to-png.py   |   (step 3, optional)
    v                        v
ratios-macro.png        ratios-scatter.png
```

### Step 1 — Extract monotonic ranges

```bash
./scripts/analyze-token-ratios.py ~/.cache/ai-usages-tracker/usage-history/2026/ \
    --min-delta-5h 5 \
    --out ratios.jsonl
```

For each `(vendor, account)` pair:

1. Pair the 5h and 7d samples on matching timestamps.
2. Split the timeline whenever a **decrease** is observed on either window
   (= window reset detected).
3. For each strictly monotonic range, compute:
   - `macro_ratio = total_delta_5h / total_delta_7d`
   - a list of micro `steps` (one per consecutive sample pair).

Available filters:

- `--min-delta-5h N` : drop ranges where the 5h window did not progress by at
  least N points. Recommended: 5.
- `--min-duration N` : drop ranges shorter than N seconds.
- Ranges with `delta_7d == 0` are **always filtered out** (ratio undefined
  due to integer rounding of the weekly percentage).

Output: JSONL on stdout (or `--out <file>`).

Entry format:

```json
{
  "vendor": "claude",
  "account": "...",
  "metric_5h": { "name": "...", "values": [start, end], "delta": 36.0 },
  "metric_7d": { "name": "...", "values": [start, end], "delta": 3.0 },
  "time_range": { "values": ["...Z", "...Z"], "delta_seconds": 17419.0 },
  "samples": 24,
  "macro_ratio": 12.0,
  "steps": [
    { "time_range": {...}, "metric_5h": {...}, "metric_7d": {...}, "ratio": 6.33 },
    ...
  ]
}
```

### Step 2 — CSV for Google Sheets

```bash
./scripts/ratios-to-csv.py ratios.jsonl --prefix /tmp/ratios
# -> /tmp/ratios-macro.csv and /tmp/ratios-scatter.csv
```

Produces two **wide-format** CSVs (one column per series):

- **`ratios-macro.csv`** : X = range midpoint timestamp (UTC, ISO 8601),
  one `(ratio, delta_5h)` column pair per account.
  Suited for **temporal line/scatter charts**.

- **`ratios-scatter.csv`** : X = decimal hour of day (local, controlled by
  `--tz-offset`), same structure. Suited for **"ratio vs hour" scatter charts**.

`delta_5h` is exposed as a parallel column so that each point's reliability
can be visually weighted in Google Sheets (e.g. via conditional formatting
or a bubble chart).

Options:

- `--tz-offset H` : timezone offset (in hours) for the `hour_of_day` column
  (default +2 = CEST).
- `--prefix PATH` : output file prefix (default: `ratios`).

### Step 3 — PNG (optional)

Requires `matplotlib`. Recommended setup with a throwaway venv via `uv`:

```bash
uv venv /tmp/venv-plot
uv pip install --python /tmp/venv-plot/bin/python matplotlib
```

Then:

```bash
/tmp/venv-plot/bin/python ./scripts/ratios-to-png.py /tmp/ratios
# -> /tmp/ratios-macro.png and /tmp/ratios-scatter.png
```

Chart features:

- One color per account.
- Marker size proportional to `delta_5h` (proxy for **ratio reliability**:
  big point = the 5h window progressed a lot on the range, ratio is reliable;
  small point = little progression, ratio is heavily biased by integer rounding).
- "US peak hours" shaded bands on the hour-of-day scatter (15:00-01:00 Paris CEST).
- Legends placed outside the plot area to avoid hiding data points.

To adapt colors/labels to your own accounts, edit the `SERIES` dict at the
top of `ratios-to-png.py`:

```python
SERIES = {
    "claude:personal@example.com":  ("Claude Pro",            "#3b82f6"),
    "claude:work@example.com":      ("Claude Teams Premium",  "#ec4899"),
    "codex:personal@example.com":   ("Codex Plus",            "#10b981"),
}
```

## Reading the results

- The **macro ratio** measures how many times the 5h window must be saturated
  to fill the 7d quota. The higher it is, the more generous the weekly quota
  is relative to the 5h window.
- Ratios derived from **ranges with a low delta_5h** (small markers) are
  unreliable: a 1% rounding error on the 7d percentage can swing the measured
  ratio by a factor of 2.
- The **US peak hours** effect shows up clearly when Claude markers (large
  points) cluster high inside the shaded bands on the hour-of-day scatter.

## Other scripts

- `build-app-bundle.sh` — build the .app bundle (see `docs/DEVELOPMENT.md`).
