* test_fallbacks.do -- hmerge's argument errors and fallbacks to native merge.
*   1. no key varlist: same message family and rc (198) as merge, for m:1 and 1:1
*   2. option sorted: accepted, no effect, result identical to merge
*   3. observation guard: above the threshold hmerge calls merge (threshold
*      lowered with $HMERGE_TEST_MAXOBS so this runs on small data)
*   4. no compiled plugin: hmerge still loads, notes it, and calls merge
*      (simulated with a copy of the ado-file in a folder without the plugin)
*
* Usage (repo root): stata-mp -b do tests/test_fallbacks.do [package-dir, default .]
* The no-plugin case starts a second Stata; set STATA to its executable if needed.

version 17
clear all
set more off
set varabbrev off
set linesize 255
args proto
if ( "`proto'" == "" ) local proto .
local protodir "`proto'"
if substr("`proto'", 1, 1) != "/" local protodir "`c(pwd)'/`proto'"
adopath ++ "`protodir'"

global FB_PASS 0
global FB_FAIL 0
capture program drop fb_check
program fb_check
    args name cond
    if ( `cond' ) {
        global FB_PASS = $FB_PASS + 1
        display as result "PASS `name'"
    }
    else {
        global FB_FAIL = $FB_FAIL + 1
        display as error "FAIL `name'"
    }
end

* fixtures: using file sorted by id and flagged as sorted, master sorted too
clear
set obs 40
generate long id = _n
generate double y = _n / 10
sort id
tempfile U M
save `U'
clear
set obs 200
generate long id = mod(_n, 50) + 1
generate double x = _n
sort id
save `M'

* 1. missing key varlist
foreach mt in m:1 1:1 {
    use `M', clear
    capture noisily merge `mt' using `U'
    local rc_nat = _rc
    use `M', clear
    capture noisily hmerge `mt' using `U'
    local rc_hm = _rc
    local ok = (`rc_nat' == `rc_hm') & (`rc_hm' == 198)
    fb_check nokeys_`=subinstr("`mt'", ":", "", .)' `ok'
}

* 2. option sorted on data that really are sorted
use `M', clear
generate long obs0 = _n
merge m:1 id using `U', sorted
sort id obs0
tempfile nat
save `nat'
use `M', clear
generate long obs0 = _n
hmerge m:1 id using `U', sorted
sort id obs0
capture noisily cf _all using `nat', all
fb_check sorted_option `=(_rc == 0)'
* 3. observation guard -> native merge, identical result, note shown
global HMERGE_TEST_MAXOBS 100
use `M', clear
generate long obs0 = _n
log using fb_guard.txt, text replace name(fbg)
hmerge m:1 id using `U'
log close fbg
sort id obs0 _merge
tempfile hm
save `hm'
use `M', clear
generate long obs0 = _n
merge m:1 id using `U'
sort id obs0 _merge
capture noisily cf _all using `hm', all
local same = (_rc == 0)
tempname fh
file open `fh' using fb_guard.txt, read text
local saw 0
file read `fh' line
while ( r(eof) == 0 ) {
    if ( strpos(`"`line'"', "the plugin interface's limit of 2,147,483,647") ) local saw 1
    file read `fh' line
}
file close `fh'
erase fb_guard.txt
fb_check obs_guard_identical `=(`same')'
fb_check obs_guard_note `=(`saw')'
global HMERGE_TEST_MAXOBS

* 3b. the guard bounds master + using: each under the threshold, sum at it
global HMERGE_TEST_MAXOBS 240
use `M', clear
hmerge m:1 id using `U'
local p = r(path)
local ok = (substr("`p'", 1, 7) == "native:")
fb_check guard_on_sum `ok'
global HMERGE_TEST_MAXOBS 241
use `M', clear
hmerge m:1 id using `U'
local p = r(path)
local ok = inlist("`p'", "direct", "hash")
fb_check guard_below_sum `ok'

* 3c. a malformed test-hook value is ignored, not an error
global HMERGE_TEST_MAXOBS abc
use `M', clear
capture noisily hmerge m:1 id using `U'
local rc = _rc
local p = r(path)
local ok = (`rc' == 0) & inlist("`p'", "direct", "hash")
fb_check test_hook_ignored `ok'
global HMERGE_TEST_MAXOBS

* 4. no compiled plugin: ado-file alone in a fresh folder, run in a clean process
tempfile nodir
local nodir "`nodir'_noplugin"
mkdir "`nodir'"
copy "`protodir'/hmerge.ado" "`nodir'/hmerge.ado"
tempfile Mfile Ufile dofile
copy `M' "`nodir'/M.dta"
copy `U' "`nodir'/U.dta"
file open `fh' using "`nodir'/run.do", write text replace
file write `fh' `"adopath ++ "`nodir'""' _n
file write `fh' `"use "`nodir'/M.dta", clear"' _n
file write `fh' `"capture noisily hmerge m:1 id using "`nodir'/U.dta""' _n
file write `fh' `"display "RC=" _rc"' _n
file close `fh'
local here "`c(pwd)'"
cd "`nodir'"
local stata_exe : env STATA
if ( `"`stata_exe'"' == "" ) local stata_exe "/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp"
shell "`stata_exe'" -b do run.do
cd "`here'"
file open `fh' using "`nodir'/run.log", read text
local saw_note 0
local saw_rc0 0
file read `fh' line
while ( r(eof) == 0 ) {
    if ( strpos(`"`line'"', "no hmerge plugin for this platform") ) local saw_note 1
    if ( `"`line'"' == "RC=0" ) local saw_rc0 1
    file read `fh' line
}
file close `fh'
fb_check noplugin_note `=(`saw_note')'
fb_check noplugin_runs `=(`saw_rc0')'
display _n as text "fallback tests: " as result "$FB_PASS passed, $FB_FAIL failed"
if ( $FB_FAIL > 0 ) exit 9
