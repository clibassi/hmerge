*! file: acs_hmerge_walkthrough.do
*! purpose: Compare merge and hmerge on the real ACS vintage reconciliation.
*! author: CJ Libassi, with Codex assistance
*! created: 2026-09-25
version 17.0
set more off
set varabbrev off
set rmsg on

*******************************************************************************
* SECTION 1: Set paths once for this Stata session
*******************************************************************************
* These globals survive separate Do-file Editor selections.
* All inputs and outputs are local to hmerge, outside Dropbox.
global hm_project "/Users/clibassi/code/hmerge"
global hm_example "${hm_project}/examples/acs_vintage"
global hm_raw "${hm_example}/data/raw"
global hm_prepared "${hm_example}/data/prepared"
global hm_output "${hm_example}/output"

adopath ++ "${hm_project}"
which hmerge
confirm file "${hm_raw}/january_utility.dta"
confirm file "${hm_raw}/march_extract.dat"

capture log close acs_benchmark
log using "${hm_output}/walkthrough.log", text replace name(acs_benchmark)

*******************************************************************************
* SECTION 2: Prepare the two inputs (run this section as one selection)
*******************************************************************************
* Skip the expensive import on subsequent runs. To rebuild, remove the two
* prepared .dta files, then rerun this section. Never change the raw copies.
* Keep the original storage types and row order: no compress or added sort.
* That preserves the workload from 08_factor_table.do at its merge step.

capture confirm file "${hm_prepared}/january.dta"
if _rc {
    use sample serial pernum year multyear statefip incwage ///
        using "${hm_raw}/january_utility.dta", clear
    drop if year == 2024
    drop year

    rename incwage jan_incwage
    rename statefip jan_statefip
    label variable jan_incwage "Wage income as the January 5, 2026 file ships it"

    isid sample serial pernum
    assert _N == 16044345
    save "${hm_prepared}/january.dta", replace
}

capture confirm file "${hm_prepared}/march_master.dta"
if _rc {
    * Fixed-width positions come from the original ACS reconciliation script.
    infix                      ///
        int    multyear   5-8  ///
        long   sample     9-14 ///
        double serial    15-22 ///
        byte   statefip  59-60 ///
        int    pernum    74-77 ///
        long   incwage 142-147 ///
        using "${hm_raw}/march_extract.dat", clear

    rename multyear survey_year
    rename statefip mar_statefip
    rename incwage mar_incwage
    label variable mar_incwage "Wage income after the March 18, 2026 correction"
    order survey_year sample serial pernum mar_statefip mar_incwage

    isid sample serial pernum
    assert _N == 16044345
    save "${hm_prepared}/march_master.dta", replace
}

use "${hm_prepared}/march_master.dta", clear
describe, short
* A blank Sorted by line means no stored sort flag; the rows may still happen
* to be in key order. We do not shuffle them to manufacture a larger gain.

*******************************************************************************
* SECTION 3: Time native merge (run this whole section)
*******************************************************************************
* Loading the master is outside the timer. Reading the using file, checking
* uniqueness, and doing the join are inside it, for BOTH commands.
use "${hm_prepared}/march_master.dta", clear

timer clear 71
timer on 71
merge 1:1 sample serial pernum using "${hm_prepared}/january.dta", ///
    assert(match) nogenerate
timer off 71

timer list 71
scalar hm_native_seconds = r(t71)

* These correctness checks and the reference save are outside the timer.
assert _N == 16044345
assert jan_statefip == mar_statefip
sort sample serial pernum
save "${hm_output}/native_result.dta", replace

*******************************************************************************
* SECTION 4: Time hmerge from exactly the same master (run this whole section)
*******************************************************************************
use "${hm_prepared}/march_master.dta", clear

timer clear 72
timer on 72
hmerge 1:1 sample serial pernum using "${hm_prepared}/january.dta", ///
    assert(match) nogenerate
timer off 72

* A successful native fallback is not an hmerge performance test.
* Capture r(path) before timer list replaces the returned results.
local join_path "`r(path)'"
display as text "hmerge execution path: `join_path'"
assert inlist("`join_path'", "hash", "direct", "ordered")

timer list 72
scalar hm_hash_seconds = r(t72)

assert _N == 16044345
assert jan_statefip == mar_statefip
sort sample serial pernum
save "${hm_output}/hmerge_result.dta", replace

*******************************************************************************
* SECTION 5: Compare every variable value, then report this pair of timings
*******************************************************************************
* hmerge preserves master order, so align by the unique key before comparing.
* This sort is ONLY for validation and is outside the merge timer.
* cf checks values; it does not certify labels, formats, or other metadata.
use "${hm_output}/hmerge_result.dta", clear
cf _all using "${hm_output}/native_result.dta", all

scalar hm_speed_ratio = hm_native_seconds / hm_hash_seconds
scalar hm_seconds_saved = hm_native_seconds - hm_hash_seconds

display as text "Native merge seconds: " as result %9.3f hm_native_seconds
display as text "hmerge seconds:       " as result %9.3f hm_hash_seconds
display as text "Native / hmerge:      " as result %9.3f hm_speed_ratio
display as text "Seconds saved:        " as result %9.3f hm_seconds_saved

* Ratio > 1 means hmerge was faster; ratio < 1 means native merge was faster.
* This is ONE exploratory pair, not a stable speed estimate. Repeat sections
* 3-5, and also try section 4 before 3 (then 5), to check order/cache effects.
* Do not include source copying, text import, validation, or saves in timing.
* Both sides have 16 million rows: this is not the small-lookup 8x example.
capture log close acs_benchmark
