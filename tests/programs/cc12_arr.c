struct P { int x; }; int main() { struct P arr[3]; arr[0].x = 1; arr[1].x = 2; arr[2].x = 3; return arr[0].x + arr[1].x * 10 + arr[2].x * 100; }
