#!/bin/bash
# run_all.sh - one-command verification for the Writing-a-C project.
#
#   bash tests/run_all.sh
#
# Runs the main suite (run_tests.m) followed by the four MEX/double gates.
# The runtime and paths come from tests/env.sh, so $MATLAB (or the usual
# clone build) and the repo's own location are resolved in one place.
# Exits non-zero if any part fails.
set -u

. "$(dirname "$0")/env.sh" || exit 1
cd "$CC_ROOT" || exit 1

pass=0
fail=0
step() { printf '\n=== %s\n' "$1"; }

step "main suite: tests/run_tests.m"
if "$MATLAB" tests/run_tests.m; then
    pass=$((pass + 1))
else
    echo "run_tests: FAILED"
    fail=$((fail + 1))
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
