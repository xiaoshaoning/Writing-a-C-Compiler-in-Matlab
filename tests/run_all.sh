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
# cannot be trusted to tell them apart.
#
#   VERDICT 0  passed      the harness reached its summary and counted 0 failures
#   VERDICT 1  failed      the harness reached its summary with failures
#   VERDICT 2  cut short   it never reached the summary: the process died
#
# These are verdicts about the run, not process exit codes. The evidence is the
# file run_tests.m writes as its very last act, run_tests.verdict ("<passed>
# <failed>"), which it also removes on startup - so the file existing means this run
# finished. It used to grep the summary line out of the log, which made the wording
# of a human-facing message a contract between two files: rewording it turned a
# green run into a reported failure.
#
# A cut-short run is retried once, because the death is random and always leaves 0
# failures; a second one is reported as cut short rather than retried forever.
set -u

. "$(dirname "$0")/env.sh" || exit 1
cd "$CC_ROOT" || exit 1

pass=0
fail=0
step() { printf '\n=== %s\n' "$1"; }

# suite_verdict - report 0, 1 or 2 for the main suite from run_tests.verdict.
# A missing or unreadable file is 2: the harness never got to write it.
suite_verdict() {
    [ -r run_tests.verdict ] || return 2
    read -r cc_passed cc_failed < run_tests.verdict || return 2
    case "$cc_failed" in
        ''|*[!0-9]*) return 2 ;;          # not two numbers: treat as unfinished
        0) return 0 ;;
        *) return 1 ;;
    esac
}

step "main suite: tests/run_tests.m"
# Name the runtime: this project's results are runtime-specific, and a log that does
# not say which engine produced it cannot be compared with another.
echo "runtime: $MATLAB"
if [ -r "$MATLAB" ]; then
    echo "         $(wc -c < "$MATLAB" | tr -d ' ') bytes, $(date -r "$MATLAB" '+%Y-%m-%d %H:%M' 2>/dev/null)"
fi
cc_log=${TMPDIR:-/tmp}/cc_run_tests.log
attempt=1
while : ; do
    "$MATLAB" tests/run_tests.m 2>&1 | tee "$cc_log"
    rc=${PIPESTATUS[0]}
    suite_verdict; verdict=$?
    [ "$verdict" -ne 2 ] && break
    if [ -r run_tests.verdict ]; then
        echo "           it was doing: $(cat run_tests.verdict)"
    fi
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
