*! file: acs_hmerge_first.do
*! purpose: Repeat the ACS timing comparison with hmerge first, native merge second.
*! author: CJ Libassi, with Codex assistance
*! created: 2026-09-25
version 17.0
set more off
set varabbrev off
set rmsg on

*******************************************************************************
* SECTION 1: Paths and prepared inputs
*******************************************************************************
* Run this entire script after preparing inputs with acs_hmerge_walkthrough.do.
* It reuses the same inputs without importing, sorting, or changing them.
global hm_project "/Users/clibassi/code/hmerge"
global hm_example "${hm_project}/examples/acs_vintage"
global hm_prepared "${hm_example}/data/prepared"
global hm_output "${hm_example}/output"

adopath ++ "${hm_project}"
which hmerge
confirm file "${hm_prepared}/january.dta"
confirm file "${hm_prepared}/march_master.dta"

capture log close acs_reverse
log using "${hm_output}/hmerge_first.log", text replace name(acs_reverse)

* Only the merge is timed, including reading the using file and validation.
* Loading the master, checking results, sorting, and saving are outside timers.

*******************************************************************************
* SECTION 2: Time hmerge FIRST
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
save "${hm_output}/hmerge_first_result.dta", replace

*******************************************************************************
* SECTION 3: Time native merge SECOND
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
save "${hm_output}/native_second_result.dta", replace

*******************************************************************************
* SECTION 4: Check equality and report timings
*******************************************************************************
* hmerge preserves master order, so align by the unique key before comparing.
* This sort is ONLY for validation and is outside the merge timer.
* cf checks values; it does not certify labels, formats, or other metadata.
use "${hm_output}/hmerge_first_result.dta", clear
cf _all using "${hm_output}/native_second_result.dta", all

scalar hm_speed_ratio = hm_native_seconds / hm_hash_seconds
scalar hm_seconds_saved = hm_native_seconds - hm_hash_seconds

display as text "Native merge seconds: " as result %9.3f hm_native_seconds
display as text "hmerge seconds:       " as result %9.3f hm_hash_seconds
display as text "Native / hmerge:      " as result %9.3f hm_speed_ratio
display as text "Seconds saved:        " as result %9.3f hm_seconds_saved

* Ratio > 1 favors hmerge; ratio < 1 favors native merge.
* Compare this pair with walkthrough.log. One pair in each order is preliminary.
capture log close acs_reverse
