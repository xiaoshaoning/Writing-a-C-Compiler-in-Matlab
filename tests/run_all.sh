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

# CC_RUNTIMES=<a>;<b> runs the suite once per runtime and compares the FAILURE SETS - the
# comparison that found every defect here, automated. See the differential block below.
# $MATLAB is still the single runtime when CC_RUNTIMES is unset.

# suite_verdict - report 0, 1 or 2 for the main suite from run_tests.verdict.
# A missing or unreadable file is 2: the harness never got to write it.
suite_verdict() {
    [ -r run_tests.verdict ] || return 2
    read -r cc_passed cc_failed < run_tests.verdict || return 2
    cc_failed=${cc_failed%$'\r'}      # written in text mode: "163 0\r\n" otherwise
    cc_passed=${cc_passed%$'\r'}
    case "$cc_failed" in
        ''|*[!0-9]*) return 2 ;;          # not two numbers: treat as unfinished
        0) return 0 ;;
        *) return 1 ;;
    esac
}

# run_suite_once <runtime> <log>
# One runtime through the suite, with the retry-once-on-cut-short logic. Leaves
# run_tests.verdict for the caller and returns the verdict: 0 pass, 1 fail, 2 cut short.
run_suite_once() {
    rs_rt=$1
    rs_log=$2
    rs_attempt=1
    while : ; do
        "$rs_rt" tests/run_tests.m 2>&1 | tee "$rs_log"
        rs_rc=${PIPESTATUS[0]}
        suite_verdict; rs_v=$?
        [ "$rs_v" -ne 2 ] && return "$rs_v"
        if [ -r run_tests.verdict ]; then
            echo "           it was doing: $(cat run_tests.verdict)"
        fi
        if [ "$rs_attempt" -eq 1 ]; then
            echo "run_tests: CUT SHORT - no summary line, so the process died (exit $rs_rc)."
            echo "           retrying once: the death is random, always with 0 failures"
            rs_attempt=2
        else
            return 2
        fi
    done
}

# runtime_line <runtime> - the runtime and its size/date. A log that does not say which
# runtime produced it cannot be compared with another, which is the point of CC_RUNTIMES.
runtime_line() {
    echo "runtime: $1"
    if [ -r "$1" ]; then
        echo "         $(wc -c < "$1" | tr -d ' ') bytes, $(date -r "$1" '+%Y-%m-%d %H:%M' 2>/dev/null)"
    fi
}

if [ -z "${CC_RUNTIMES:-}" ]; then
step "main suite: tests/run_tests.m"
runtime_line "$MATLAB"
cc_log=${TMPDIR:-/tmp}/cc_run_tests.log
run_suite_once "$MATLAB" "$cc_log"; verdict=$?
case "$verdict" in
    0) pass=$((pass + 1)) ;;
    1) echo "run_tests: FAILED (log: $cc_log)"; fail=$((fail + 1)) ;;
    *) echo "run_tests: CUT SHORT twice - the host kills it at a random point;"
       echo "           verify a section instead (CC_SECTIONS=... , see run_tests.m)"
       echo "           log: $cc_log"
       fail=$((fail + 1)) ;;
esac

fi   # end of the single-runtime branch

# The differential run (2026-11-05). Every defect this project has found came from one
# runtime disagreeing with another, and that comparison was always done by hand. Set
# CC_RUNTIMES to two or more runtimes separated by ';' (a ';' because Windows paths contain
# ':') and each gets the suite, after which the FAILURE SETS are compared.
#
# Failure sets, not counts: two runtimes can each fail one test, both report "1 failed", and
# be failing different tests. On disagreement the differences are printed and the exit status
# is 1. A cut-short runtime is excluded and said so, because a partial run disagrees for a
# reason that is not portability.
if [ -n "${CC_RUNTIMES:-}" ]; then
    step "differential run: the suite on each runtime, then diff the failures"
    IFS=';' read -r -a cc_rts <<< "$CC_RUNTIMES"
    cc_n=${#cc_rts[@]}
    if [ "$cc_n" -lt 2 ]; then
        echo "CC_RUNTIMES needs at least two runtimes separated by ';'" >&2
        echo "  e.g. CC_RUNTIMES='/a/matlab.exe;/b/matlab.exe'" >&2
        exit 2
    fi
    cc_div=0
    cc_usable=0
    cc_i=0
    cc_base=${TMPDIR:-/tmp}/cc_diff_base.fail
    : > "$cc_base"
    for cc_rt in "${cc_rts[@]}"; do
        cc_i=$((cc_i + 1))
        step "runtime $cc_i/$cc_n"
        runtime_line "$cc_rt"
        cc_flog=${TMPDIR:-/tmp}/cc_diff_$cc_i.log
        cc_fset=${TMPDIR:-/tmp}/cc_diff_$cc_i.fail
        run_suite_once "$cc_rt" "$cc_flog"; cc_v=$?
        grep '^FAIL' "$cc_flog" | sort > "$cc_fset" 2>/dev/null || : > "$cc_fset"
        cc_fails=$(wc -l < "$cc_fset" | tr -d ' ')
        cc_ran=$(grep -c '^PASS' "$cc_flog" 2>/dev/null)
        cc_ran=$((cc_ran + cc_fails))
        echo "         $cc_fails failure(s) of $cc_ran check(s)"
        if [ "$cc_v" -eq 2 ]; then
            echo "         CUT SHORT: excluded from the comparison"
            continue
        fi
        cc_usable=$((cc_usable + 1))
        if [ "$cc_usable" -eq 1 ]; then
            cp "$cc_fset" "$cc_base"
            cc_ran_base=$cc_ran
        else
            # The COUNT matters as much as the set. A runtime that skips checks - the C
            # clone cannot run gcc-dependent ones, because its system() captures no output -
            # has an empty failure set too, and comparing sets alone would call that
            # agreement. Two runtimes are only comparable if they ran the same number of
            # checks.
            if [ "$cc_ran" -ne "$cc_ran_base" ]; then
                echo "--- $cc_ran checks here against $cc_ran_base: NOT comparable"
                echo "         (skipped checks have no failure to diff)"
                cc_div=$((cc_div + 1))
            fi
            if ! diff -q "$cc_base" "$cc_fset" >/dev/null 2>&1; then
                echo "--- portability divergence against the first runtime:"
                diff "$cc_base" "$cc_fset" | sed 's/^/         /'
                cc_div=$((cc_div + 1))
            fi
        fi
    done
    if [ "$cc_usable" -lt 2 ]; then
        echo "differential run: fewer than two runtimes completed; nothing was compared" >&2
        exit 2
    fi
    if [ "$cc_div" -ne 0 ]; then
        echo "differential run: DIVERGENCE - $cc_div runtime(s) disagree with the first"
        fail=$((fail + cc_div))
    else
        echo "differential run: $cc_usable runtime(s) agree on the failure set"
    fi
fi

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
