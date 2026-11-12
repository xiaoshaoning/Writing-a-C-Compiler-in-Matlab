#!/bin/bash
# run_all.sh - one-command verification for the Writing-a-C project.
#
#   bash tests/run_all.sh
#
# Runs the main suite (run_tests.m) followed by the four MEX/double gates.
# The runtime and paths come from tests/env.sh, so $MATLAB (or the usual
# clone build) and the repo's own location are resolved in one place.
# Exits non-zero if any part fails, and says WHICH: the main suite has three
# outcomes, not two. This host kills run_tests.m at a random point (its header
# records deaths at 125..773 of ~817 checks, always with 0 failures), and a killed
# run returns the same non-zero code a FAILING run returns - so the exit code
# cannot be trusted to tell them apart. The summary line can: it is printed once,
# last, by the harness itself.
#
#   0 passed                      summary says 0 failed
#   1 failed                      summary present, failures counted
#   2 cut short                   no summary at all: the process died
#
# A cut-short run is retried once, because the death is random and always leaves 0
# failures; a second one is reported as cut short rather than retried forever.
set -u

. "$(dirname "$0")/env.sh" || exit 1
cd "$CC_ROOT" || exit 1

pass=0
fail=0
step() { printf '\n=== %s\n' "$1"; }

# suite_verdict LOGPATH - classify a finished run from its log, not from its exit
# code. Prints 0, 1 or 2 as described above; leaves the log behind for the report.
suite_verdict() {
    if ! grep -q '^run_tests: [0-9]* tests,' "$1"; then
        return 2
    fi
    if grep -q '^run_tests: .* 0 failed$' "$1"; then
        return 0
    fi
    return 1
}

step "main suite: tests/run_tests.m"
cc_log=${TMPDIR:-/tmp}/cc_run_tests.log
attempt=1
while : ; do
    "$MATLAB" tests/run_tests.m 2>&1 | tee "$cc_log"
    rc=${PIPESTATUS[0]}
    suite_verdict "$cc_log"; verdict=$?
    [ "$verdict" -ne 2 ] && break
    if [ "$attempt" -eq 1 ]; then
        echo "run_tests: CUT SHORT - no summary line, so the process died (exit $rc)."
        echo "           retrying once: the death is random, always with 0 failures"
        attempt=2
    else
        break
    fi
done
case "$verdict" in
    0) pass=$((pass + 1)) ;;
    1) echo "run_tests: FAILED (log: $cc_log)"; fail=$((fail + 1)) ;;
    *) echo "run_tests: CUT SHORT twice - the host kills it at a random point;"
       echo "           verify a section instead (CC_SECTIONS=... , see run_tests.m)"
       echo "           log: $cc_log"
       fail=$((fail + 1)) ;;
esac

for g in run_double_regression.sh run_mx_smoke.sh run_mex_run_smoke.sh run_mex_run_gcc.sh; do
    step "$g"
    if bash "tests/$g"; then
        pass=$((pass + 1))
    else
        echo "$g: FAILED"
        fail=$((fail + 1))
    fi
done

printf '\nrun_all: %d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
