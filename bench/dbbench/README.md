# db-benchmark join task in Stata

A public, regenerable join benchmark with published results for other tools, so our
merge timings are not on our own synthetic data alone.

**Source:** DuckDB Labs' maintained fork of the H2O.ai "database-like ops" benchmark,
<https://github.com/duckdblabs/db-benchmark> (MPL-2.0), pinned at commit
`3b074bc3190468803b3a890301f87ce455114d20` (23 Sep 2026). Published results:
<https://duckdblabs.github.io/db-benchmark/>.

## Regenerate the data (not committed: ~0.9 GB of CSV)
```sh
git clone https://github.com/duckdblabs/db-benchmark.git upstream/db-benchmark
git -C upstream/db-benchmark checkout 3b074bc3190468803b3a890301f87ce455114d20
mkdir -p bench/data/dbbench && cd bench/data/dbbench
Rscript ../../../upstream/db-benchmark/_data/join-datagen.R 1e7 NA 0 0   # needs R + data.table; ~20 s
```
This writes `J1_1e7_NA_0_0.csv` (x: 10M rows; id1–id3 integer, id4–id6 their string
versions, v1) and the right tables `J1_1e7_1e1_0_0.csv` (small, 10 rows),
`J1_1e7_1e4_0_0.csv` (medium, 10,000) and `J1_1e7_1e7_0_0.csv` (big, 10M). Right-table
keys are unique; about 90% of keys overlap. In x, `id3` is unique, so q5 is a 1:1 merge.

## Run
```sh
stata-mp -b do bench/dbbench/dbbench_join.do 3        # merge, hmerge, hmerge+sort, fmerge
Rscript bench/dbbench/dbbench_join_datatable.R 3       # data.table at 2 threads and all threads
```
Outputs: `bench/raw/dbbench_join_stata.csv`, `bench/raw/dbbench_join_datatable.csv`,
`bench/raw/dbbench_join_rows.csv` (row counts per implementation, to compare with data.table),
`logs/dbbench_join.log` (lines `EQUALITY …` confirm hmerge == native per question).

## Question mapping
| upstream question | Stata |
|---|---|
| q1 small inner on int | `merge m:1 id1 using small, keep(match) keepusing(v2)` |
| q2 medium inner on int | `merge m:1 id2 using medium, keep(match) keepusing(v2)` |
| q3 medium outer on int | `merge m:1 id2 using medium, keep(master match) keepusing(v2)` |
| q4 medium inner on factor | `merge m:1 id5 using medium, keep(match) keepusing(v2)` (string key) |
| q5 big inner on int | `merge 1:1 id3 using big, keep(match) keepusing(v2)` |

`keepusing(v2)`: the right tables repeat x's id columns; in Stata those would be dropped
anyway, since master values win for overlapping variables. data.table returns them as `i.` columns,
a small amount of extra work it does that the Stata runs don't. Neither side times reading the CSV files.
The other difference runs against Stata: the Stata timing *includes* reading the using `.dta`
(that is how `merge` works: the using data always come from disk), while data.table has all
four tables in memory before timing starts. This matters most for q5, whose using table has 10M rows.
