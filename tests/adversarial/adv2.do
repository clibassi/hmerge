* adv2.do -- adversarial probes, batch 2 (types, keys, labels, options)
clear all
do "`c(pwd)'/adv_common.do"

tempfile M U Mt Ut Mk Uk Mm Um Ms Us Mo Uo Mz Uz Ml Mb Ub Mw Uw

* ---- t1: overlapping-variable type promotion with using-only rows
clear
input long id byte v1 int v2 long v3 float v4 long v5 int v6 str3 v7 float v8
1 1 1 1 1 1 1 "a" 1.5
2 2 2 2 2 2 2 "b" 2.5
end
format v7 %-3s
format v4 %5.2f
save `Mt'
clear
input long id int v1 float v2 float v3 long v4 double v5 byte v6 str10 v7 double v8
1 100 1.5 16777217 16777217 3.25 7 "zzzzzzzzzz" 1.1
9 300 2.5 16777217 16777217 3.25 7 "yyyyyyyyyy" 1.1
end
format v7 %10s
format v2 %6.1f
save `Ut'
adv_run t1_overlap_promotion, master(`Mt') cmd(1:1 id using `Ut')
adv_run t1b_overlap_promotion_match, master(`Mt') cmd(1:1 id using `Ut', keep(match))

* ---- t2: key promotion long master / float using, large integers
clear
input long id double x
16777217 1
16777216 2
end
save `Mk'
clear
input float id double y
16777216 20
end
save `Uk'
adv_run t2_key_long_float, master(`Mk') cmd(1:1 id using `Uk')
adv_run t2b_key_float_long, master(`Uk') cmd(1:1 id using `Mk')

* ---- t3: missing and extended-missing keys across storage types
clear
input double id double x
. 1
.a 2
0 3
1.1 4
end
save `Mm'
clear
input float id byte y
. 10
.a 20
.b 30
1.1 40
end
save `Um'
adv_run t3_missing_keys_dbl_flt, master(`Mm') cmd(1:1 id using `Um')
adv_run t3b_missing_keys_flt_dbl, master(`Um') cmd(1:1 id using `Mm')

* ---- t4: string keys: trailing spaces, width mismatch, unicode
clear
input str3 k double x
"a" 1
"a " 2
"é" 3
"" 4
end
save `Ms'
clear
input str10 k double y
"a" 10
"a  " 20
"é" 30
"" 40
"zzzzzzzzzz" 50
end
save `Us'
adv_run t4_strkeys, master(`Ms') cmd(1:1 k using `Us')
adv_run t4b_strkeys_rev, master(`Us') cmd(1:1 k using `Ms')

* ---- t5: _merge value label already defined differently in master
use `Mt', clear
label define _merge 1 "mine" 3 "both"
save `Ml'
adv_run t5_merge_label_predefined, master(`Ml') cmd(1:1 id using `Ut')

* ---- t6: multi-key, mixed str/num, key order reversed vs using
clear
input str2 a long b double x
"x" 1 1
"y" 2 2
end
save `Mb'
clear
input long b str4 a double y
2 "y" 20
3 "z" 30
end
save `Ub'
adv_run t6_multikey_order, master(`Mb') cmd(1:1 b a using `Ub')
adv_run t6b_multikey_order2, master(`Mb') cmd(1:1 a b using `Ub')

* ---- t7: keep()/assert() spellings
use `Mt', clear
adv_run t7a_keep_ma, master(`Mt') cmd(1:1 id using `Ut', keep(ma))
adv_run t7b_keep_u, master(`Mt') cmd(1:1 id using `Ut', keep(u))
adv_run t7c_keep_mast_mat, master(`Mt') cmd(1:1 id using `Ut', keep(mast mat))
adv_run t7d_assert_keep, master(`Mt') cmd(1:1 id using `Ut', assert(match) keep(match))
adv_run t7e_keep_matched, master(`Mt') cmd(1:1 id using `Ut', keep(matched))
adv_run t7f_keep_M, master(`Mt') cmd(1:1 id using `Ut', keep(Match))

* ---- t8: overlapping var str vs numeric type clash
clear
input long id str3 v1
1 "a"
end
save `Mo'
adv_run t8_overlap_type_clash, master(`Mo') cmd(1:1 id using `Ut')

* ---- t9: wide string keys (str2045) and payload
clear
set obs 3
gen long n = _n
gen str2045 k = n * "x" + 2040 * "y"
gen double x = n
save `Mw'
clear
set obs 4
gen long n = _n + 1
gen str2045 k = n * "x" + 2040 * "y"
gen str2045 p = 2045 * "p"
drop n
save `Uw'
adv_run t9_str2045, master(`Mw') cmd(1:1 k using `Uw')

* ---- t10: using with only key vars; empty using with sort flag
clear
input long id
1
7
end
save `Uz'
adv_run t10_using_keys_only, master(`Mt') cmd(1:1 id using `Uz')

* ---- t11: master sorted by key, keep(match master) (flag must stay true)
adv_run t11_sorted_keepmm, master(`Mt') cmd(m:1 id using `Ut', keep(match master)) setup(sort id)
adv_run t11b_sorted_byx, master(`Mt') cmd(m:1 id using `Ut', keep(match master)) setup(sort v8)

display as text _n "ADV2 suspected: $ADV_BUGS"
