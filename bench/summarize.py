#!/usr/bin/env python3
"""Summarize benchmark CSVs: median seconds per (case, J, keytype, order, impl),
plus the ratio of each implementation to the native baseline.

Usage: python3 bench/summarize.py bench/raw/prelim_survey.csv [--base native] [--md]
"""
import csv
import statistics
import sys
from collections import defaultdict


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    base = "native"
    if "--base" in sys.argv:
        base = sys.argv[sys.argv.index("--base") + 1]
        args = [a for a in args if a != base]
    as_md = "--md" in sys.argv

    times = defaultdict(list)
    for path in args:
        with open(path) as fh:
            for row in csv.DictReader(fh):
                key = (row["bench"], row["case"], int(float(row["N"])), int(float(row["J"])),
                       row["keytype"], row["order"])
                if row["seconds"] in (".", "") or row.get("ok", "1") == "0":
                    continue  # timer clobbered (e.g. gcontract uses timer 97)
                times[key, row["impl"]].append(float(row["seconds"]))

    cells = defaultdict(dict)
    for (key, impl), secs in times.items():
        cells[key][impl] = (statistics.median(secs), len(secs), min(secs), max(secs))

    rows = []
    for key in sorted(cells):
        impls = cells[key]
        b = impls.get(base, (None,))[0]
        for impl, (med, n, lo, hi) in sorted(impls.items(), key=lambda kv: kv[1][0]):
            ratio = (b / med) if (b and med > 0) else float("nan")
            rows.append((*key, impl, med, lo, hi, n, ratio))

    hdr = ["bench", "case", "N", "J", "keytype", "order", "impl", "median_s", "min_s", "max_s",
           "reps", f"speedup_vs_{base}"]
    if as_md:
        print("| " + " | ".join(hdr[1:]) + " |")
        print("|" + "---|" * (len(hdr) - 1))
        for r in rows:
            print("| " + " | ".join(
                f"{v:,.3f}" if isinstance(v, float) else (f"{v:,}" if isinstance(v, int) else str(v))
                for v in r[1:]) + " |")
    else:
        w = csv.writer(sys.stdout)
        w.writerow(hdr)
        for r in rows:
            w.writerow([f"{v:.4f}" if isinstance(v, float) else v for v in r])


if __name__ == "__main__":
    main()
