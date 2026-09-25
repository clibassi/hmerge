* bench_lib.do -- shared helpers for the stata-grouplab benchmark harness.
* Every benchmark do-file runs `do bench/bench_lib.do` first.
*
* Timing model: each measured command runs between `bl_tic` and `bl_toc`, which
* wrap Stata's millisecond `timer`. Data are reloaded from a saved .dta (outside
* the timed region) before every repetition, so no rep sees another rep's
* side effects. Results are appended as CSV rows to $BL_OUT.

version 17
set more off
set varabbrev off
set rmsg off
set linesize 200

capture program drop bl_init
program bl_init
    * bl_init, out(file.csv) bench(name)
    syntax, out(string) bench(string)
    global BL_OUT   `"`out'"'
    global BL_BENCH `"`bench'"'
    capture confirm file `"`out'"'
    if ( _rc ) {
        tempname fh
        file open `fh' using `"`out'"', write text replace
        file write `fh' "bench,case,impl,N,J,keytype,order,rep,seconds,ok,stata_version,host_procs" _n
        file close `fh'
    }
end

capture program drop bl_tic
program bl_tic
    timer clear 100
    timer on 100
end

capture program drop bl_toc
program bl_toc
    * bl_toc, case() impl() n() j() keytype() order() rep() [ok(0|1)]
    syntax, case(string) impl(string) n(real) j(real) keytype(string) ///
        order(string) rep(integer) [ok(integer 1)]
    timer off 100
    timer list 100
    local secs = r(t100)
    tempname fh
    file open `fh' using `"$BL_OUT"', write text append
    file write `fh' `"$BL_BENCH,`case',`impl',`n',`j',`keytype',`order',`rep',`secs',`ok',`c(stata_version)',`c(processors)'"' _n
    file close `fh'
    display as text "BENCH " %-24s "`case'" %-20s "`impl'" " N=" %12.0fc `n' " J=" %12.0fc `j' " rep `rep': " as result %8.3f `secs' "s"
end

* bl_gen: build a synthetic dataset in memory.
*   n()       observations
*   j()       target number of distinct keys (keys are drawn with replacement,
*             so the realized count can be lower; tests use the realized count)
*   keytype() int1 | int3 | dbl1 | str1 | mixed | strlong
*   order()   random | sorted
*   nvars()   number of double payload variables (default 3)
*   skew      draw keys from a Zipf-like distribution instead of uniform
*   unique    make keys a random permutation of 1..n (J = N exactly)
capture program drop bl_gen
program bl_gen
    syntax, n(integer) j(integer) keytype(string) [order(string) nvars(integer 3) ///
        skew unique seed(integer 20260924)]
    if ( "`order'" == "" ) local order random
    clear
    set seed `seed'
    set obs `n'
    if ( "`unique'" != "" ) {
        gen long _k = _n
        gen double _u = runiform()
        sort _u
        drop _u
    }
    else if ( "`skew'" != "" ) {
        * key rank ~ exp(U * log J): heavy concentration in low ranks
        gen long _k = ceil(exp(runiform() * log(`j')))
    }
    else {
        gen long _k = runiformint(1, `j')
    }
    if ( "`keytype'" == "int1" ) {
        gen long id1 = _k
    }
    else if ( "`keytype'" == "int3" ) {
        * three integer keys whose combination identifies _k
        local b = ceil(`j'^(1/3)) + 1
        gen long id1 = mod(_k, `b')
        gen long id2 = mod(floor(_k / `b'), `b')
        gen long id3 = floor(_k / (`b' * `b'))
    }
    else if ( "`keytype'" == "dbl1" ) {
        gen double id1 = _k + 0.25
    }
    else if ( "`keytype'" == "str1" ) {
        gen str12 id1 = "k" + string(_k, "%011.0f")
    }
    else if ( "`keytype'" == "mixed" ) {
        gen str8 id1 = "s" + string(mod(_k, 1000), "%07.0f")
        gen long id2 = floor(_k / 1000)
    }
    else if ( "`keytype'" == "strlong" ) {
        gen str64 id1 = "prefix-common-to-every-key-" + string(_k, "%030.0f")
    }
    else {
        display as error "unknown keytype `keytype'"
        exit 198
    }
    forvalues v = 1 / `nvars' {
        gen double x`v' = rnormal()
    }
    if ( "`order'" == "sorted" ) {
        sort _k
    }
    drop _k
end

* bl_keys: the grouping variable list for a keytype
capture program drop bl_keys
program bl_keys, rclass
    args keytype
    if ( "`keytype'" == "int3" )       return local keys id1 id2 id3
    else if ( "`keytype'" == "mixed" ) return local keys id1 id2
    else                               return local keys id1
end
