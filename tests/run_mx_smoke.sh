#!/bin/bash
# ME-2 smoke: assemble mx_preamble()+mxdouble.c, compile with cc_int, run
# the sim, compare stdout + exit code with the expected values.
cd /d/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab || exit 1
M=/d/Projects/codes/MATLAB_in_c/matlab.exe
SRC=/d/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab
S='D:/Projects/github/xiaoshaoning/Writing-a-C-Compiler-in-Matlab'
EXPECT="2 3
2 3 4 5 6 7
6 6"

# assemble preamble + source into one file for cc_int
$M -e "addpath('${S}/src'); pd = char(mx_preamble()); src = fileread('${S}/tests/programs/mxdouble.c'); fid = fopen('${S}/tests/tmp_mxdouble_asm.c','w'); fprintf(fid, '%s', pd); fprintf(fid, '%s', src); fclose(fid);" > /d/tmp/asm.txt 2>&1
if ! grep -q "tmp_mxdouble_asm.c" /dev/null 2>/dev/null; then :; fi
if [ ! -f tests/tmp_mxdouble_asm.c ]; then
  echo "ASSEMBLE FAILED: $(cat /d/tmp/asm.txt | tail -1)"; exit 1
fi

$M -e "addpath('${S}/src'); cc_int('${S}/tests/tmp_mxdouble_asm.c', '${S}/tests/tmp_mxdouble.s'); x = x86sim('${S}/tests/tmp_mxdouble.s'); fprintf('SIM_EXIT=%d', x);" > /d/tmp/o.txt 2>&1
if grep -q '^Error' /d/tmp/o.txt; then
  echo "COMPILE/ERROR: $(grep -m1 Error /d/tmp/o.txt)"; echo "---"; cat /d/tmp/o.txt | head -5; exit 1
fi
sim_out=$(sed 's/SIM_EXIT=.*//' /d/tmp/o.txt | grep -v '^$')
sexit=$(grep -oE "SIM_EXIT=[0-9-]+" /d/tmp/o.txt | cut -d= -f2)
echo "--- sim output ---"; echo "$sim_out"
if [ "$sim_out" = "$EXPECT" ] && [ "$sexit" = "0" ]; then
  echo "ME-2 mxdouble: OK (stdout + exit 0)"
else
  echo "ME-2 mxdouble: DIFF"
  echo "expected:"; echo "$EXPECT"
fi