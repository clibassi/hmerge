* adv3.do -- adversarial probes, batch 3
clear all
do "`c(pwd)'/adv_common.do"
tempfile M U Ul Ub Mb Mf

clear
input long id double x
1 .1
2 .2
end
save `M'

* ---- q1: value-label text with literal macro characters (set via Mata)
clear
input long id byte b
1 0
5 1
end
mata: st_vlmodify("bl", (0\1), ("costs \$S_OS here" \ "tick `" + "x" + "' quote"))
label values b bl
label list bl
save `Ul'
adv_run q1_label_literal_macros, master(`M') cmd(1:1 id using `Ul')

* ---- q2: using path with a space and no extension
capture mkdir "`c(pwd)'/dir with space"
use `Ul', clear
save "`c(pwd)'/dir with space/u file", replace
adv_run q2_path_space, master(`M') cmd(1:1 id using "`c(pwd)'/dir with space/u file")

* ---- q3: fallback path with a key variable named sort
clear
input long sort double y
1 10
1 11
end
save `Ub'
clear
input long sort double x
1 .1
end
save `Mb'
adv_run q3_fallback_key_named_sort, master(`Mb') cmd(1:m sort using `Ub')

* ---- q4: str# with embedded binary zero
clear
set obs 2
gen str3 k = cond(_n == 1, "a", "a" + char(0) + "b")
gen double x = _n
display length(k[2])
save `Mf'
clear
set obs 2
gen str3 k = cond(_n == 1, "a", "a" + char(0) + "c")
gen double y = _n * 10
save `U'
adv_run q4_binary_zero_keys, master(`Mf') cmd(1:1 k using `U')

* ---- q5: r() left behind
use `M', clear
merge 1:1 id using `Ul'
return list
use `M', clear
hmerge 1:1 id using `Ul'
return list

display as text _n "ADV3 suspected: $ADV_BUGS"
