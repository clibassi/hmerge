* test_hmerge.do -- differential tests: hmerge vs native merge.
*
* For every case, the same master/using files go through native -merge- and
* -hmerge-, each in a clean state. The test passes when
*   (a) both return the same rc, and when rc==0:
*   (b) same variables in the same order, same storage types, formats,
*       variable labels, and attached value labels (with identical
*       definitions);
*   (c) identical values in every cell once both results are ordered by
*       (keys, original master row, _merge) -- native merge's order within a
*       key is not stable, so row order within ties is not compared;
*   (d) any sort flag hmerge leaves on the data is true.
* With option -sort-, (e) the hmerge result must also be sorted by the keys.
*
* Usage (repo root): stata-mp -b do tests/test_hmerge.do

version 17
clear all
set more off
set varabbrev off
set linesize 255
* optional argument: package directory (default: the repository root, .)
args proto
if ( "`proto'" == "" ) local proto .
local protodir "`proto'"
if substr("`proto'", 1, 1) != "/" local protodir "`c(pwd)'/`proto'"
adopath ++ "`protodir'"
which hmerge

global HM_PASS 0
global HM_FAIL 0
global HM_FAILED ""

capture program drop hm_case
program hm_case
    * hm_case name, master(file) using(file) spec(string) [sortcheck]
    syntax name(name=name), master(string) using(string) spec(string) [SORTcheck]
    tempfile nat
    local ok 1
    gettoken mt rest : spec
    local keys
    foreach w of local rest {
        if ( "`w'" == "using" ) continue, break
        local keys `keys' `w'
    }

    use `"`master'"', clear
    gen long __obs = _n
    capture noisily merge `spec'
    local rc_nat = _rc
    if ( `rc_nat' == 0 ) save `"`nat'"'
    * state left in memory, compared even after an error
    local post_nat "N=`=_N' k=`=c(k)'"

    use `"`master'"', clear
    gen long __obs = _n
    local hspec `spec'
    if ( "`sortcheck'" != "" ) local hspec `spec' sort
    if ( !strpos(`"`hspec'"', ",") & "`sortcheck'" != "" ) local hspec `spec', sort
    capture noisily hmerge `hspec'
    local rc_hm = _rc
    local path_hm "`r(path)'"
    * a successful call must have used the plugin join; a silent hand-off to
    * merge would make every comparison below pass trivially
    if ( `rc_hm' == 0 & !inlist("`path_hm'", "direct", "hash", "ordered") & !strpos("`name'", "fallback") ) {
        display as error "FAIL `name': hmerge ran native merge instead of the plugin (`path_hm')"
        local ok 0
    }
    local post_hm "N=`=_N' k=`=c(k)'"
    if ( `rc_nat' != 0 & `"`post_nat'"' != `"`post_hm'"' ) {
        display as error "FAIL `name': state after error differs: native `post_nat', hmerge `post_hm'"
        local ok 0
    }

    if ( `rc_nat' != `rc_hm' ) {
        display as error "FAIL `name': rc native=`rc_nat' hmerge=`rc_hm'"
        local ok 0
    }
    else if ( `rc_hm' == 0 ) {
        * (d) the sort flag must be true
        local sb : sortedby
        if ( "`sb'" != "" ) {
            gen long __pos = _n
            sort `sb', stable
            capture assert __pos == _n
            if ( _rc ) {
                display as error "FAIL `name': data claims sortedby(`sb') but is not"
                local ok 0
            }
            drop __pos
        }
        * (e) option sort => sorted by keys
        if ( "`sortcheck'" != "" ) {
            gen long __pos = _n
            sort `keys', stable
            capture assert __pos == _n
            if ( _rc ) {
                display as error "FAIL `name': option sort did not leave data sorted by keys"
                local ok 0
            }
            drop __pos
        }
        * (b) metadata
        local hv
        foreach v of varlist _all {
            local hv `hv' `v'|`: type `v''|`: format `v''|`: value label `v''|`: variable label `v''
        }
        mata: _hm_labeldump("hlabs")
        preserve
        use `"`nat'"', clear
        local nv
        foreach v of varlist _all {
            local nv `nv' `v'|`: type `v''|`: format `v''|`: value label `v''|`: variable label `v''
        }
        mata: _hm_labeldump("nlabs")
        restore
        if ( `"`hv'"' != `"`nv'"' ) {
            display as error "FAIL `name': variable metadata differ"
            display as error "  native: `nv'"
            display as error "  hmerge: `hv'"
            local ok 0
        }
        if ( `"`hlabs'"' != `"`nlabs'"' ) {
            display as error "FAIL `name': value label definitions differ"
            display as error `"  native: `nlabs'"'
            display as error `"  hmerge: `hlabs'"'
            local ok 0
        }
        * (c) values
        local mv _merge
        if ( strpos(`"`spec'"', "generate(") ) {
            if ( regexm(`"`spec'"', "generate\(([A-Za-z_0-9]+)\)") ) local mv = regexs(1)
        }
        capture confirm variable `mv'
        local mvsort = cond(_rc, "", "`mv'")
        * sort on every variable: (keys, __obs, _merge) is not unique for
        * 1:m, and identical rows are interchangeable anyway
        sort `keys' __obs `mvsort' _all, stable
        tempfile hmf
        save `"`hmf'"'
        use `"`nat'"', clear
        sort `keys' __obs `mvsort' _all, stable
        capture noisily cf _all using `"`hmf'"', all
        if ( _rc ) {
            display as error "FAIL `name': values differ (cf)"
            local ok 0
        }
    }
    if ( `ok' ) {
        global HM_PASS = $HM_PASS + 1
        display as result "PASS `name' (rc=`rc_hm')"
    }
    else {
        global HM_FAIL = $HM_FAIL + 1
        global HM_FAILED $HM_FAILED `name'
    }
end

mata:
// Dump the definitions of all value labels attached to variables, sorted by
// label name, into a local: "name:v=text;v=text|name:..."
void _hm_labeldump(string scalar mac)
{
    real scalar i, j
    string rowvector names
    string scalar out, lab
    real colvector vals
    string colvector txt
    names = J(1, 0, "")
    for (i = 1; i <= st_nvar(); i++) {
        lab = st_varvaluelabel(i)
        if (lab != "") names = names, lab
    }
    names = uniqrows(names')'
    out = ""
    for (i = 1; i <= cols(names); i++) {
        if (!st_vlexists(names[i])) continue
        st_vlload(names[i], vals, txt)
        out = out + names[i] + ":"
        for (j = 1; j <= rows(vals); j++) out = out + strofreal(vals[j], "%21.0g") + "=" + txt[j] + ";"
        out = out + "|"
    }
    st_local(mac, out)
}
end

tempfile M U U2 Udup M11 Mdup11 Ms Us Mmix Umix Mmiss Umiss Mempty Uempty Mlab Ulab Mover Uover Mbyte Uint Mflt Udbl

* ---------------------------------------------------------------------------
* Fixtures
* ---------------------------------------------------------------------------
* basic numeric m:1: master has duplicate keys, some keys absent from using
clear
set seed 101
set obs 200
gen long id = runiformint(1, 60)
gen double x = rnormal()
save `M'
clear
set obs 50
gen long id = _n * 1 + 10
gen double y = runiform()
gen str7 s = "u" + string(_n)
gen byte b = mod(_n, 3)
label define bl 0 "zero" 1 "one" 2 "two"
label values b bl
label variable y "using y"
format y %6.3f
save `U'

* using with duplicate keys
append using `U'
save `Udup'

* 1:1 fixtures
clear
set obs 100
gen long id = _n * 2
gen double x = _n
save `M11'
expand 2 in 1/3
save `Mdup11'
clear
set obs 80
gen long id = _n * 3
gen double y = -_n
save `U2'

* string keys with different widths on each side
clear
set obs 120
gen str4 k = char(97 + mod(_n, 26)) + string(mod(_n, 7))
gen double x = _n
save `Ms'
clear
set obs 26
gen str9 k = char(96 + _n) + string(mod(_n, 7))
replace k = "zzzzzzzzz" in 26
gen double y = _n * 10
gen str12 note = "note " + string(_n)
save `Us'

* mixed string + numeric multi-key
clear
set obs 300
gen str3 a = char(65 + mod(_n, 4))
gen int  b = mod(_n, 9)
gen byte c = mod(_n, 2)
gen double x = _n
save `Mmix'
clear
set obs 40
gen str5 a = char(65 + mod(_n, 5))
gen int  b = mod(_n, 11)
gen byte c = mod(_n, 2)
duplicates drop a b c, force
gen double y = _n
save `Umix'

* missing and extended-missing keys, empty-string keys
clear
input double id str2 t double x
.  ""  1
.a ""  2
.z "q" 3
1  "q" 4
.  "q" 5
.b ""  6
end
save `Mmiss'
clear
input double id str2 t double y
.  ""  10
.a ""  20
.z "q" 30
2  "q" 40
.c ""  50
end
save `Umiss'

* empty datasets
clear
set obs 0
gen long id = .
gen double x = .
save `Mempty'
clear
set obs 0
gen long id = .
gen double y = .
save `Uempty'

* value labels: same name, different definitions on each side
clear
set obs 5
gen long id = _n
gen byte z = 1
label define zl 1 "master-one"
label values z zl
save `Mlab'
clear
set obs 6
gen long id = _n
gen byte w = 1
label define zl 1 "using-one" 2 "using-two"
label values w zl
save `Ulab'

* overlapping non-key variables (numeric and string, narrower in master)
clear
set obs 10
gen long id = _n
gen byte v = 7
gen str2 sv = "mm"
save `Mover'
clear
set obs 12
gen long id = _n + 5
gen int v = 1000 + _n
gen str10 sv = "using" + string(_n)
gen double y = _n
save `Uover'

* key storage-type mismatches
clear
set obs 20
gen byte id = _n
gen double x = _n
save `Mbyte'
clear
set obs 30
gen int id = _n * 10
gen double y = _n
save `Uint'
clear
set obs 10
gen float id = _n / 10
gen double x = _n
save `Mflt'
clear
set obs 10
gen double id = _n / 10
gen double y = _n
save `Udbl'

* ---------------------------------------------------------------------------
* Cases
* ---------------------------------------------------------------------------
hm_case m1_basic,          master(`M') using(`U') spec(m:1 id using `U')
hm_case m1_basic_sort,     master(`M') using(`U') spec(m:1 id using `U') sortcheck
hm_case m1_keepusing,      master(`M') using(`U') spec(m:1 id using `U', keepusing(y))
hm_case m1_keepusing_key,  master(`M') using(`U') spec(m:1 id using `U', keepusing(id s))
hm_case m1_keep_match,     master(`M') using(`U') spec(m:1 id using `U', keep(match))
hm_case m1_keep_master,    master(`M') using(`U') spec(m:1 id using `U', keep(master))
hm_case m1_keep_using,     master(`M') using(`U') spec(m:1 id using `U', keep(using))
hm_case m1_keep_13,        master(`M') using(`U') spec(m:1 id using `U', keep(1 3))
hm_case m1_keep_mm,        master(`M') using(`U') spec(m:1 id using `U', keep(match master))
hm_case m1_assert_fail,    master(`M') using(`U') spec(m:1 id using `U', assert(match))
hm_case m1_assert_ok,      master(`M') using(`U') spec(m:1 id using `U', assert(1 2 3))
hm_case m1_generate,       master(`M') using(`U') spec(m:1 id using `U', generate(mm))
hm_case m1_nogenerate,     master(`M') using(`U') spec(m:1 id using `U', nogenerate)
hm_case m1_nolabel,        master(`M') using(`U') spec(m:1 id using `U', nolabel)
hm_case m1_noreport,       master(`M') using(`U') spec(m:1 id using `U', noreport)
hm_case m1_using_dups,     master(`M') using(`Udup') spec(m:1 id using `Udup')
hm_case m1_nokeyinusing,   master(`M') using(`U2') spec(m:1 x using `U2')
hm_case o1_basic,          master(`M11') using(`U2') spec(1:1 id using `U2')
hm_case o1_basic_sort,     master(`M11') using(`U2') spec(1:1 id using `U2') sortcheck
hm_case o1_master_dups,    master(`Mdup11') using(`U2') spec(1:1 id using `U2')
hm_case o1_using_dups,     master(`M11') using(`Udup') spec(1:1 id using `Udup')
hm_case o1_unmatched_dups, master(`M') using(`U2') spec(1:1 id using `U2')
hm_case str_widths,        master(`Ms') using(`Us') spec(m:1 k using `Us')
hm_case str_widths_sort,   master(`Ms') using(`Us') spec(m:1 k using `Us') sortcheck
hm_case mixed_keys,        master(`Mmix') using(`Umix') spec(m:1 a b c using `Umix')
hm_case missing_keys,      master(`Mmiss') using(`Umiss') spec(m:1 id t using `Umiss')
hm_case missing_keys_11,   master(`Mmiss') using(`Umiss') spec(1:1 id t using `Umiss')
hm_case empty_master,      master(`Mempty') using(`U') spec(m:1 id using `U')
hm_case empty_using,       master(`M') using(`Uempty') spec(m:1 id using `Uempty')
hm_case empty_both,        master(`Mempty') using(`Uempty') spec(1:1 id using `Uempty')
hm_case label_clash,       master(`Mlab') using(`Ulab') spec(1:1 id using `Ulab')
hm_case overlap_vars,      master(`Mover') using(`Uover') spec(1:1 id using `Uover')
hm_case overlap_vars_match, master(`Mover') using(`Uover') spec(1:1 id using `Uover', keep(match))
hm_case key_byte_int_match, master(`Mbyte') using(`Uint') spec(1:1 id using `Uint', keep(match))
hm_case key_byte_int,      master(`Mbyte') using(`Uint') spec(1:1 id using `Uint')
hm_case key_float_double,  master(`Mflt') using(`Udbl') spec(1:1 id using `Udbl')
hm_case type_mismatch,     master(`Ms') using(`U') spec(m:1 k using `U')
hm_case strkey_vs_num,     master(`Ms') using(`Umiss') spec(m:1 k using `Umiss')
hm_case merge_exists,      master(`M') using(`U') spec(m:1 id using `U', keep(master) generate(x))
hm_case fallback_1m,       master(`U') using(`M') spec(1:m id using `M')

* integer-key index paths: direct addressing (compact range, incl. negatives)
* vs hash fallback (sparse range, non-integers, huge values)
tempfile Mneg Uneg Msp Usp Mbig Ubig
clear
set obs 300
gen long id = runiformint(-50, 50)
replace id = . in 1/5
replace id = .a in 6/8
gen double x = _n
save `Mneg'
clear
set obs 80
gen long id = _n - 40
gen double y = -_n
save `Uneg'
clear
set obs 300
gen double id = runiformint(1, 40) * 1e9
replace id = id + 0.5 in 1/10
gen double x = _n
save `Msp'
clear
set obs 40
gen double id = _n * 1e9
gen double y = _n
save `Usp'
clear
input double id double x
9007199254740992 1
-9007199254740992 2
0 3
-0 4
1e300 5
end
save `Mbig'
clear
input double id double y
9007199254740992 10
-9007199254740992 20
0 30
1e300 50
end
save `Ubig'
hm_case direct_negative,   master(`Mneg') using(`Uneg') spec(m:1 id using `Uneg')
hm_case direct_neg_sort,   master(`Mneg') using(`Uneg') spec(m:1 id using `Uneg') sortcheck
hm_case hash_sparse_ints,  master(`Msp') using(`Usp') spec(m:1 id using `Usp')
hm_case huge_keys,         master(`Mbig') using(`Ubig') spec(m:1 id using `Ubig')
hm_case keepusing_wild,    master(`M') using(`U') spec(m:1 id using `U', keepusing(y*))
hm_case keep_matched_word, master(`M') using(`U') spec(m:1 id using `U', keep(matched mas))
hm_case assert_keep_combo, master(`M') using(`U') spec(m:1 id using `U', assert(match master) keep(match master))
hm_case nolabels_native,   master(`M') using(`U') spec(m:1 id using `U', nolabels)

* using-only observations come back in the same order as native merge (key order)
capture program drop hm_order
program hm_order
    syntax name(name=name), master(string) spec(string)
    use `"`master'"', clear
    merge `spec'
    generate long __pos = _n
    keep if _merge == 2
    tempfile nat2
    save `"`nat2'"'
    use `"`master'"', clear
    hmerge `spec'
    generate long __pos = _n
    keep if _merge == 2
    drop __pos
    tempfile hm2
    save `"`hm2'"'
    use `"`nat2'"', clear
    drop __pos
    capture noisily cf _all using `"`hm2'"', all
    if ( _rc == 0 ) {
        global HM_PASS = $HM_PASS + 1
        display as result "PASS `name'"
    }
    else {
        global HM_FAIL = $HM_FAIL + 1
        global HM_FAILED $HM_FAILED `name'
        display as error "FAIL `name': using-only observations in a different order"
    }
end
* the using files are shuffled first, so file order and key order differ (with
* already-sorted using files this test could not tell the two apart)
foreach u in U Us Umix Umiss Uneg {
    use ``u'', clear
    set seed 9
    generate double __shuffle = runiform()
    sort __shuffle
    drop __shuffle
    tempfile `u'_shuf
    save ``u'_shuf'
}
* dedicated fixtures with many using-only observations (the shared ones have
* zero or one, which cannot reveal an ordering)
clear
set obs 40
generate long id = 2 * _n
generate double x = _n
tempfile Mord
save `Mord'
clear
set obs 120
generate long id = _n
generate str6 k = "k" + string(1000 - _n)
generate double y = -_n
set seed 11
generate double __shuffle = runiform()
sort __shuffle
drop __shuffle
tempfile Uord
save `Uord'
use `Mord', clear
generate str6 k = "k" + string(1000 - id)
tempfile Mords
save `Mords'
hm_order order_using_only_int,  master(`Mord')  spec(m:1 id using `Uord')
hm_order order_using_only_str,  master(`Mords') spec(m:1 k using `Uord', keepusing(y))
hm_order order_using_only_mix,  master(`Mmix')  spec(m:1 a b c using `Umix_shuf')
hm_order order_using_only_miss, master(`Mmiss') spec(m:1 id t using `Umiss_shuf')
hm_order order_using_only_neg,  master(`Mneg')  spec(m:1 id using `Uneg_shuf')

* security: label text from the using data must be copied literally, never
* expanded or executed (value labels, variable labels)
clear
set obs 5
generate long id = _n
generate byte evil = mod(_n, 2)
generate double y = _n
mata: st_vlmodify("evillab", (0 \ 1), ("zero" + char(10) + "global HM_PWNED 1" \ "`" + "c(username)' $" + "S_TIME =2+2 `" + "=1+1'"))
label values evil evillab
mata: st_varlabel("y", "label `" + "c(pwd)' and $" + "HM_PWNED and =3*3" + char(10) + "global HM_PWNED 2")
mata: st_varlabel("evil", char(96) + "=exp(1)'" + char(39))
tempfile Uevil
save `Uevil'
clear
set obs 8
generate long id = mod(_n, 6) + 1
generate double x = _n
tempfile Mevil
save `Mevil'
global HM_PWNED
hm_case label_injection, master(`Mevil') using(`Uevil') spec(m:1 id using `Uevil')
if ( "$HM_PWNED" != "" ) {
    global HM_FAIL = $HM_FAIL + 1
    global HM_FAILED $HM_FAILED label_injection_executed
    display as error "FAIL label_injection_executed: label text ran as code (HM_PWNED=$HM_PWNED)"
}
else {
    global HM_PASS = $HM_PASS + 1
    display as result "PASS label_injection_not_executed"
}

* sorted master: sort flag must survive only when still true
use `M', clear
sort id
save `M', replace
hm_case m1_sorted_master,        master(`M') using(`U') spec(m:1 id using `U')
hm_case m1_sorted_master_nousing, master(`M') using(`U') spec(m:1 id using `U', keep(master match))

* ---------------------------------------------------------------------------
* Randomized property tests: random key domains, duplicate patterns, options
* ---------------------------------------------------------------------------
forvalues s = 1 / 40 {
    clear
    set seed `=1000 + `s''
    local nm = runiformint(0, 400)
    local nu = runiformint(0, 150)
    local dom = runiformint(1, 300)
    local strkey = runiform() < 0.4
    set obs `nm'
    gen long id = runiformint(1, `dom')
    replace id = .a if runiform() < 0.05
    if ( `strkey' ) gen str6 k2 = "k" + string(mod(id, 17))
    gen double x = rnormal()
    tempfile RM RU
    save `RM'
    clear
    set obs `nu'
    gen long id = runiformint(1, `dom')
    replace id = .a if runiform() < 0.05
    if ( `strkey' ) gen str8 k2 = "k" + string(mod(id, 17))
    local keys = cond(`strkey', "id k2", "id")
    duplicates drop `keys', force
    gen double y = runiform()
    gen str3 z = "z" + string(mod(_n, 50))
    save `RU'
    local opts
    local r = runiform()
    if ( `r' < 0.2 )      local opts , keep(match)
    else if ( `r' < 0.4 ) local opts , keep(master match)
    else if ( `r' < 0.5 ) local opts , keepusing(y)
    hm_case rand`s'_m1, master(`RM') using(`RU') spec(m:1 `keys' using `RU' `opts')
    * 1:1 on the same draw: master usually has duplicates -> both must error
    hm_case rand`s'_11, master(`RM') using(`RU') spec(1:1 `keys' using `RU' `opts')
}

display _n as text "hmerge differential tests: " as result "$HM_PASS passed, $HM_FAIL failed"
if ( $HM_FAIL > 0 ) {
    display as error "failed: $HM_FAILED"
    exit 9
}
