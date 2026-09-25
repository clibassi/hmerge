*! file: hmerge_speedup_demo.do
*! purpose: show hmerge's speedup over native merge on a person-year panel, and that results match
*! author: CJ Libassi (demo written with Claude)
*! created: 2026-09-24
*
* Run from the repository root:
*   /Applications/Stata/StataMP.app/Contents/MacOS/stata-mp -b do demo/hmerge_speedup_demo.do
*
* The story: a person-year panel (10 million rows, sorted by person and year) picks up
* county characteristics with a many-to-one merge on county. Native -merge- sorts the whole
* panel by county to do this; -hmerge- looks each county up in a hash table instead, so
* the panel never moves.

version 17.0
clear all
set more off
set varabbrev off
capture log close
set seed 48103
set sortseed 10031

*===============================================================================
* SECTION 1: SETUP
*===============================================================================

* The prototype lives in the repository, not in PLUS: point the adopath at it.
* Works whether Stata's working directory is the repository root (batch run) or the
* demo/ folder (running the file from the do-file editor usually switches there).
global project_dir "`c(pwd)'"
capture confirm file "${project_dir}/hmerge.ado"
if ( _rc ) {
    global project_dir "`c(pwd)'/.."
}
confirm file "${project_dir}/hmerge.ado"
adopath ++ "${project_dir}"

* Size of the demo. 1,000,000 people x 10 years = 10 million rows (about 30 seconds in
* total). Lower n_people for a quicker look; the speedup grows with the number of rows.
local n_people   = 1000000
local n_years    = 10
local n_counties = 3000

*===============================================================================
* SECTION 2: BUILD THE TWO DATASETS
*===============================================================================

* --- County file: one row per county (the "using" side of an m:1 merge) ---
clear
set obs `n_counties'
generate long   county_id         = _n
generate double median_income     = round(40000 + 30000 * runiform(), 100)
generate double unemployment_rate = round(3 + 6 * runiform(), 0.1)
label variable county_id         "County identifier"
label variable median_income     "County median household income (USD)"
label variable unemployment_rate "County unemployment rate (percent)"

isid county_id
compress
tempfile tmp_counties
save "`tmp_counties'"

* --- Person-year panel: sorted by person and year, as panels usually are ---
clear
set obs `n_people'
generate long person_id = _n
generate long county_id = runiformint(1, `n_counties')
expand `n_years'
bysort person_id: generate int year = 2014 + _n
generate double wage = round(exp(10 + 0.5 * rnormal()), 1)
label variable person_id "Person identifier"
label variable year      "Survey year"
label variable wage      "Annual wage (USD)"

sort person_id year
isid person_id year
compress
tempfile tmp_panel
save "`tmp_panel'"

display as text "Panel: " as result %12.0fc _N as text " person-years; counties: " ///
    as result %6.0fc `n_counties'

*===============================================================================
* SECTION 3: PLAIN MERGE -- NATIVE MERGE VS HMERGE
*===============================================================================

* Native merge: sorts the whole panel by county_id first, then joins.
use "`tmp_panel'", clear
timer clear 1
timer on 1
merge m:1 county_id using "`tmp_counties'"
timer off 1
tabulate _merge
assert _merge == 3
drop _merge

* Save the native result in a fixed order so it can be compared cell by cell below.
sort person_id year
tempfile tmp_native_result
save "`tmp_native_result'"

* hmerge: same command, same syntax; it builds a hash table on the 3,000 counties and
* looks up each of the 10 million panel rows. The panel keeps its original order.
use "`tmp_panel'", clear
timer clear 2
timer on 2
hmerge m:1 county_id using "`tmp_counties'"
timer off 2
tabulate _merge
assert _merge == 3
drop _merge

* Same data? Put hmerge's result in the same order and compare every variable and value.
sort person_id year
cf _all using "`tmp_native_result'", all
display as result "Plain merge: hmerge and native merge produce identical data."

*===============================================================================
* SECTION 4: THE COMMON PANEL CASE -- KEEP THE PANEL SORTED BY PERSON AND YEAR
*===============================================================================

* After a native m:1 merge the rows come back in county order, so a panel workflow has to
* sort back by person and year before using -by person_id:- or lags. hmerge never moved
* the rows, so the panel is still in person-year order when it finishes.

use "`tmp_panel'", clear
timer clear 3
timer on 3
merge m:1 county_id using "`tmp_counties'", nogenerate
sort person_id year
timer off 3

use "`tmp_panel'", clear
timer clear 4
timer on 4
hmerge m:1 county_id using "`tmp_counties'", nogenerate
timer off 4

* hmerge left the panel sorted, and Stata still knows it (no using-only rows were added).
local still_sorted_by : sortedby
display as text "After hmerge the data are sorted by: " as result "`still_sorted_by'"
assert "`still_sorted_by'" == "person_id year"

*===============================================================================
* SECTION 5: RESULTS
*===============================================================================

timer list
local native_plain  = r(t1)
local hmerge_plain  = r(t2)
local native_panel  = r(t3)
local hmerge_panel  = r(t4)

local speedup_plain = `native_plain' / `hmerge_plain'
local speedup_panel = `native_panel' / `hmerge_panel'

display _newline as text "{hline 64}"
display as text "Merging " as result %12.0fc `=`n_people' * `n_years'' ///
    as text " person-years with " as result %6.0fc `n_counties' as text " counties"
display as text "{hline 64}"
display as text %-38s "Case" %10s "merge" %10s "hmerge" %8s "ratio"
display as text %-38s "Plain m:1 merge" ///
    as result %9.2f `native_plain' "s" %9.2f `hmerge_plain' "s" %7.1f `speedup_plain' "x"
display as text %-38s "Merge, then keep person-year order" ///
    as result %9.2f `native_panel' "s" %9.2f `hmerge_panel' "s" %7.1f `speedup_panel' "x"
display as text "{hline 64}"
display as text "Results are identical (cf above). Stata/MP " c(stata_version) ///
    ", " c(processors) " cores."
display as text "When is native merge the better choice? If you want the result sorted by"
display as text "the merge key (e.g. you run -bysort county_id:- next), the sort hmerge skips"
display as text "has to happen anyway, and native merge is as fast or slightly faster."
