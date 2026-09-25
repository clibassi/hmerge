# ACS vintage reconciliation: interactive hmerge benchmark

Open `acs_hmerge_walkthrough.do`. The script runs start to finish, or by numbered
section in Stata's Do-file Editor. Run Section 1 first in each Stata session.
Run sections containing braces or locals as complete selections.

## Local files

Everything is under `/Users/clibassi/code/hmerge/examples/acs_vintage`, outside
Dropbox. `data/` and `output/` are ignored by Git. Source files are copied, never
moved or modified; the Stata script never reads from the team folder.

- `data/raw/january_utility.dta`: January 5, 2026 utility vintage.
- `data/raw/march_extract.dat`: corrected IPUMS extract `usa_00036.dat`.
- `data/prepared/`: narrow, reusable merge inputs, created by Section 2.
- `output/`: log and both merge results for comparison.

Expected January SHA-256 (verified by CJ on the team source):
`a1f99d62de0a53eb80f4796e73ed0bff89301a302e8415ea05864e610408129c`.

The March source is `/Users/clibassi/code/ge-data-qc/ipums_data/usa_00036.dat`.
The original workflow is `ge-data-qc/stata/08_factor_table.do`, line 120.
Both merge inputs should have 16,044,345 observations.

## Walkthrough

1. Set the globals and check inputs (Section 1).
2. Prepare inputs (Section 2); later runs reuse the saved inputs. This skips
   state-median calculations that do not affect the merge inputs. Original
   storage types and row order are preserved; no compression or shuffling.
3. Run and time native merge (Section 3).
4. Reload the identical master and time hmerge (Section 4). Require its
   `r(path)` to be `hash`, `direct`, or `ordered`; fallback is not a successful benchmark.
5. Compare every variable value after aligning records by key (Section 5).
   The comparison does not test labels, formats, notes, or other metadata.

A full script run produces one exploratory pair. For repeated runs, use sections
3,4,5, then 4,3,5, alternating. Each command reloads the same master. Both results
are saved separately, so the equality check works in either execution order.
Keep each timer result; use medians over several runs before claiming a speedup.
Reopen the named log with Section 1 when starting another logged pair.

Only the merge command is timed, including using-file read and join validation.
Master loading, file copying, text import, result saves and comparison sorting
are outside the timers. Both commands use the original assert(match) nogenerate
options. No re-sort is needed for the subsequent original per-record calculations.
The equal-size 1:1 workload may show modest gains or none, especially if the
original row order already favors native merge. Do not shuffle for the headline.

To rebuild inputs, delete only the two prepared files and rerun Section 2.
The raw files occupy about 7 GB; prepared inputs and results take additional space.

## After updating the plugin

Save your work and restart Stata before benchmarking version 0.3.0: an open session
may retain the old compiled plugin. Run Section 1, then Sections 3–5 in the walkthrough.
`which hmerge` should report version 0.3.0, and the original ordered ACS join should
report `r(path)` as `ordered`. The shuffled master should report `hash`.
See [the measured comparison](../../bench/results/adaptive.md) for the release benchmark.
