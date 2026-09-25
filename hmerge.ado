*! version 0.3.0  25sep2026  CJ Libassi
*! hmerge: merge m:1 and 1:1 without sorting the master data (prototype)
*! https://github.com/clibassi/hmerge -- written with help from Claude (Anthropic)
program hmerge, rclass
    version 17

    * ---------------------------------------------------------------------
    * 0. Anything we do not implement goes to native -merge- unchanged, so
    *    hmerge is never less capable than merge.
    * ---------------------------------------------------------------------
    local cmdline `"`0'"'
    * r(path) records what the call did: "direct", "ordered", or "hash" (plugin join) or
    * "native: <reason>" (handed to merge). The test suite checks it.
    gettoken mtype rest : 0, parse(" ,")
    gettoken first : rest, parse(" ,")
    if ( "`first'" == "_n" ) {
        display as text "(hmerge: a sequential merge (1:1 _n); using merge instead)"
        merge `cmdline'
        return add
        return local path "native: sequential merge"
        exit
    }
    local 0 `"`rest'"'
    syntax [varlist(default=none)] using/ [, ///
        ASSERT(string)                      ///
        GENerate(name)                      ///
        NOGENerate                          ///
        KEEP(string)                        ///
        KEEPUSing(string)                   ///
        noLabels                            ///
        noNOTEs                             ///
        noREPort                            ///
        SORTED                              ///
        SORT                                ///
        UPDATE REPLACE FORCE DEBUG          ///
    ]
    local keys `varlist'
    if ( "`keys'" == "" ) {
        * same message and return code as merge
        if ( "`mtype'" == "1:1" ) {
            display as error "{it:varlist} or {bf:_n} required after {bf:merge 1:1}"
        }
        else {
            display as error "{it:varlist} must be specified after {bf:merge `mtype'}"
        }
        exit 198
    }
    if ( "`mtype'" == "n:1" ) local mtype m:1
    if ( "`mtype'" == "1:n" ) local mtype 1:m

    * native options, rebuilt from the parse (never by string surgery)
    local nopts
    if ( `"`assert'"' != "" )    local nopts `nopts' assert(`assert')
    if ( "`generate'" != "" )    local nopts `nopts' generate(`generate')
    if ( `"`keep'"' != "" )      local nopts `nopts' keep(`keep')
    if ( `"`keepusing'"' != "" ) local nopts `nopts' keepusing(`keepusing')
    local nopts `nopts' `nogenerate' `labels' `notes' `report' `sorted' `update' `replace' `force' `debug'

    local fallback
    if ( !inlist("`mtype'", "1:1", "m:1") ) local fallback "merge type `mtype'"
    if ( "`update'`replace'`force'" != "" ) local fallback "option update/replace/force"
    if ( "`fallback'" != "" ) {
        display as text "(hmerge: `fallback'; using merge instead)"
        merge `mtype' `keys' using `"`using'"', `nopts'
        if ( "`sort'" != "" ) sort `keys'
        return add
        return local path "native: `fallback'"
        exit
    }

    if ( "`generate'" != "" & "`nogenerate'" != "" ) {
        display as error "options generate() and nogenerate may not be combined"
        exit 198
    }
    if ( "`nogenerate'" != "" ) {
        tempvar mergevar
        local mergevaristemp 1
    }
    else {
        local mergevar = cond("`generate'" != "", "`generate'", "_merge")
        local mergevaristemp 0
        capture confirm new variable `mergevar'
        if ( _rc ) {
            display as error "variable `mergevar' already defined"
            exit 110
        }
    }

    _hm_results keepcodes : `"`keep'"'
    _hm_results assertcodes : `"`assert'"'

    * Counts suffice for assert() and reporting. Only keep() needs per-row
    * result codes when the user did not request a merge-result variable.
    local writecodes = !`mergevaristemp' | ("`keepcodes'" != "")
    local pluginmergevar `mergevar'
    if ( !`writecodes' ) local pluginmergevar

    if ( regexm(`"`using'"', "^(http|https|ftp)://") ) {
        display as text "(hmerge: a using file on the web; using merge instead)"
        merge `mtype' `keys' using `"`using'"', `nopts'
        if ( "`sort'" != "" ) sort `keys'
        return add
        return local path "native: using file on the web"
        exit
    }
    mata: st_local("using", _hm_fullname(st_local("using")))
    confirm file `"`using'"'

    * Two more reasons to hand the job to merge: no compiled plugin on this
    * platform, or data too large for the plugin interface, which indexes
    * observations with a 32-bit integer (ST_int)
    * (probe by calling the plugin's no-op free step: -program list- fails on
    * plugin programs even when they are loaded)
    capture plugin call hmerge_plugin, free
    if ( _rc ) local fallback "no hmerge plugin for this platform"
    quietly describe using `"`using'"', short   // houserule-ok: header read only
    local Nusing = r(N)
    * $HMERGE_TEST_MAXOBS lowers the threshold so the test suite can exercise
    * this path without billions of observations
    local maxobs = 2147483647
    if ( "$HMERGE_TEST_MAXOBS" != "" ) {
        capture confirm integer number $HMERGE_TEST_MAXOBS
        if ( !_rc ) {
            if ( $HMERGE_TEST_MAXOBS > 0 ) local maxobs = $HMERGE_TEST_MAXOBS
        }
    }
    * master plus using bounds the merged result (all using observations could
    * be appended), so guard the sum, not each dataset separately
    if ( _N + `Nusing' >= `maxobs' ) {
        local fallback "the merged data could reach the plugin interface's limit of 2,147,483,647 observations"
    }
    if ( "`fallback'" != "" ) {
        display as text "(hmerge: `fallback'; using merge instead)"
        merge `mtype' `keys' using `"`using'"', `nopts'
        if ( "`sort'" != "" ) sort `keys'
        return add
        return local path "native: `fallback'"
        exit
    }

    tempname U L tok
    local token "`tok'_`=subinstr("`c(current_time)'", ":", "", .)'"
    local N0 = _N
    local prof = ("$HMERGE_PROFILE" == "1")
    if ( `prof' ) {
        forvalues t = 81 / 85 {
            timer clear `t'
        }
        timer on 81
    }

    * ---------------------------------------------------------------------
    * 1. VALIDATE. Nothing in this phase modifies the master dataset, so an
    *    error here leaves it exactly as it was (as native merge does).
    * ---------------------------------------------------------------------
    local phase validate
    capture noisily {
        * load keys + payload; -use varlist- expands keepusing() wildcards
        * and ranges against the using file and keeps the file's order
        frame create `U'
        if ( `"`keepusing'"' == "" ) frame `U': use `"`using'"'
        else frame `U': use `keys' `keepusing' using `"`using'"'
        * (not -unab-: it returns via c_local, which a frame prefix loses)
        frame `U': quietly ds   // houserule-ok: only r(varlist) is wanted
        local uvars `r(varlist)'
        local payload : list uvars - keys

        local keyw
        foreach k of local keys {
            local mt : type `k'
            frame `U': local ut : type `k'
            if ( "`mt'" == "strL" | "`ut'" == "strL" ) {
                local fallback "strL key `k'"
                exit 17099
            }
            local ms = substr("`mt'", 1, 3) == "str"
            local us = substr("`ut'", 1, 3) == "str"
            if ( `ms' != `us' ) {
                display as error "key variable `k' is " cond(`ms', "str", "numeric") ///
                    " in master but " cond(`us', "str", "numeric") " in using data"
                exit 106
            }
            local keyw `keyw' `=cond(`ms', max(real(substr("`mt'", 4, .)), real(substr("`ut'", 4, .))), 0)'
        }

        local payw
        local mask
        local newvars
        local newtypes
        foreach v of local payload {
            frame `U': local ut : type `v'
            if ( "`v'" == "`mergevar'" & !`mergevaristemp' ) {
                display as error "variable `mergevar' already defined in using data"
                exit 110
            }
            local us = substr("`ut'", 1, 3) == "str"
            capture confirm variable `v', exact
            if ( _rc ) {
                local mt
                local mask `mask' 1
                local newvars `newvars' `v'
                local newtypes `newtypes' `ut'
            }
            else {
                local mt : type `v'
                local ms = substr("`mt'", 1, 3) == "str"
                if ( `ms' != `us' ) {
                    display as error "variable `v' is " cond(`ms', "str", "numeric") ///
                        " in master but " cond(`us', "str", "numeric") " in using data"
                    exit 106
                }
                local mask `mask' 0
            }
            if ( "`ut'" == "strL" | "`mt'" == "strL" ) {
                local fallback "strL variable `v'"
                exit 17099
            }
            local payw `payw' `=cond(`us', real(substr("`ut'", 4, .)), 0)'
        }

        local kk : word count `keys'
        local kp : word count `payload'
        local uniqmaster = ("`mtype'" == "1:1")

        if ( `prof' ) {
            timer off 81
            timer on 82
        }
        capture frame `U': plugin call hmerge_plugin `keys' `payload', ///
            build `token' `kk' `kp' 1 `keyw' `payw'
        if ( _rc == 459 ) {
            _hm_notunique "`keys'" using
            exit 459
        }
        else if ( _rc ) exit _rc
        if ( `prof' ) {
            timer off 82
            timer on 83
        }

        frame `U' {
            foreach v in `keys' `payload' {
                local ut_`v' : type `v'
            }
        }
        * merge copies every value-label definition in the using file, even
        * for variables keepusing() leaves out; a partial -use- does not load
        * those, so read the definitions from a one-observation load
        local vlnames
        local LF `U'
        if ( "`labels'" == "" ) {
            if ( `"`keepusing'"' != "" ) {
                local LF `L'
                frame create `L'
                capture frame `L': use in 1 using `"`using'"'
                if ( _rc ) frame `L': use using `"`using'"'
            }
            frame `LF': quietly label dir   // houserule-ok: only r(names) is wanted
            local vlnames `r(names)'
        }
        * Variable labels, formats, value-label names and definitions are
        * copied by Mata (st_varlabel, st_vlload, ...), never through macros
        * or a -label save- file: label text comes from the using data and
        * must not be expanded or executed as Stata code.
        mata: _hm_meta_save("`U'", "`LF'", tokens(st_local("newvars")), ///
            tokens(st_local("vlnames")), "`tok'")
        capture frame drop `L'

        * the plugin now holds keys and payload: free the frame before the
        * master is touched, so peak memory holds the using data once
        frame drop `U'
        * match: reads master keys, checks 1:1 uniqueness, writes nothing
        capture plugin call hmerge_plugin `keys', ///
            match `token' `kk' `kp' `uniqmaster' `keyw' `payw'
        if ( _rc == 459 ) {
            _hm_notunique "`keys'" master
            exit 459
        }
        else if ( _rc ) exit _rc
        local n1 = `hm_n1'
        local n2 = `hm_n2'
        local n3 = `hm_n3'

        * -----------------------------------------------------------------
        * 2. COMMIT. From here the master changes; on error we roll back
        *    new variables and appended rows.
        * -----------------------------------------------------------------
        local phase commit
        foreach v in `keys' `payload' {
            if ( `:list v in newvars' ) continue
            _hm_promote `v' `ut_`v''
        }
        if ( "`newvars'" != "" ) {
            mata: (void) st_addvar(tokens(st_local("newtypes")), tokens(st_local("newvars")), 1)
        }
        if ( `writecodes' ) {
            mata: (void) st_addvar("byte", st_local("mergevar"), 1)
        }
        plugin call hmerge_plugin `keys' `payload' `pluginmergevar', ///
            write `token' `kk' `kp' `keyw' `payw' `mask'
        if ( `prof' ) {
            timer off 83
            timer on 84
        }

        * using-only rows: appended when kept, and also when assert() is
        * given, because merge checks assert() before applying keep()
        local want2 = ("`keepcodes'" == "") | strpos("`keepcodes'", "2") | ("`assertcodes'" != "")
        local appended 0
        if ( `n2' > 0 & `want2' ) {
            quietly set obs `=`N0' + `n2''   // houserule-ok: merge prints no obs-count note
            * Appended rows follow key order, but the combined order need not.
            _hm_clear_sortedby
            plugin call hmerge_plugin `keys' `payload' `pluginmergevar', ///
                append `token' `kk' `kp' `N0' `keyw' `payw'
            local appended `n2'
        }
    }
    local rc = _rc
    if ( `prof' ) {
        forvalues t = 81 / 84 {
            capture timer off `t'
        }
        timer on 85
    }
    capture plugin call hmerge_plugin, free
    capture frame drop `U'
    capture frame drop `L'
    if ( `rc' ) capture mata: _hm_meta_drop("`tok'")
    if ( `rc' ) {
        if ( "`phase'" == "commit" ) {
            * best-effort rollback of what the commit phase added
            capture drop `newvars'
            capture drop `mergevar'
            if ( _N > `N0' ) {
                keep in 1 / `N0'
            }
        }
        if ( `rc' == 17099 ) {
            display as text "(hmerge: `fallback'; using merge instead)"
            merge `mtype' `keys' using `"`using'"', `nopts'
            if ( "`sort'" != "" ) sort `keys'
            return add
            return local path "native: `fallback'"
            exit
        }
        exit `rc'
    }

    * ---------------------------------------------------------------------
    * 3. Metadata
    * ---------------------------------------------------------------------
    * value-label definitions the master lacks (master definitions win, as in
    * merge), then each new variable's label, value-label name (attached even
    * under nolabels, as merge does) and format
    capture noisily mata: _hm_meta_apply("`tok'", tokens(st_local("newvars")))
    if ( _rc ) {
        capture mata: _hm_meta_drop("`tok'")
        display as error "(hmerge: the data were merged, but some variable labels, value labels"
        display as error " or formats from the using data could not be copied)"
    }
    if ( !`mergevaristemp' ) {
        capture label list _merge
        if ( _rc ) {
            label define _merge 1 "Master only (1)" 2 "Using only (2)" ///
                3 "Matched (3)" 4 "Missing updated (4)" 5 "Nonmissing conflict (5)"
        }
        label values `mergevar' _merge
        label variable `mergevar' "Matching result from merge"
    }

    * ---------------------------------------------------------------------
    * 4. assert() on the full result (no data pass), then keep()
    * ---------------------------------------------------------------------
    if ( "`assertcodes'" != "" ) {
        local bad 0
        forvalues c = 1 / 3 {
            if ( !strpos("`assertcodes'", "`c'") & `n`c'' > 0 ) local bad 1
        }
        if ( `bad' ) {
            display as error "after hmerge, not all observations satisfy assert(`assert')"
            display as error "(merged result left in memory)"
            exit 9
        }
    }
    if ( "`keepcodes'" != "" ) {
        * codes present in the data but not kept (using-only rows exist in
        * the data only if they were appended)
        local present1 = `n1' > 0
        local present2 = `appended' > 0
        local present3 = `n3' > 0
        local dropc
        forvalues c = 1 / 3 {
            if ( !strpos("`keepcodes'", "`c'") & `present`c'' ) local dropc `dropc' `c'
        }
        if ( "`dropc'" != "" ) {
            local expr
            foreach c of local dropc {
                local expr `expr' | `mergevar' == `c'
            }
            local expr = substr(`"`expr'"', 3, .)
            quietly drop if `expr'   // houserule-ok: counts are reported below
        }
        forvalues c = 1 / 3 {
            if ( !strpos("`keepcodes'", "`c'") ) local n`c' 0
        }
    }

    if ( "`sort'" != "" ) sort `keys'

    if ( `prof' ) {
        timer off 85
        timer list
        display as text "HMPROFILE index=`hm_index' load=" r(t81) " build=" r(t82) " match_write=" r(t83) " append=" r(t84) " finish=" r(t85)
    }
    return local path "`hm_index'"
    if ( c(noisily) & "`report'" == "" ) _hm_table `n1' `n2' `n3' `mergevar' `mergevaristemp'
end

* Map keep()/assert() words to codes with merge's documented rule: a digit
* 1-5, or a case-sensitive abbreviation of masters (>= 3 chars), usings (2),
* matches/matched (3), match_updates or match_conflicts (8). Codes 4-5 cannot
* occur without update/replace, which fall back to native merge.
program _hm_results
    gettoken target 0 : 0
    gettoken colon list : 0
    local list `list'
    local codes
    foreach w of local list {
        local L = strlen(`"`w'"')
        local c
        if ( inlist(`"`w'"', "1", "2", "3", "4", "5") ) local c `w'
        else if ( substr("masters", 1, max(3, `L')) == `"`w'"' )         local c 1
        else if ( substr("usings", 1, max(2, `L')) == `"`w'"' )          local c 2
        else if ( substr("matches", 1, max(3, `L')) == `"`w'"' )         local c 3
        else if ( substr("matched", 1, max(3, `L')) == `"`w'"' )         local c 3
        else if ( substr("match_updates", 1, max(8, `L')) == `"`w'"' )   local c 4
        else if ( substr("match_conflicts", 1, max(8, `L')) == `"`w'"' ) local c 5
        else {
            display as error `"`w':  invalid resulttype"'
            exit 198
        }
        local codes `codes' `c'
    }
    c_local `target' `codes'
end

* merge's message for a key that does not identify observations
program _hm_notunique
    args keys side
    local nk : word count `keys'
    if ( `nk' == 1 ) {
        display as error "variable `keys' does not uniquely identify observations in the `side' data"
    }
    else {
        display as error "variables `keys' do not uniquely identify observations in the `side' data"
    }
end

* Widen a master variable's storage type so values of using type `ut' fit.
program _hm_promote
    args v ut
    local mt : type `v'
    if ( "`mt'" == "`ut'" ) exit
    if ( substr("`mt'", 1, 3) == "str" ) {
        local mw = real(substr("`mt'", 4, .))
        local uw = real(substr("`ut'", 4, .))
        if ( `uw' > `mw' ) {
            recast `ut' `v'
            display as text "(variable {bf:`v'} was {bf:`mt'}, now {bf:`ut'} to accommodate using data's values)"
        }
        exit
    }
    local rank_byte 1
    local rank_int 2
    local rank_long 3
    local rank_float 4
    local rank_double 5
    local new `mt'
    if ( `rank_`ut'' > `rank_`mt'' ) local new `ut'
    * float cannot hold every long, and vice versa: go to double
    if ( inlist("`mt' `ut'", "long float", "float long") ) local new double
    if ( "`new'" != "`mt'" ) {
        recast `new' `v'
        display as text "(variable {bf:`v'} was {bf:`mt'}, now {bf:`new'} to accommodate using data's values)"
    }
end

* Clear Stata's sorted-by flag without sorting: a real change to the first
* sort variable in obs 1 clears the flag; the value is then restored through
* Mata, which does not re-set the flag. Must run with _N > 0.
program _hm_clear_sortedby
    local sb : sortedby
    if ( "`sb'" == "" | _N == 0 ) exit
    local v : word 1 of `sb'
    capture confirm string variable `v'
    if ( _rc ) {
        mata: _hm_keep = st_data(1, "`v'")
        quietly replace `v' = cond(`v' == 0, 1, 0) in 1   // houserule-ok: flag-clearing touch
        mata: st_store(1, "`v'", _hm_keep)
    }
    else {
        mata: _hm_keep = st_sdata(1, "`v'")
        quietly replace `v' = cond(`v' == "", "a", "") in 1   // houserule-ok: flag-clearing touch
        mata: st_sstore(1, "`v'", _hm_keep)
    }
    mata: mata drop _hm_keep
    local sb : sortedby
    if ( "`sb'" != "" ) {
        display as error "hmerge: internal error, could not clear sort flag"
        exit 459
    }
end


program _hm_table
    args n1 n2 n3 mergevar istemp
    if ( !`istemp' ) {
        local v1 "(`mergevar'==1)"
        local v2 "(`mergevar'==2)"
        local v3 "(`mergevar'==3)"
    }
    display
    display as text _col(5) "Result" _col(33) "Number of obs"
    display as text _col(5) "{hline 41}"
    display as text _col(5) "Not matched" _col(30) as result %16.0fc (`n1' + `n2')
    if ( `n1' | `n2' ) {
        display as text _col(9) "from master" _col(30) as result %16.0fc `n1' as text "  `v1'"
        display as text _col(9) "from using"  _col(30) as result %16.0fc `n2' as text "  `v2'"
        display
    }
    display as text _col(5) "Matched" _col(30) as result %16.0fc `n3' as text "  `v3'"
    display as text _col(5) "{hline 41}"
end

mata:
// Save, from frame ufr, the variable label, format and value-label name of each
// new variable, and from frame lfr the definitions of the value labels named in
// vlnames. Stored in Mata externals keyed by obj (the call's token).
void _hm_meta_save(string scalar ufr, string scalar lfr, string rowvector newvars,
                   string rowvector vlnames, string scalar obj)
{
    string scalar cur
    string matrix M
    real scalar i
    real colvector vals
    string colvector txt
    transmorphic A
    pointer() scalar p

    cur = st_framecurrent()
    st_framecurrent(ufr)
    M = J(3, cols(newvars), "")
    for (i = 1; i <= cols(newvars); i++) {
        M[1, i] = st_varlabel(newvars[i])
        M[2, i] = st_varformat(newvars[i])
        M[3, i] = st_varvaluelabel(newvars[i])
    }
    A = asarray_create()
    st_framecurrent(lfr)
    for (i = 1; i <= cols(vlnames); i++) {
        st_vlload(vlnames[i], vals, txt)
        asarray(A, vlnames[i] + ":v", vals)
        asarray(A, vlnames[i] + ":t", txt)
    }
    st_framecurrent(cur)
    _hm_meta_drop(obj)
    p = crexternal("_hmM" + obj)
    *p = M
    p = crexternal("_hmA" + obj)
    *p = A
    p = crexternal("_hmN" + obj)
    *p = vlnames
}

// Apply saved metadata to the current (master) data, then drop it.
void _hm_meta_apply(string scalar obj, string rowvector newvars)
{
    string matrix M
    string rowvector vlnames
    transmorphic A
    real scalar i

    M = *findexternal("_hmM" + obj)
    A = *findexternal("_hmA" + obj)
    vlnames = *findexternal("_hmN" + obj)
    for (i = 1; i <= cols(vlnames); i++) {
        if (!st_vlexists(vlnames[i])) {
            st_vlmodify(vlnames[i], asarray(A, vlnames[i] + ":v"), asarray(A, vlnames[i] + ":t"))
        }
    }
    for (i = 1; i <= cols(newvars); i++) {
        st_varlabel(newvars[i], M[1, i])
        if (M[3, i] != "") st_varvaluelabel(newvars[i], M[3, i])
        st_varformat(newvars[i], M[2, i])
    }
    _hm_meta_drop(obj)
}

void _hm_meta_drop(string scalar obj)
{
    if (findexternal("_hmM" + obj) != NULL) rmexternal("_hmM" + obj)
    if (findexternal("_hmA" + obj) != NULL) rmexternal("_hmA" + obj)
    if (findexternal("_hmN" + obj) != NULL) rmexternal("_hmN" + obj)
}

string scalar _hm_fullname(string scalar fn)
{
    string scalar path, file
    pragma unset path
    pragma unset file
    pathsplit(fn, path, file)
    if (strpos(file, ".") == 0) return(fn + ".dta")
    return(fn)
}
end

capture program drop hmerge_plugin
* -capture-: without a compiled plugin for this platform, hmerge still loads and
* falls back to merge (see "no compiled hmerge plugin" above)
capture program hmerge_plugin, plugin using("hmerge.plugin")
