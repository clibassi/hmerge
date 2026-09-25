#!/bin/sh
# Run from the repository root. Optional argument selects another package dir.
# Require fresh, complete logs: Stata batch exit status alone is insufficient.
set -eu
PROTO=${1:-.}
STATA=${STATA:-/Applications/Stata/StataMP.app/Contents/MacOS/stata-mp}
ROOT=$(pwd)
case "$PROTO" in /*) ;; *) PROTO="$ROOT/$PROTO" ;; esac
mkdir -p logs

for suite in main fb adaptive; do
    case "$suite" in
        main) source=test_hmerge; expected='hmerge differential tests: 137 passed, 0 failed' ;;
        fb) source=test_fallbacks; expected='fallback tests: 10 passed, 0 failed' ;;
        adaptive) source=test_adaptive; expected='adaptive tests: 22 passed' ;;
    esac
    wrapper="tests/_run_${suite}.do"
    batchlog="_run_${suite}.log"
    result="logs/${source}.log"
    rm -f "$batchlog" "$result"
    printf 'do tests/%s.do "%s"\n' "$source" "$PROTO" > "$wrapper"
    "$STATA" -b do "$wrapper"
    test -f "$batchlog"
    mv "$batchlog" "$result"
    if ! grep -Fx "$expected" "$result"; then
        tail -30 "$result"
        exit 1
    fi
    if grep -E '^FAIL|^r\([0-9]+\);' "$result"; then exit 1; fi
done

cd tests/adversarial
for suite in adv1 adv2 adv3; do
    rm -f "_run_${suite}.log"
    printf 'global HM_DIR "%s"\ndo %s.do\n' "$PROTO" "$suite" > "_run_${suite}.do"
    "$STATA" -b do "_run_${suite}.do"
    result="_run_${suite}.log"
    test -f "$result"
    holds=$(grep -c '^HOLDS' "$result" || true)
    differs=$(grep -c '^BUG?' "$result" || true)
    case "$suite" in
        adv1)
            test "$holds" -eq 17
            test "$differs" -eq 1
            grep -Eq '^BUG\? p13_gen_and_nogen[[:space:]]*$' "$result"
            grep -q '^ADV1 suspected:' "$result" ;;
        adv2) test "$holds" -eq 22; test "$differs" -eq 0; grep -q '^ADV2 suspected:' "$result" ;;
        adv3) test "$holds" -eq 4; test "$differs" -eq 0; grep -q '^ADV3 suspected:' "$result" ;;
    esac
    if grep -E '^r\([0-9]+\);' "$result"; then exit 1; fi
    echo "adversarial $suite: holds=$holds differs=$differs"
done
echo 'All suites completed; the sole allowed discrepancy is generate()+nogenerate.'
