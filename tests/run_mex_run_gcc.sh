#!/bin/bash
# GCC reference-track gate: mex_run(src, ins...) vs mex_run(src, ins..., 'gcc')
# must return identical outputs on the shared MEX corpus (the compiler
# project's group-11 sources + the main repo's B+ parity corpus, minus the
# mexCallMATLAB-dependent one that needs a MATLAB host).
cd /d/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab || exit 1
M=/d/Projects/codes/MATLAB_in_C/matlab.exe
S='D:/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab'
C='D:/Projects/codes/MATLAB_in_C'
pass=0; fail=0

check() {
  local name="$1" body="$2"
  $M -e "addpath('${S}/src'); addpath('${S}/tests'); $body" > /d/tmp/o.txt 2>&1
  if grep -q '^Error' /d/tmp/o.txt; then
    echo "$name: ERROR $(grep -m1 -A1 '^Error' /d/tmp/o.txt | tail -1)"
    fail=$((fail+1)); return
  fi
  if grep -q 'PARITY FAIL' /d/tmp/o.txt; then
    echo "$name: DIFF $(grep -m1 'PARITY FAIL' /d/tmp/o.txt)"
    fail=$((fail+1)); return
  fi
  echo "$name: OK"
  pass=$((pass+1))
}

# ---- compiler-project group-11 corpus ----
check mxdouble "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxdouble.c', [1 2 3; 4 5 6]), mex_run('${S}/tests/programs/mxdouble.c', [1 2 3; 4 5 6], 'gcc'));"
check mxscalar "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxscalar.c', 21.5), mex_run('${S}/tests/programs/mxscalar.c', 21.5, 'gcc'));"
check mxshape  "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxshape.c', [1 2 3; 4 5 6]), mex_run('${S}/tests/programs/mxshape.c', [1 2 3; 4 5 6], 'gcc'));"
check mxint    "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxint.c', int32([10 20 30])), mex_run('${S}/tests/programs/mxint.c', int32([10 20 30]), 'gcc'));"
check mxchar   "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxchar.c', 'hi'), mex_run('${S}/tests/programs/mxchar.c', 'hi', 'gcc'));"
check mxmath   "[a,b] = gcc_ab(mex_run('${S}/tests/programs/mxmath.c', [0.5 1 4 0.25]), mex_run('${S}/tests/programs/mxmath.c', [0.5 1 4 0.25], 'gcc'));"

# ---- main-repo B+ parity corpus (no MATLAB-host dependency) ----
check mxcell_build "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxcell.c'), mex_run('${C}/tests/mex/mxcell.c', 'gcc'));"
check mxcell_get   "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxcell.c', 'get', {10, 'two', [3 4]}), mex_run('${C}/tests/mex/mxcell.c', 'get', {10, 'two', [3 4]}, 'gcc'));"
check mxstruct_build "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxstruct.c'), mex_run('${C}/tests/mex/mxstruct.c', 'gcc'));"
check mxstruct_get  "s.a = [1 2; 3 4]; s.s = 'hello'; [a,b] = gcc_ab(mex_run('${C}/tests/mex/mxstruct.c', 'get', s), mex_run('${C}/tests/mex/mxstruct.c', 'get', s, 'gcc'));"
check mxsparse_build "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxsparse.c'), mex_run('${C}/tests/mex/mxsparse.c', 'gcc'));"
check mxsparse_get  "sp = sparse([1 2 3], [1 3 3], [5 7 -1], 3, 3); [a,b] = gcc_ab(mex_run('${C}/tests/mex/mxsparse.c', sp), mex_run('${C}/tests/mex/mxsparse.c', sp, 'gcc'));"
check mxerror_id   "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxerror.c', 'id'), mex_run('${C}/tests/mex/mxerror.c', 'id', 'gcc'));"
check mxprint      "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxprint.c'), mex_run('${C}/tests/mex/mxprint.c', 'gcc'));"
check mxpersist_get "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxpersist.c', 'get'), mex_run('${C}/tests/mex/mxpersist.c', 'get', 'gcc'));"
check mxpersist_lock "[a,b] = gcc_ab(mex_run('${C}/tests/mex/mxpersist.c', 'lock'), mex_run('${C}/tests/mex/mxpersist.c', 'lock', 'gcc'));"
check yprime      "[a,b] = gcc_ab(mex_run('${C}/tests/mex/yprime.c', 1.0, [0 1; 0 1]), mex_run('${C}/tests/mex/yprime.c', 1.0, [0 1; 0 1], 'gcc'));"
check matfile     "[a,b] = gcc_ab(mex_run('${C}/tests/mex/matfile.c', 'v160_ab.mat', 'roundtrip', [1 2 3; 4 5 6]), mex_run('${C}/tests/mex/matfile.c', 'v160_ab.mat', 'roundtrip', [1 2 3; 4 5 6], 'gcc'));"
check matfile_del  "[a,b] = gcc_ab(mex_run('${C}/tests/mex/matfile.c', 'v160_ab_del.mat', 'delete', 'X'), mex_run('${C}/tests/mex/matfile.c', 'v160_ab_del.mat', 'delete', 'X', 'gcc'));"

check matrixDivide "[a,b] = gcc_ab(mex_run('${C}/tests/mex/matrixDivideComplex.c', [1 2; 3 4], [5 0; 0 5]), mex_run('${C}/tests/mex/matrixDivideComplex.c', [1 2; 3 4], [5 0; 0 5], 'gcc'));"

echo "mex_run gcc cross-track gate: $pass passed, $fail failed"
exit $fail
