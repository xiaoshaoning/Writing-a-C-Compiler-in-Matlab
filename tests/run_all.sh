#!/bin/bash
# run_all.sh - one-command verification for the Writing-a-C project.
#
#   bash tests/run_all.sh
#
# Runs the main suite (run_tests.m) followed by the four MEX/double gates.
# The runtime comes from $MATLAB when set, else matlab on PATH, else the
# usual clone build. The repo path is derived from this script's location
# and passed to the gates (which no longer hardcode it). Exits non-zero if
# any part fails.
set -u

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/.." && pwd)

if [ -n "${MATLAB:-}" ]; then
    M="$MATLAB"
elif command -v matlab >/dev/null 2>&1; then
    M=matlab
elif [ -x /d/Projects/codes/MATLAB_in_C/matlab.exe ]; then
    M=/d/Projects/codes/MATLAB_in_C/matlab.exe
else
    echo "run_all: no MATLAB runtime found; set MATLAB=/path/to/matlab(.exe)" >&2
    exit 1
fi

# the gates feed paths to MATLAB code, so hand them the Windows form
case "$repo" in
    /[a-zA-Z]/*)
        drv=$(printf '%s' "${repo:1:1}" | tr 'a-z' 'A-Z')
        winrepo="${drv}:${repo:2}"
        ;;
    *) winrepo="$repo" ;;
esac
export MATLAB="$M"
export CC_REPO="$winrepo"

cd "$repo" || exit 1
pass=0
fail=0
step() { printf '\n=== %s\n' "$1"; }

step "main suite: tests/run_tests.m"
if "$M" tests/run_tests.m; then
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
