struct P { int x; int y; }; int main() { struct P arr[2]; struct P *p; arr[0].x = 7; arr[1].x = 9; p = &arr[0]; p++; return p->x; }
