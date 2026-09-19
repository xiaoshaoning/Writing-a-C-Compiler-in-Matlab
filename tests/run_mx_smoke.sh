#!/bin/bash
# ME-2 smoke: assemble mx_preamble()+<corpus>.c, compile with cc_int,
# run the sim, compare stdout + exit code with expected values.
. "$(dirname "$0")/env.sh" || exit 1
cd "$CC_ROOT" || exit 1
M="$MATLAB"
S="$CC_REPO"

pass=0; fail=0

run_one() {
  local c="$1" expected="$2"
  $M -e "addpath('${S}/src'); pd = char(mx_preamble()); src = fileread('${S}/tests/programs/${c}.c'); fid = fopen('${S}/tests/tmp_mx_${c}.c','w'); fprintf(fid, '%s', pd); fprintf(fid, '%s', src); fclose(fid);" > $TMPDIR/asm.txt 2>&1
  $M -e "addpath('${S}/src'); cc_int('${S}/tests/tmp_mx_${c}.c', '${S}/tests/tmp_mx_${c}.s'); x = x86sim('${S}/tests/tmp_mx_${c}.s'); fprintf('SIM_EXIT=%d', x);" > $TMPDIR/o.txt 2>&1
  if grep -q '^Error' $TMPDIR/o.txt; then
    echo "$c: ERROR: $(grep -m1 -A1 ^Error $TMPDIR/o.txt | tail -1)"
    fail=$((fail+1)); return
  fi
  local sl se
  sl=$(sed 's/SIM_EXIT=.*//' $TMPDIR/o.txt | tr -d '\r' | grep -v '^$')
  se=$(grep -oE "SIM_EXIT=[0-9-]+" $TMPDIR/o.txt | cut -d= -f2)
  if [ "$(printf '%s\n' "$sl" | tr -d '\r')" = "$(printf '%s\n' "$expected" | tr -d '\r')" ] && [ "$se" = "0" ]; then
    echo "$c: OK"; pass=$((pass+1))
  else
    echo "$c: DIFF"; fail=$((fail+1))
    echo "--- sim:"; printf '%s\n' "$sl"
    echo "--- want:"; printf '%s\n' "$expected"
  fi
}

E_MXDOUBLE="2 3
2 3 4 5 6 7
6 6"
E_MXSCALAR="43"
E_MXSHAPE="6.0603e+06"
E_MXINT="12
1 3 3
110 120 130
ok=1"
E_MXCHAR="1
1
prefix:hi"
E_MXMATH="1.186532 1.841471 1.243198 0.747404"

run_one mxdouble "$E_MXDOUBLE"
run_one mxscalar "$E_MXSCALAR"
run_one mxshape  "$E_MXSHAPE"
run_one mxint    "$E_MXINT"
run_one mxchar   "$E_MXCHAR"
run_one mxmath   "$E_MXMATH"
echo "mx smoke: $pass passed, $fail failed"
exit $fail
