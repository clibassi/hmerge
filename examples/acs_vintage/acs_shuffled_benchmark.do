*! file: acs_shuffled_benchmark.do
*! purpose: Test ACS merge speed with the same randomly ordered master for both commands.
*! author: CJ Libassi, with Codex assistance
*! created: 2026-09-25
version 17.0
set more off
set varabbrev off

*******************************************************************************
* SECTION 1: Local paths
*******************************************************************************
global hm_project "/Users/clibassi/code/hmerge"
global hm_example "${hm_project}/examples/acs_vintage"
global hm_prepared "${hm_example}/data/prepared"
global hm_output "${hm_example}/output"

adopath ++ "${hm_project}"
which hmerge
confirm file "${hm_prepared}/march_master.dta"
confirm file "${hm_prepared}/january.dta"
capture log close acs_shuffled
log using "${hm_output}/shuffled_benchmark.log", text replace name(acs_shuffled)

*******************************************************************************
* SECTION 2: Shuffle the master ONCE, outside all merge timers
*******************************************************************************
* Start with the original on every script run, so the seed reproduces the same
* permutation. Keep January unchanged: only master order is being varied.
use "${hm_prepared}/march_master.dta", clear
assert _N == 16044345
isid sample serial pernum

set seed 48103
set sortseed 19970
generate double shuffle_order = runiform()
sort shuffle_order, stable
drop shuffle_order

* Keep original types and payload. Compression would change the benchmark.
save "${hm_prepared}/march_master_shuffled.dta", replace
describe, short

*******************************************************************************
* SECTION 3: Warm up, then run four pairs in alternating order
*******************************************************************************
* Run this entire section together: its locals and postfile handle need to
* stay in scope. The loops run over trials and commands, never observations.
* Round 0 warms both implementations and is excluded from the summary.
* Measured rounds: hmerge/merge, merge/hmerge, hmerge/merge, merge/hmerge.
* Each command loads the SAME shuffled master before its timer starts.
* Using-file reads, uniqueness checks and merging are inside the timer.
* Result validation and its sorting are outside the timer.

tempname timing_handle
postfile `timing_handle' byte round byte position str6 command double seconds ///
    using "${hm_output}/shuffled_timings.dta", replace

forvalues round = 0/4 {
    local command_order "merge hmerge"
    if mod(`round', 2) == 1 {
        local command_order "hmerge merge"
    }
    local position = 0

    foreach command of local command_order {
        local position = `position' + 1
        display as text "Round `round', position `position': `command'"
        use "${hm_prepared}/march_master_shuffled.dta", clear

        timer clear 73
        timer on 73
        `command' 1:1 sample serial pernum using "${hm_prepared}/january.dta", ///
            assert(match) nogenerate
        timer off 73

        * Record plugin use before timer list replaces returned results.
        if "`command'" == "hmerge" {
            local join_path "`r(path)'"
            display as text "hmerge execution path: `join_path'"
            assert inlist("`join_path'", "hash", "direct", "ordered")
        }
        timer list 73
        local elapsed = r(t73)

        assert _N == 16044345
        assert jan_statefip == mar_statefip
        sort sample serial pernum

        * First native result becomes the reference for every later result.
        if `round' == 0 & "`command'" == "merge" {
            save "${hm_output}/shuffled_reference.dta", replace
        }
        else {
            cf _all using "${hm_output}/shuffled_reference.dta", all
        }

        * Post only after correctness and plugin checks have passed.
        post `timing_handle' (`round') (`position') ("`command'") (`elapsed')
    }
}
postclose `timing_handle'

*******************************************************************************
* SECTION 4: Show all timings and compare the measured medians
*******************************************************************************
use "${hm_output}/shuffled_timings.dta", clear
label variable round "Trial (0 is warm-up)"
label variable position "Execution order within trial"
label variable seconds "Merge elapsed time, seconds"
format seconds %9.3f
list round position command seconds, noobs sepby(round)
export delimited using "${hm_output}/shuffled_timings.csv", replace

summarize seconds if command == "merge" & round > 0, detail
scalar hm_shuffled_native = r(p50)
summarize seconds if command == "hmerge" & round > 0, detail
scalar hm_shuffled_hash = r(p50)
scalar hm_shuffled_ratio = hm_shuffled_native / hm_shuffled_hash
scalar hm_shuffled_saved = hm_shuffled_native - hm_shuffled_hash

display as text "Native merge median seconds: " as result %9.3f hm_shuffled_native
display as text "hmerge median seconds:       " as result %9.3f hm_shuffled_hash
display as text "Native / hmerge:             " as result %9.3f hm_shuffled_ratio
display as text "Median seconds saved:        " as result %9.3f hm_shuffled_saved

* Ratio > 1 favors hmerge. Ratio < 1 favors native merge.
* All trials passed value comparisons; cf does not compare metadata.
* This tests hypothetical unsorted arrivals, not the original ACS workflow.
* Original prepared inputs and previous ordered-run outputs are unchanged.
capture log close acs_shuffled
