#!/bin/bash
# ME-3 gate: mex_run('src.c', ...) — the full gcc-free pipeline returns the
# expected output arrays.
. "$(dirname "$0")/env.sh" || exit 1
cd "$CC_ROOT" || exit 1
M="$MATLAB"
S="$CC_REPO"
pass=0; fail=0

check() {
  local name="$1" mcall="$2" want="$3"
  $M -e "addpath('${S}/src'); r = mex_run('${S}/tests/programs/${name}.c', ${mcall}); for k=1:numel(r), v=r{k}; if ischar(v), fprintf('out%d=%s ', k, v); else, fprintf('out%d=[', k); fprintf('%g ', v(:)); fprintf('] ', k); end, end, fprintf('|DONE', 0);" > $TMPDIR/o.txt 2>&1
  if grep -q '^Error' $TMPDIR/o.txt; then
    echo "$name: ERROR $(grep -m1 -A1 ^Error $TMPDIR/o.txt | tail -1)"; fail=$((fail+1)); return
  fi
  local got
  got=$(grep -oE 'out[0-9]+=.*\|DONE' $TMPDIR/o.txt | head -1 | sed 's/|DONE$//')
  if [ "$got" = "$want" ]; then
    echo "$name: OK"; pass=$((pass+1))
  else
    echo "$name: DIFF got=[$got] want=[$want]"; fail=$((fail+1))
  fi
}

check mxdouble "[1 2 3; 4 5 6]"     "out1=[2 5 3 6 4 7 ] out2=[6 ] "
check mxscalar "21.5"               "out1=[43 ] "
check mxshape  "[1 2 3; 4 5 6]"     "out1=[6.0603e+06 ] "
check mxint    "int32([10 20 30])"  "out1=[110 120 130 ] "
check mxchar   "'hi'"               "out1=prefix:hi "
check mxmath   "[0.5 1 4 0.25]"     "out1=[1.18653 1.84147 1.2432 0.747404 ] "

echo "mex_run gate: $pass passed, $fail failed"
exit $fail
