* bench_merge.do -- end-to-end timing of m:1 / 1:1 joins.
*
* Implementations (each timed from "master in memory, using on disk" to
* "joined data in memory", i.e. what a user waits for):
*   native       merge
*   ftools       fmerge (ftools' join)
*   frames       frame create + use + frlink + frget
*   hmerge       prototype hash join, master order preserved
*   hmerge_sort  prototype + option sort (reproduces merge's key-sorted order)
*
* Usage: stata-mp -b do bench/bench_merge.do <grid> <reps>
*   grid = main | keys | state | wide | one | smoke

args grid reps
if ( "`grid'" == "" ) local grid smoke
if ( "`reps'" == "" ) local reps 3

do bench/bench_lib.do
adopath ++ "`c(pwd)'"
* $BM_TAG suffixes the output file (e.g. _v02); $BM_IMPLS restricts impls
bl_init, out(bench/raw/merge_`grid'${BM_TAG}.csv) bench(merge_`grid'${BM_TAG})

* ---------------------------------------------------------------------------
* One benchmark cell: build master + using files, then time each impl.
* ---------------------------------------------------------------------------
capture program drop bm_cell
program bm_cell
    syntax, n(integer) j(integer) keytype(string) [order(string) mtype(string) ///
        nvars(integer 3) impls(string) usingunsorted reps(integer 3) tag(string)]
    if ( "`order'" == "" ) local order random
    if ( "`mtype'" == "" ) local mtype m:1
    if ( "`impls'" == "" ) local impls $BM_IMPLS
    if ( "`impls'" == "" ) local impls native ftools frames hmerge hmerge_sort
    local case = cond("`tag'" == "", "`mtype'", "`mtype'_`tag'")

    * using file: one row per key 1..J, `nvars' payload doubles
    if ( "`mtype'" == "1:1" ) {
        bl_gen, n(`n') j(`n') keytype(`keytype') nvars(0) unique
    }
    else {
        clear
        set obs `j'
        gen long _k = _n
        bl_keysfrom _k, keytype(`keytype') j(`j')
        drop _k
    }
    bl_keys `keytype'
    local keys `r(keys)'
    forvalues v = 1 / `nvars' {
        gen double y`v' = runiform()
    }
    if ( "`usingunsorted'" == "" ) sort `keys'
    local using bench/data/merge_using_`keytype'_J`j'_n`n'_`mtype'_`nvars'.dta
    local using : subinstr local using ":" "", all
    save "`using'", replace

    * master: N rows, keys drawn from 1..J (m:1) or a permutation (1:1)
    if ( "`mtype'" == "1:1" ) {
        bl_gen, n(`n') j(`n') keytype(`keytype') nvars(3) unique seed(777)
    }
    else {
        bl_gen, n(`n') j(`j') keytype(`keytype') nvars(3) order(`order')
    }
    if ( "`order'" == "sorted" ) sort `keys'
    local master bench/data/merge_master.dta
    save "`master'", replace

    local ylist
    forvalues v = 1 / `nvars' {
        local ylist `ylist' y`v'
    }
    local tags n(`n') j(`j') keytype(`keytype') order(`order')
    forvalues r = 1 / `reps' {
        foreach impl of local impls {
            use "`master'", clear
            if ( "`impl'" == "native" ) {
                bl_tic
                capture noisily merge `mtype' `keys' using "`using'"
                bl_toc, case(`case') impl(native) `tags' rep(`r') ok(`=_rc == 0')
            }
            else if ( "`impl'" == "ftools" ) {
                bl_tic
                capture noisily fmerge `mtype' `keys' using "`using'"
                bl_toc, case(`case') impl(ftools) `tags' rep(`r') ok(`=_rc == 0')
            }
            else if ( "`impl'" == "frames" ) {
                bl_tic
                capture noisily {
                    frame create _u
                    frame _u: use "`using'"
                    frlink `mtype' `keys', frame(_u)
                    frget `ylist', from(_u)
                }
                local ok = _rc == 0
                capture frame drop _u
                bl_toc, case(`case') impl(frames) `tags' rep(`r') ok(`ok')
            }
            else if ( "`impl'" == "hmerge" ) {
                bl_tic
                capture noisily hmerge `mtype' `keys' using "`using'"
                bl_toc, case(`case') impl(hmerge) `tags' rep(`r') ok(`=_rc == 0')
            }
            else if ( "`impl'" == "hmerge_sort" ) {
                bl_tic
                capture noisily hmerge `mtype' `keys' using "`using'", sort
                bl_toc, case(`case') impl(hmerge_sort) `tags' rep(`r') ok(`=_rc == 0')
            }
        }
    }
end

* bl_keysfrom: build key variables of a keytype from an integer code variable
capture program drop bl_keysfrom
program bl_keysfrom
    syntax varname, keytype(string) j(integer)
    local k `varlist'
    if ( "`keytype'" == "int1" )         gen long id1 = `k'
    else if ( "`keytype'" == "int3" ) {
        local b = ceil(`j'^(1/3)) + 1
        gen long id1 = mod(`k', `b')
        gen long id2 = mod(floor(`k' / `b'), `b')
        gen long id3 = floor(`k' / (`b' * `b'))
    }
    else if ( "`keytype'" == "dbl1" )    gen double id1 = `k' + 0.25
    else if ( "`keytype'" == "str1" )    gen str12 id1 = "k" + string(`k', "%011.0f")
    else if ( "`keytype'" == "mixed" ) {
        gen str8 id1 = "s" + string(mod(`k', 1000), "%07.0f")
        gen long id2 = floor(`k' / 1000)
    }
    else if ( "`keytype'" == "strlong" ) gen str64 id1 = "prefix-common-to-every-key-" + string(`k', "%030.0f")
end

* ---------------------------------------------------------------------------
* Grids
* ---------------------------------------------------------------------------
if ( "`grid'" == "smoke" ) {
    bm_cell, n(100000) j(1000) keytype(int1) reps(1)
    bm_cell, n(100000) j(1000) keytype(mixed) reps(1)
    bm_cell, n(100000) j(100000) keytype(int1) mtype(1:1) reps(1)
}
if ( "`grid'" == "main" ) {
    * N x J, single integer key, random master order, using saved sorted
    foreach n in 100000 1000000 10000000 {
        foreach j in 100 100000 `=`n'/2' {
            if ( `j' > `n' ) continue
            local rr = cond(`n' >= 10000000, `reps', `reps' + 2)
            bm_cell, n(`n') j(`j') keytype(int1) reps(`rr')
        }
    }
}
if ( "`grid'" == "keys" ) {
    foreach kt in str1 mixed int3 strlong dbl1 {
        bm_cell, n(10000000) j(100000) keytype(`kt') reps(`reps')
    }
    bm_cell, n(10000000) j(5000000) keytype(str1) reps(`reps')
}
if ( "`grid'" == "state" ) {
    * master already sorted by key: native merge skips its master sort
    bm_cell, n(10000000) j(100000) keytype(int1) order(sorted) reps(`reps') tag(mastersorted)
    * using file not flagged as sorted: native loads, sorts and re-saves it
    bm_cell, n(10000000) j(5000000) keytype(int1) usingunsorted reps(`reps') tag(usingunsorted)
}
if ( "`grid'" == "wide" ) {
    bm_cell, n(10000000) j(100000) keytype(int1) nvars(20) reps(`reps') tag(wide20)
    bm_cell, n(10000000) j(100) keytype(int1) nvars(1) reps(`reps') tag(narrow1)
}
if ( "`grid'" == "one" ) {
    foreach n in 1000000 10000000 {
        bm_cell, n(`n') j(`n') keytype(int1) mtype(1:1) reps(`reps')
    }
    bm_cell, n(10000000) j(10000000) keytype(str1) mtype(1:1) reps(`reps')
}
