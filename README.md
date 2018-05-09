# Writing-a-C-Compiler-in-Matlab
Follow Nors Sandler's series [writing a C compiler](https://norasandler.com/2017/11/29/Write-a-Compiler.html).
```
cc_int return_2.c return_x.s
gcc return_2.s -o return_2
./return_2
echo $?
```
