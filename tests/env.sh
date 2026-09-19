#!/bin/bash
# env.sh - shared runtime and paths for the test gates. Source it, do not run it.
#
#   . tests/env.sh
#
# Sets (each honoured if already exported):
#   MATLAB   runtime to invoke (default: matlab on PATH, else the clone build)
#   CC_ROOT  this repo, POSIX form      (shell: cd, redirections)
#   CC_REPO  this repo, Windows form    (MATLAB: addpath, fileread)
#   MX_REPO  compiler project, Windows form (its tests/mex corpus)
#   TMPDIR   scratch dir, POSIX form    (shell redirections, -o)
#   TMPWIN   scratch dir, Windows form  (MATLAB output paths)
#
# One place knows these paths; the gates used to each carry a copy, in two
# spellings of the same clone dir.

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

if [ -z "${MATLAB:-}" ]; then
    if command -v matlab >/dev/null 2>&1; then
        MATLAB=matlab
    elif [ -x /d/Projects/codes/MATLAB_in_C/matlab.exe ]; then
        MATLAB=/d/Projects/codes/MATLAB_in_C/matlab.exe
    else
        echo "env.sh: no MATLAB runtime found; set MATLAB=/path/to/matlab(.exe)" >&2
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

export MATLAB CC_ROOT CC_REPO MX_REPO TMPDIR TMPWIN
