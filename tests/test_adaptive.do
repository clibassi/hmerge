*! file: test_adaptive.do
*! purpose: Differential regressions for ordered matching and lazy uniqueness tracking.
*! author: CJ Libassi, with Codex assistance
*! created: 2026-09-25
version 17
clear all
set more off
set varabbrev off
args package
if "`package'" == "" local package .
adopath ++ "`package'"
global ADAPT_PASS 0

program adaptive_case
    syntax, Master(string) Using(string) [TYPE(string) OPTions(string) PATH(string)]
    if "`type'" == "" local type m:1
    preserve
    tempfile tmp_native
    use "`master'", clear
    generate long original_row = _n
    capture noisily merge `type' k1 k2 using "`using'", `options'
    local native_rc = _rc
    local native_n = _N
    unab native_vars : _all
    local native_types
    foreach v of local native_vars {
        local native_types `native_types' `: type `v''
    }
    sort k1 k2 original_row
    save `tmp_native', replace

    use "`master'", clear
    generate long original_row = _n
    capture noisily hmerge `type' k1 k2 using "`using'", `options'
    local hash_rc = _rc
    local join_path "`r(path)'"
    assert `hash_rc' == `native_rc'
    assert _N == `native_n'
    unab hash_vars : _all
    local hash_types
    foreach v of local hash_vars {
        local hash_types `hash_types' `: type `v''
    }
    assert "`hash_vars'" == "`native_vars'"
    assert "`hash_types'" == "`native_types'"
    if `hash_rc' == 0 & "`path'" != "" assert "`join_path'" == "`path'"
    * Master records retain relative order, even with keep() or tied keys.
    assert original_row > original_row[_n-1] if _n > 1 & !missing(original_row)
    sort k1 k2 original_row
    cf _all using `tmp_native'
    restore
    global ADAPT_PASS = $ADAPT_PASS + 1
end

tempfile tmp_using tmp_master tmp_reverse tmp_empty tmp_growth tmp_duplicate
clear
input double k1 str8 k2 double payload
-2 "" 10
0 "a" 20
0 "aa" 30
2 "é" 40
. "z" 50
.a "z" 60
.z "z" 70
end
sort k1 k2
save `tmp_using'
drop payload
save `tmp_master'
keep if 0
save `tmp_empty'

adaptive_case, master(`tmp_master') using(`tmp_using') type(1:1) path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_using') type(1:1) options(nogenerate assert(match)) path(ordered)
adaptive_case, master(`tmp_empty') using(`tmp_using') type(1:1) options(nogenerate) path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_empty') type(1:1) options(nogenerate) path(ordered)
adaptive_case, master(`tmp_empty') using(`tmp_empty') type(1:1) options(nogenerate) path(ordered)

* Tied master keys; matched, master-only and using-only rows; narrow strings.
use `tmp_master', clear
keep in 1/4
expand 2
sort k1 k2
replace k1 = -3 in 1
save `tmp_master', replace
adaptive_case, master(`tmp_master') using(`tmp_using') path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_using') options(nogenerate) path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_using') options(nogenerate keep(match)) path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_using') options(nogenerate keep(using)) path(ordered)
adaptive_case, master(`tmp_master') using(`tmp_using') options(nogenerate assert(match))
adaptive_case, master(`tmp_master') using(`tmp_using') options(nogenerate assert(match) keep(match))
adaptive_case, master(`tmp_master') using(`tmp_using') type(1:1)

* A late inversion switches to hashing without discarding the matched prefix.
replace k1 = 0 in L
replace k2 = "a" in L
save `tmp_reverse'
adaptive_case, master(`tmp_reverse') using(`tmp_using') path(hash)
adaptive_case, master(`tmp_reverse') using(`tmp_using') options(nogenerate) path(hash)
adaptive_case, master(`tmp_reverse') using(`tmp_using') options(nogenerate keep(master match)) path(hash)

* Many unmatched keys exercise repeated set growth, then late disorder.
clear
set obs 1000
generate double k1 = _n * 100
generate str8 k2 = "new"
save `tmp_growth'
adaptive_case, master(`tmp_growth') using(`tmp_using') type(1:1) options(nogenerate) path(ordered)
replace k1 = 50 in L
save `tmp_growth', replace
adaptive_case, master(`tmp_growth') using(`tmp_using') type(1:1) options(nogenerate) path(hash)
replace k1 = 100 in L
save `tmp_duplicate'
adaptive_case, master(`tmp_duplicate') using(`tmp_using') type(1:1) options(nogenerate)

* Unsorted using data must still reject duplicates and sort appended rows.
use `tmp_using', clear
gsort -k1 k2
save `tmp_reverse', replace
adaptive_case, master(`tmp_growth') using(`tmp_reverse') type(1:1) options(nogenerate) path(hash)
replace k1 = .z in L
replace k2 = "z" in L
save `tmp_duplicate', replace
adaptive_case, master(`tmp_growth') using(`tmp_duplicate') type(1:1)

* Duplicate matched key after switching; prefix matches must remain recorded.
use `tmp_using', clear
drop payload
replace k1 = -2 in L
replace k2 = "" in L
save `tmp_duplicate', replace
adaptive_case, master(`tmp_duplicate') using(`tmp_using') type(1:1) options(nogenerate)

* Adjacent using duplicate caught before matching changes any master values.
use `tmp_using', clear
expand 2
sort k1 k2
save `tmp_duplicate', replace
adaptive_case, master(`tmp_growth') using(`tmp_duplicate') type(1:1) options(nogenerate)

display "adaptive tests: $ADAPT_PASS passed"
assert $ADAPT_PASS == 22
