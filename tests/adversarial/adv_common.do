* adv_common.do -- helper: run native merge and hmerge on the same input and
* compare full post-state (rc, variables+metadata, sort flag + truth, all value
* label definitions in memory, values), INCLUDING state left after an error.
version 17
set more off
set linesize 255
adopath ++ "$HM_DIR"   // houserule-ok

capture program drop adv_state
program adv_state, rclass
    args f
    * variable metadata
    local meta
    foreach v of varlist _all {
        local meta `meta' `v'|`: type `v''|`: format `v''|`: value label `v''|`: variable label `v''
    }
    return local meta `"`meta'"'
    local sb : sortedby
    return local sb "`sb'"
    local truth 1
    if ( "`sb'" != "" & _N > 0 ) {
        tempvar pos
        gen long `pos' = _n
        sort `sb', stable
        capture assert `pos' == _n
        if ( _rc ) local truth 0
        sort `pos'
        drop `pos'
    }
    return local sbtrue `truth'
    mata: _adv_alllabels("labs")
    return local labs `"`labs'"'
    return local N = _N
    * order-free value signature
    if ( c(k) > 0 & _N > 0 ) {
        preserve
        sort _all, stable
        save `"`f'"', replace
        local sig
        foreach v of varlist _all {
            capture confirm string variable `v'
            if ( _rc ) {
                summarize `v', meanonly
                local sig `sig' `v':`=r(N)':`=r(sum)':`=r(min)':`=r(max)'
            }
        }
        restore
        return local sig `"`sig'"'
        return local file `"`f'"'
    }
end

mata:
void _adv_alllabels(string scalar mac)
{
    real scalar i, j
    string colvector names
    string scalar out
    real colvector vals
    string colvector txt
    stata("quietly label dir")   // houserule-ok
    names = tokens(st_global("r(names)"))'
    if (rows(names) == 0) {
        st_local(mac, "")
        return
    }
    names = sort(names, 1)
    out = ""
    for (i = 1; i <= rows(names); i++) {
        st_vlload(names[i], vals, txt)
        out = out + names[i] + ":"
        for (j = 1; j <= rows(vals); j++) out = out + strofreal(vals[j], "%21.0g") + "=" + txt[j] + ";"
        out = out + "|"
    }
    st_local(mac, out)
}
end

global ADV_BUGS ""
capture program drop adv_run
program adv_run
    syntax name(name=name), master(string) cmd(string asis) [SETUP(string asis)]
    foreach eng in merge hmerge {
        use `"`master'"', clear
        if ( `"`setup'"' != "" ) {
            `setup'
        }
        capture noisily `eng' `cmd'
        local rc_`eng' = _rc
        tempfile F_`eng'
        adv_state `"`F_`eng''"'
        foreach s in meta sb sbtrue labs N sig file {
            local `s'_`eng' `"`r(`s')'"'
        }
    }
    local bad 0
    display as text _n `"==== `name': `cmd'"'
    foreach s in rc meta sb sbtrue labs N sig {
        if ( `"``s'_merge'"' != `"``s'_hmerge'"' ) {
            if ( "`s'" == "sb" ) {
                display as text "  (sortedby differs: native=[`sb_merge'] hmerge=[`sb_hmerge'])"
                continue
            }
            local bad 1
            display as error "  DIFF `s'"
            display as error `"    native: ``s'_merge'"'
            display as error `"    hmerge: ``s'_hmerge'"'
        }
    }
    if ( `"`file_merge'"' != "" & `"`file_hmerge'"' != "" & `rc_merge' == `rc_hmerge' & `"`meta_merge'"' == `"`meta_hmerge'"' ) {
        preserve
        use `"`file_merge'"', clear
        capture noisily cf _all using `"`file_hmerge'"', all
        if ( _rc ) {
            local bad 1
            display as error "  DIFF values (cf)"
        }
        restore
    }
    if ( `bad' ) {
        display as error "BUG? `name'"
        global ADV_BUGS $ADV_BUGS `name'
    }
    else display as result "HOLDS `name'"
end
