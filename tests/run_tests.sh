#!/bin/sh
# Differential correctness suites for hmerge. From the repo root:
#   make && sh tests/run_tests.sh [package-dir]     (default: repo root)
# Set STATA to your Stata executable if it is not Stata/MP in /Applications.
PROTO=${1:-.}
STATA=${STATA:-/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp}
ROOT=$(pwd)
mkdir -p logs
# a wrapper keeps the batch log name predictable (Stata names it after the
# last argument otherwise)
printf 'do tests/test_hmerge.do "%s"\n' "$PROTO" > tests/_run_main.do
"$STATA" -b do tests/_run_main.do; mv _run_main.log logs/test_hmerge.log
grep -E 'differential tests:' logs/test_hmerge.log
grep -E '^FAIL' logs/test_hmerge.log
printf 'do tests/test_fallbacks.do "%s"\n' "$PROTO" > tests/_run_fb.do
"$STATA" -b do tests/_run_fb.do; mv _run_fb.log logs/test_fallbacks.log
grep -E 'fallback tests:' logs/test_fallbacks.log | tail -1
cd tests/adversarial
for f in adv1 adv2 adv3; do
  printf 'global HM_DIR "%s/%s"\ndo %s.do\n' "$ROOT" "$PROTO" "$f" > _run_$f.do
  "$STATA" -b do _run_$f.do
  echo "adversarial $f: holds=$(grep -c '^HOLDS' _run_$f.log) differs=$(grep -c '^BUG?' _run_$f.log) $(grep '^BUG?' _run_$f.log | tr '\n' ' ')"
done
