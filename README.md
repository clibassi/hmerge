# hmerge

`hmerge` is a prototype Stata command for `merge m:1` and `merge 1:1`. It takes the same
syntax as `merge` and gives the same results, but it never sorts the master data. It
uses sequential matching when both inputs are ordered, or indexes the using keys
and looks up each master observation where it already sits.

```stata
net install hmerge, from("https://raw.githubusercontent.com/clibassi/hmerge/main/")
help hmerge
```

A compiled plugin is included for **Apple silicon Macs only**. On other platforms `hmerge`
prints a note and runs `merge` instead. Requires Stata 17 or later; tested only with
Stata/MP 17.

## When it is faster, and when it isn't

Version 0.3.0 adds an adaptive ordered join for physically ordered inputs, even when
Stata's sort flag is empty. See [the ACS benchmark](bench/results/adaptive.md) for
comparisons with native merge and 0.2.3, including shuffled and late-disorder cases.

The original benchmarks below predate the ordered path and use Stata/MP 17.0 (2-core licence), MacBook Pro (Apple M5 Pro, 24 GB), 10 million master
observations, one integer key, master in random order. Seconds, median of 3 runs with a
warm file cache, end to end:

| using obs | merge | hmerge | hmerge, sort | ratio |
|---|---|---|---|---|
| 100 | 1.924 | 0.231 | 1.929 | 8.3x |
| 100,000 | 2.015 | 0.259 | 2.028 | 7.8x |
| 5,000,000 | 2.299 | 1.204 | 3.370 | 1.9x |

These gains depend on the workload and whether you need the result sorted:

| case (J = 100,000) | merge | hmerge | ratio |
|---|---|---|---|
| panel sorted by person-year that has to keep that order | 4.373 | 0.272 | 16.1x |
| master already sorted by the key | 0.283 | 0.239 | 1.2x |
| merge, then `bysort` on the key right after | 2.138 | 2.270 | 0.94x |

With 100,000 using observations the speedup is 5.4x to 13.6x across key types (single
integer, double, string, long string, mixed string and numeric, three integers). On the
public [db-benchmark join task](https://github.com/duckdblabs/db-benchmark), `hmerge` is 5.2x to
11.4x faster than `merge` on the m:1 questions and 2.6x on the 1:1 question, with identical
output. See [`bench/results/evidence.md`](bench/results/evidence.md) and
[`bench/dbbench/`](bench/dbbench/).

## What differs from `merge`

- Master observations keep their original order. After `merge m:1` they are in key order,
  although Stata's sort indicator is cleared. Using-only observations are appended in key
  order by both commands. Option `sort` gives key order throughout.
- Variable notes are not copied. `r()` holds `r(path)`.
- `1:m`, `m:m`, `1:1 _n`, `update`, `replace`, `force`, strL variables, a using file on the web,
  data near the plugin interface's 2,147,483,647-observation limit, and platforms without a
  plugin are all handed to `merge`, with a note.

Everything else should match `merge` exactly: values, `_merge`, variable order, storage
types (including `merge`'s promotions), formats, labels, error messages and codes, and the
data left after an error. Please open an issue if you find a difference.

## Correctness

```sh
make                      # builds hmerge.plugin (macOS, clang)
sh tests/run_tests.sh     # set STATA=/path/to/stata if needed
```

- **`tests/test_hmerge.do`** runs 137 cases against native `merge` on identical inputs. Every
  successful case must show that the plugin actually ran, via `r(path)`. A mutation check
  confirmed the suite fails when the ordering logic or the plugin detection is broken.
- **`tests/test_adaptive.do`** adds 22 comparisons covering ordered keys, late master
  inversions, uniqueness across the transition, empty inputs, missing and string keys,
  filtering, and omitted merge-code writes.
- **`tests/test_fallbacks.do`** covers argument errors and the hand-offs to `merge` (10 cases).
- **`tests/adversarial/`** holds probes written by an independent reviewer. 43 of 44 match
  `merge` exactly. The exception is the error code when `generate()` and `nogenerate` are
  combined.
- The suite also passes with the plugin built under UndefinedBehaviorSanitizer (`make ubsan`).

## Design

The using file is read into a temporary frame with Stata's own reader. The plugin then
works in four steps:

1. It copies keys and payload into memory, checking physical key order as it reads.
   One integer key over a compact range retains the direct lookup table. Otherwise,
   ordered using keys select sequential matching; unordered using keys select hashing.
   Hash matches are confirmed against the full key.
2. A match step reads the master keys and writes nothing, so all validation errors leave the
   data untouched. A descending master key triggers a hash-table build and continues
   from that observation without replaying the prefix. Master order is preserved.
   Unmatched master keys get a growing uniqueness set only when needed for `1:1`.
3. A write step fills the new variables and `_merge`. With `nogenerate` and no `keep()`,
   the temporary merge-code column is omitted; assertions and reports still use counts.
4. An append step adds using-only observations in key order, skipping their sort when
   using-key order was already verified.

`r(path)` reports `direct`, `ordered`, or `hash`; an ordered join that switches to
hashing reports `hash`. The sort flag is not used to choose the algorithm.

Plugin memory persists between the calls. This works in current Stata but the Stata plugin
interface doesn't document it, so every call is checked against a token and a mismatch stops
with an error.

The direct lookup table for integer keys follows the approach used in
[gtools](https://github.com/mcaceresb/stata-gtools) by Mauricio Cáceres Bravo.

## Security

`hmerge` reads data, variable names and labels from a using file that may come from someone
else. Before release it had an independent security review. Label and format text is copied
through Mata (`st_vlload`, `st_vlmodify`, `st_varlabel`, `st_varformat`) and is never expanded
or executed as Stata code; the test suite includes injection payloads. The hash table uses a
random seed on every call, so crafted keys cannot force a slow build. String lengths are
checked before they are read. The one remaining assumption: variable and value-label
*names* are used in Stata commands, which is safe because Stata only accepts valid names
when it reads a .dta file.

## How this was written

`hmerge` was written with a lot of help from an AI coding assistant (Anthropic's Claude):
the C plugin, the ado-file, the tests, and the benchmarks. That is a large part of why the
test suite compares every result against native `merge`, including after errors, and why
it was checked by an independent adversarial review and a mutation check.

## Building for other platforms

Linux: `gcc -O3 -shared -fPIC -DSYSTEM=OPUNIX -o hmerge.plugin hmerge.c stplugin.c`.
Windows: mingw-w64 with `-shared`. Neither build is tested yet. Reports and pull requests
are welcome.

## Licence

MIT (see `LICENSE`). `stplugin.c` and `stplugin.h` are StataCorp's plugin interface files.
