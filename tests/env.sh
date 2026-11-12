#!/bin/bash
# env.sh - shared runtime and paths for the test gates. Source it, do not run it.
#
#   . tests/env.sh
#
# Sets (each honoured if already exported):
#   MATLAB    runtime to invoke. THIS IS THE ENGINE: matlab_in_rust's matlab-cli,
#             the runtime this project is developed and verified against. Real
#             MATLAB also works and is the authority when the two disagree; the C
#             clone (MATLAB_in_C) is the ORACLE for cross-checks, not the runtime.
#   CC_ENGINE the engine's binary, used when MATLAB is not exported
#   CC_ROOT   this repo, POSIX form      (shell: cd, redirections)
#   CC_REPO   this repo, Windows form    (MATLAB: addpath, fileread)
#   MX_REPO   compiler project, Windows form (its tests/mex corpus)
#   TMPDIR    scratch dir, POSIX form    (shell redirections, -o)
#   TMPWIN    scratch dir, Windows form  (MATLAB output paths)
#
# One place knows these paths; the gates used to each carry a copy, in two
# spellings of the same clone dir.
#
# The runtime is PROBED before it is handed to a gate. A stale or wrong build
# fails deep inside run_tests.m with "Unrecognized function or variable 'getenv'",
# which reads like a harness bug and cost an hour of the wrong debugging; a wrong
# runtime bought on the 1.86 MB clone in MATLAB_in_C's root, which nothing here
# should ever select by default.

_env_dir=$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)
CC_ROOT=$(cd "$_env_dir/.." && pwd)

case "$CC_ROOT" in
    /[a-zA-Z]/*)
        CC_REPO="$(printf '%s' "${CC_ROOT:1:1}" | tr 'a-z' 'A-Z'):${CC_ROOT:2}"
        ;;
    *)
        CC_REPO="$CC_ROOT"
        ;;
esac

# The engine is the runtime this project is developed and verified against; named
# here so the messages below can point at it even when MATLAB was exported.
: "${CC_ENGINE:=/d/Projects/codes/matlab_in_rust/dist/matlab-cli/matlab.exe}"

if [ -z "${MATLAB:-}" ]; then
    if [ -x "$CC_ENGINE" ]; then
        MATLAB=$CC_ENGINE
    elif command -v matlab >/dev/null 2>&1; then
        MATLAB=matlab
    else
        echo "env.sh: no runtime found; set MATLAB=/path/to/matlab(.exe)" >&2
        echo "        (the engine is $CC_ENGINE)" >&2
        [ "${BASH_SOURCE[0]}" != "$0" ] && return 1
        exit 1
    fi
fi

# an inherited $MATLAB may be a stale path (the clone is rebuilt in place):
# fail here, with a clear message, rather than letting each gate emit
# command-not-found noise
case "$MATLAB" in
    */*)
        if [ ! -x "$MATLAB" ]; then
            echo "env.sh: MATLAB is not executable: $MATLAB" >&2
            [ "${BASH_SOURCE[0]}" != "$0" ] && return 1
            exit 1
        fi
        ;;
esac

: "${MX_REPO:=D:/Projects/codes/MATLAB_in_C}"
: "${TMPDIR:=/d/tmp}"
: "${TMPWIN:=D:/tmp}"
mkdir -p "$TMPDIR" 2>/dev/null

# Probe once, outside run_tests: the runtime has to answer getenv() and run a
# script file, which is all the harness needs to start. Anything else is reported
# here, naming the path, instead of as a mid-run error about a missing function.
_env_probe=$TMPDIR/env_probe.m
printf "disp(numel(getenv('PATH')) > 0);%s" "$(printf '\n')" > "$_env_probe"
if ! "$MATLAB" "$_env_probe" 2>/dev/null | tr -d ' \r' | grep -qx 1; then
    echo "env.sh: this runtime cannot run the harness: $MATLAB" >&2
    echo "        (no getenv, or it will not run a script file)" >&2
    echo "        set MATLAB=/path/to/matlab(.exe); the engine is: $CC_ENGINE" >&2
    rm -f "$_env_probe"
    [ "${BASH_SOURCE[0]}" != "$0" ] && return 1
    exit 1
fi
rm -f "$_env_probe"

export MATLAB CC_ROOT CC_REPO MX_REPO TMPDIR TMPWIN CC_ENGINE
