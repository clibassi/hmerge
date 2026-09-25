#!/usr/bin/env python3
"""Compare native, baseline, and candidate in fresh Stata processes.
Usage: python3 bench/adaptive_benchmark.py BASELINE CANDIDATE ACS_PREPARED OUTPUT
OUTPUT holds generated fixtures, logs, canonical results, and timings.csv.
"""
import csv
import os
from pathlib import Path
import statistics
import subprocess
import sys

baseline, candidate, acs, output = map(lambda p: Path(p).resolve(), sys.argv[1:])
output.mkdir(parents=True, exist_ok=True)
stata = os.environ.get('STATA', '/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp')

def run(name, script):
    dofile = output / (name + '.do')
    logfile = output / (name + '.log')
    dofile.write_text('version 17\nset more off\nset varabbrev off\n' + script + '\ndisplay "BENCH_COMPLETE"\n')
    logfile.unlink(missing_ok=True)
    subprocess.run([stata, '-b', 'do', str(dofile)], cwd=output, check=True)
    text = logfile.read_text()
    if '\nBENCH_COMPLETE\n' not in text:
        raise RuntimeError(f'Incomplete Stata run: {logfile}')
    return text

# Deliberately small using tables protect the original direct/hash use cases.
run('prepare', f'''
clear
set obs 100000
generate long id = _n
generate double payload = id / 7
save "{output}/direct_using.dta", replace
generate str8 key = string(id, "%08.0f")
sort id key
save "{output}/hash_using.dta", replace
clear
set seed 48103
set obs 10000000
generate long id = ceil(runiform() * 100000)
generate long original_row = _n
save "{output}/direct_master.dta", replace
generate str8 key = string(id, "%08.0f")
save "{output}/hash_master.dta", replace
clear
set obs 1000000
generate long id = _n
generate byte key2 = 1
generate long original_row = _n
save "{output}/unmatched_master.dta", replace
keep if id <= 1000
drop original_row
generate double payload = id / 7
sort id key2
save "{output}/unmatched_using.dta", replace
''')
cases = [
    ('acs_ordered', acs/'march_master.dta', acs/'january.dta', '1:1', 'sample serial pernum', 'assert(match)', False),
    ('acs_shuffled', acs/'march_master_shuffled.dta', acs/'january.dta', '1:1', 'sample serial pernum', 'assert(match)', False),
    ('acs_late_inversion', acs/'march_master.dta', acs/'january.dta', '1:1', 'sample serial pernum', 'assert(match)', True),
    ('small_direct', output/'direct_master.dta', output/'direct_using.dta', 'm:1', 'id', 'assert(match)', False),
    ('small_hash', output/'hash_master.dta', output/'hash_using.dta', 'm:1', 'id key', 'assert(match)', False),
    ('mostly_unmatched', output/'unmatched_master.dta', output/'unmatched_using.dta', '1:1', 'id key2', '', False),
]
rows = []
for trial in range(4):
    implementations = ['native', 'baseline', 'candidate']
    if trial:
        shift = (trial-1) % 3
        implementations = implementations[shift:] + implementations[:shift]
    for implementation in implementations:
        package = baseline if implementation == 'baseline' else candidate
        command = 'merge' if implementation == 'native' else 'hmerge'
        script = f'adopath ++ "{package}"\n'
        for name, master, using, kind, keys, options, late in cases:
            script += f'use "{master}", clear\n'
            if late:
                script += 'generate long swap_order = _n\nreplace swap_order = _N in -2\nreplace swap_order = _N-1 in -1\nsort swap_order\ndrop swap_order\n'
            script += f'''timer clear 1
timer on 1
{command} {kind} {keys} using "{using}", nogenerate {options}
timer off 1
local path "native"
'''
            if implementation != 'native':
                script += 'local path "`r(path)\'"\nassert inlist("`path\'", "direct", "hash", "ordered")\n'
            script += f'timer list 1\ndisplay "BENCH_RESULT {name} {implementation} {trial} " %12.6f r(t1) " `path\'"\n'
            if name.startswith('acs'):
                script += 'assert _N == 16044345\n'
            else:
                script += 'assert original_row == _n\n' if implementation != 'native' else ''
            # Verify every value once, independently of the timed operation.
            if trial == 0:
                compare_keys = keys if name.startswith('acs') else 'original_row'
                script += f'sort {compare_keys}\n'
                reference = output / (name + '_native.dta')
                if implementation == 'native':
                    script += f'save "{reference}", replace\n'
                else:
                    script += f'cf _all using "{reference}", all\n'
        text = run(f'{implementation}_{trial}', script)
        for line in text.splitlines():
            if line.startswith('BENCH_RESULT '):
                _, case, impl, rep, seconds, path = line.split()
                rows.append(dict(case=case, implementation=impl, trial=int(rep), seconds=float(seconds), path=path))
        with (output/'timings.csv').open('w') as f:
            writer = csv.DictWriter(f, fieldnames=['case','implementation','trial','seconds','path'])
            writer.writeheader()
            writer.writerows(rows)
        print(f'Completed {implementation} trial {trial}', flush=True)
for case, *_ in cases:
    medians = {impl: statistics.median(r['seconds'] for r in rows if r['case']==case and r['implementation']==impl and r['trial']>0) for impl in implementations}
    print(case, medians, flush=True)
