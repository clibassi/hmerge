# Adaptive join measurements — September 25, 2026

Version 0.3.0 resolves the ordered ACS regression on this machine. This is a workload-specific result, not a claim that hmerge always beats native merge.

| Workload | Native merge | hmerge 0.2.3 | hmerge 0.3.0 |
|---|---:|---:|---:|
| ACS original physical order | 2.168 | 3.456 | 1.196 |
| ACS shuffled master | 6.127 | 4.127 | 4.109 |
| ACS final two master rows swapped | 3.460 | 3.313 | 1.464 |
| 10M master / 100K using, single integer key | 2.105 | 0.208 | 0.192 |
| 10M master / 100K using, numeric + string keys | 2.402 | 0.357 | 0.339 |
| 1M master / 1K using, 99.9% master-only | 0.038 | 0.053 | 0.052 |

Seconds, median of three measured runs after one warm-up for each implementation.
On original ACS order, 0.3.0 is 2.89x as fast as 0.2.3 and 1.81x as fast as native.
The shuffled comparison is effectively unchanged from 0.2.3 (4.109 versus 4.127 seconds).
Small lookup-table cases retain their advantage. Native remains faster on the mostly-unmatched synthetic example, albeit by 14 milliseconds.

## Method and scope

- Same Apple M5 Pro / 24 GB machine, Stata/MP 17.0, two-core license. Release plugins built with the same Makefile (`clang -O3`); baseline is commit `12266f69b362cc283499913c05e2c751114ff93b`.
- Each implementation/trial runs in a fresh Stata process. Measured implementation order rotates native/baseline/candidate, baseline/candidate/native, candidate/native/baseline. Case order stays fixed. This approximates warm-cache operation, not cold-disk performance.
- Timers include the merge command, using-file read, validation, and output construction. Master loading, shuffling, sorting results for comparison, and saves are outside timers. All use `nogenerate`; all except the mostly-unmatched fixture use `assert(match)`.
- The ACS fixtures have 16,044,345 observations on both sides and keys `sample serial pernum`. Original physical key order is preserved; the original prepared files have blank sort indicators. The shuffled fixture uses the same rows with seed 48103. The late-inversion fixture swaps only the last two master rows, outside the timer.
- Synthetic small lookup cases use 10,000,000 randomly keyed master observations and 100,000 using observations, one double payload, and an original-row marker. The mixed-key fixture adds an eight-character string. The 1,000,000-row uniqueness-growth case has two numeric keys and 1,000 matched records; all other master keys are unique and unmatched.
- Each warm-up compares every output value against native after aligning rows. All comparisons passed. Synthetic hmerge runs also assert preservation of original master order. The separate regression suite tests variable order/types and error outcomes.
- The late-inversion candidate reports `hash`, demonstrating the switch occurred; original ACS reports `ordered`. Direct-address keys retain `direct`. A late switch builds the hash but does not replay the already matched prefix.
- The earlier two-run component probes suggested benefit from lazy allocation/omitted code writes, but the balanced shuffled result does not establish a measurable gain there. Do not extrapolate those probes.
- Three repetitions on one machine are limited evidence. These cases do not cover every width, cardinality, string distribution, unmatched proportion, or Stata version. No workload-prevalence percentage has been estimated.

## Changes and correctness

The using load verifies order as it reads. Compact integer keys keep direct addressing; other ordered using keys start a sequential matcher. A descending master key triggers hashing while retaining match and uniqueness state. No separate full sorting scan or native dispatch is required. Unmatched-master uniqueness storage is allocated lazily and grows, and `nogenerate` without `keep()` omits the temporary merge-code column. Counts still support assertions and reporting.

Validation: 137 existing differential cases, 10 fallback cases, 22 adaptive cases, and 43 adversarial cases pass in release and trap-mode UndefinedBehaviorSanitizer builds. The pre-existing `generate()` plus `nogenerate` error-code difference is still the sole expected adversarial discrepancy (43/44). The runner rejects incomplete/stale logs, including a deliberately failed Stata launch. A fresh read-only review by GPT-5.6-Sol cleared the implementation after fixes.

## Reproduce

Build baseline and candidate in separate folders. Use the ACS example to create the two prepared files and its shuffled benchmark to create `march_master_shuffled.dta`. Then run:

```sh
python3 bench/adaptive_benchmark.py /path/to/baseline /path/to/candidate /path/to/acs/data/prepared /path/to/new/output
```

`STATA` can override the Stata executable. Output includes generated Stata scripts, logs, canonical comparison datasets, and timings. Allow several GB of local space. ACS data are local inputs, not distributed with the package. See [raw timings](adaptive_timings.csv); trial 0 is the excluded warm-up. The harness is [adaptive_benchmark.py](../adaptive_benchmark.py).
