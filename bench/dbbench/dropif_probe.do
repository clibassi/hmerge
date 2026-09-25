* dropif_probe.do -- how much of hmerge's inner-join time is Stata dropping
* the unmatched observations? db-benchmark q2 (x: 10M rows, medium: 10,000 rows).
*   join_keepall   hmerge m:1 id2, no keep() (all master rows stay)
*   drop_only      drop if _merge == 1 on that result (about 10% of rows)
*   join_inner     hmerge m:1 id2, keep(match) (what q2 times)
* Usage (repo root): stata-mp -b do bench/dbbench/dropif_probe.do [reps]

args reps
if ( "`reps'" == "" ) local reps 3
do bench/bench_lib.do
adopath ++ "`c(pwd)'"
bl_init, out(bench/raw/dbbench_dropif.csv) bench(dbbench_dropif)
local x      bench/data/dbbench/J1_1e7_NA_0_0.dta
local medium bench/data/dbbench/J1_1e7_1e4_0_0.dta
local tags n(10000000) j(10000) keytype(int) order(random)

forvalues r = 1 / `reps' {
    use "`x'", clear
    bl_tic
    hmerge m:1 id2 using "`medium'", keepusing(v2) noreport
    bl_toc, case(q2_parts) impl(join_keepall) `tags' rep(`r')
    bl_tic
    drop if _merge == 1
    bl_toc, case(q2_parts) impl(drop_only) `tags' rep(`r')

    use "`x'", clear
    bl_tic
    hmerge m:1 id2 using "`medium'", keep(match) keepusing(v2) nogenerate noreport
    bl_toc, case(q2_parts) impl(join_inner) `tags' rep(`r')
}
