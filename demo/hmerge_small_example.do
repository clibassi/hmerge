*! file: hmerge_small_example.do
*! purpose: tiny side-by-side example of merge vs hmerge (same keys as the explainer figure)
*! author: CJ Libassi (demo written with Claude)
*! created: 2026-09-24
version 17.0
clear all
set more off
set varabbrev off

global project_dir "`c(pwd)'"
capture confirm file "${project_dir}/hmerge.ado"
if ( _rc ) {
    global project_dir "`c(pwd)'/.."
}
adopath ++ "${project_dir}"

* using: one row per key
clear
input long id double y
2 20
4 40
7 70
9 90
end
tempfile using_data
save "`using_data'"

* master: six rows, in the order they were collected
clear
input long id double x
7 1
2 2
9 3
2 4
4 5
7 6
end
tempfile master_data
save "`master_data'"

* native merge: master rows come back in key order
use "`master_data'", clear
merge m:1 id using "`using_data'", nogenerate noreport
list, noobs sep(0)

* hmerge: same rows and values, master rows stay where they were
use "`master_data'", clear
hmerge m:1 id using "`using_data'", nogenerate noreport
list, noobs sep(0)
