* dbbench_join.do -- the db-benchmark join task (duckdblabs/db-benchmark @ 3b074bc)
* in Stata. Data: `Rscript _data/join-datagen.R 1e7 NA 0 0` (see README.md).
*
* Mapping of the upstream questions (datatable/join-datatable.R) to Stata:
*   q1 small inner on int     merge m:1 id1 using small,  keep(match)
*   q2 medium inner on int    merge m:1 id2 using medium, keep(match)
*   q3 medium outer on int    merge m:1 id2 using medium, keep(master match)
*   q4 medium inner on factor merge m:1 id5 using medium, keep(match)   (string key)
*   q5 big inner on int       merge 1:1 id3 using big,    keep(match)   (id3 unique in x)
* keepusing(v2): the right tables repeat x's id columns; v2 is their payload.
*
* Implementations: native merge, hmerge, hmerge + sort, ftools fmerge.
* Each rep reloads x from .dta outside the timer. Output rows are logged so they can
* be compared with data.table's out_rows; hmerge's result is checked against native
* once per question (identical after sorting on the key and v1).
*
* Usage (repo root): stata-mp -b do bench/dbbench/dbbench_join.do [reps]

args reps
if ( "`reps'" == "" ) local reps 3
do bench/bench_lib.do
adopath ++ "`c(pwd)'"
bl_init, out(bench/raw/dbbench_join_stata.csv) bench(dbbench)
local D bench/data/dbbench

* one-time CSV -> .dta conversion (not timed)
foreach f in NA_0_0 1e1_0_0 1e4_0_0 1e7_0_0 {
    capture confirm file "`D'/J1_1e7_`f'.dta"
    if ( _rc ) {
        import delimited using "`D'/J1_1e7_`f'.csv", clear asdouble
        foreach v in id1 id2 id3 {
            capture confirm numeric variable `v'
            if ( !_rc ) recast long `v'
        }
        compress
        save "`D'/J1_1e7_`f'.dta", replace
    }
}
local x      `D'/J1_1e7_NA_0_0.dta
local small  `D'/J1_1e7_1e1_0_0.dta
local medium `D'/J1_1e7_1e4_0_0.dta
local big    `D'/J1_1e7_1e7_0_0.dta

* question definitions: name | mtype | key | using | keep | J | keytype
local q1 q1_small_inner_int   m:1 id1 small  match          10       int
local q2 q2_medium_inner_int  m:1 id2 medium match          10000    int
local q3 q3_medium_outer_int  m:1 id2 medium "master match" 10000    int
local q4 q4_medium_inner_fact m:1 id5 medium match          10000    str
local q5 q5_big_inner_int     1:1 id3 big    match          10000000 int

* row-count and equality log
tempname fh
file open `fh' using "bench/raw/dbbench_join_rows.csv", write text replace
file write `fh' "case,impl,rep,out_rows" _n

forvalues r = 1 / `reps' {
    forvalues i = 1 / 5 {
        tokenize `"`q`i''"'
        local name `1'
        local mt `2'
        local key `3'
        local uf ``4''
        local kp `5'
        local J `6'
        local kt `7'
        local tags n(10000000) j(`J') keytype(`kt') order(random)
        foreach impl in native hmerge hmerge_sort ftools {
            use "`x'", clear
            bl_tic
            if ( "`impl'" == "native" ) {
                capture noisily merge `mt' `key' using "`uf'", keep(`kp') keepusing(v2) nogenerate noreport
            }
            else if ( "`impl'" == "hmerge" ) {
                capture noisily hmerge `mt' `key' using "`uf'", keep(`kp') keepusing(v2) nogenerate noreport
            }
            else if ( "`impl'" == "hmerge_sort" ) {
                capture noisily hmerge `mt' `key' using "`uf'", keep(`kp') keepusing(v2) nogenerate noreport sort
            }
            else {
                capture noisily fmerge `mt' `key' using "`uf'", keep(`kp') keepusing(v2) nogenerate noreport
            }
            local rc = _rc
            bl_toc, case(`name') impl(`impl') `tags' rep(`r') ok(`=`rc' == 0')
            file write `fh' "`name',`impl',`r',`=cond(`rc', ., _N)'" _n

            * correctness: hmerge vs native, once per question
            if ( `r' == 1 & inlist("`impl'", "native", "hmerge") & `rc' == 0 ) {
                sort `key' v1 v2 id1 id2 id3, stable
                tempfile res_`impl'
                save "`res_`impl''"
                if ( "`impl'" == "hmerge" ) {
                    capture noisily cf _all using "`res_native'", all
                    display as result "EQUALITY `name': " cond(_rc, "DIFFERS", "identical to native merge")
                }
            }
        }
    }
}
file close `fh'
