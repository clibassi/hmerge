* adv1.do -- adversarial probes, batch 1
clear all
do "`c(pwd)'/adv_common.do"

tempfile M U Mdup Uord Umrg Ulab Ulabu Mover Uover Mempty Mstrl Ustr Ubad

* base using: id 5 3 1 (unsorted), payload y s b
clear
input long id double y str4 s byte b
5 50 "e" 1
3 30 "c" 0
1 10 "a" 1
end
label define bl 0 "no" 1 "yes"
label values b bl
save `U'

* master unique, sorted by id
clear
input long id double x
1 .1
2 .2
3 .3
end
save `M'

* master with duplicate id (1:1 error after build)
clear
input long id double x
1 .1
1 .11
2 .2
end
save `Mdup'

* P1: 1:1 master not unique -> state after error
adv_run p1_11_master_dups, master(`Mdup') cmd(1:1 id using `U')

* P2: using contains a _merge variable (common: saved after an earlier merge)
use `U', clear
gen byte _merge = 3
save `Umrg'
adv_run p2_using_has_merge, master(`M') cmd(1:1 id using `Umrg')
adv_run p2b_using_has_merge_nogen, master(`M') cmd(1:1 id using `Umrg', nogenerate)

* P3: generate() names a using payload variable
adv_run p3_gen_is_payload, master(`M') cmd(1:1 id using `U', generate(y))

* P4: keepusing order differs from using file order
adv_run p4_keepusing_order, master(`M') cmd(1:1 id using `U', keepusing(b s y))

* P5: keepusing with wildcard / abbreviation
adv_run p5_keepusing_wild, master(`M') cmd(1:1 id using `U', keepusing(y*))
adv_run p5b_keepusing_abbrev, master(`M') cmd(1:1 id using `U', keepusing(y s-b))

* P7: empty master that carries a sort flag; using unsorted
use `M', clear
drop in 1/3
save `Mempty'
use `Mempty', clear
display "empty master sortedby: `: sortedby'"
adv_run p7_empty_sorted_master, master(`Mempty') cmd(m:1 id using `U')

* P8: using var has an attached but undefined value label
use `U', clear
label values y undefined_lbl
save `Ubad'
adv_run p8_undefined_label, master(`M') cmd(1:1 id using `Ubad')

* P9: value-label text containing macro characters
use `U', clear
label define bl 0 `"cost $S_OS"' 1 `"say `"hi"' `x' ok"', replace
save `Ulab'
adv_run p9_label_macro_chars, master(`M') cmd(1:1 id using `Ulab')

* P10: master overlapping var is strL, using str4, using-only rows appended
clear
input long id double x str4 s
1 .1 "m1"
2 .2 "m2"
end
recast strL s
save `Mstrl'
adv_run p10_master_strL_overlap, master(`Mstrl') cmd(1:1 id using `U')

* P11: using label attached to overlapping var / key, and unattached labels
clear
input long id double y str4 s
5 50 "e"
3 30 "c"
end
label define idl 5 "five" 3 "three"
label values id idl
label define yl 50 "fifty"
label values y yl
label define orphan 1 "orphan"
save `Ulabu'
clear
input long id double y
1 1
3 3
end
save `Mover'
adv_run p11_labels_on_overlap_key, master(`Mover') cmd(1:1 id using `Ulabu')

* P12: keep()/assert() with codes 4/5 (legal in native, unreachable)
adv_run p12_keep_45, master(`M') cmd(1:1 id using `U', keep(1 3 4 5))
adv_run p12b_keep_mupdate, master(`M') cmd(1:1 id using `U', keep(match match_update))

* P13: generate() together with nogenerate (native warns and proceeds)
adv_run p13_gen_and_nogen, master(`M') cmd(1:1 id using `U', generate(mm) nogenerate)

* P14: nolabels spelled as in native syntax
adv_run p14_nolabels, master(`M') cmd(1:1 id using `U', nolabels)

* P15: 1:1 _n sequential merge
adv_run p15_seq, master(`M') cmd(1:1 _n using `U')

* P16: keepusing with duplicate names
adv_run p16_keepusing_dup, master(`M') cmd(1:1 id using `U', keepusing(y y))

display as text _n "ADV1 suspected: $ADV_BUGS"
