#!/bin/bash
# regression batch for cc_int/x86sim double support (ME-1) vs gcc
cd /d/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab || exit 1
M=/d/Projects/codes/MATLAB_in_c/matlab.exe
S='D:/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab'
pass=0; fail=0
for c in cc10_cadd dsmoke dcmp dneg dmore dmore2 dmore3 dmore4 dand dge d2and dand4 dmath; do
  $M -e "addpath('${S}/src'); cc_int('${S}/tests/programs/${c}.c', 'D:/tmp/${c}.s'); x = x86sim('D:/tmp/${c}.s'); fprintf('SIM_EXIT=%d', x);" > /d/tmp/out.txt 2>&1
  if grep -q "^Error" /d/tmp/out.txt; then
    echo "$c: ERROR $(grep -m1 Error /d/tmp/out.txt)"; fail=$((fail+1)); continue
  fi
  # program stdout = everything except the trailing SIM_EXIT= marker
  sline=$(sed 's/SIM_EXIT=.*//' /d/tmp/out.txt | head -1)
  sexit=$(grep -oE "SIM_EXIT=[0-9-]+" /d/tmp/out.txt | cut -d= -f2)
  gcc tests/programs/${c}.c -o /d/tmp/g.exe -lm 2>/dev/null && /d/tmp/g.exe > /d/tmp/gout.txt; grc=$?
  gline=$(head -1 /d/tmp/gout.txt)
  if [ "$sline" = "$gline" ] && [ "$sexit" = "$grc" ]; then
    echo "$c: OK (exit $grc)"; pass=$((pass+1))
  else
    echo "$c: DIFF sim=[$sline] exit=$sexit vs gcc=[$gline] exit=$grc"; fail=$((fail+1))
  fi
done
echo "double regression: $pass passed, $fail failed"