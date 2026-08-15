struct P { int x; }; struct P garr[3]; int main() { garr[2].x = 5; return garr[2].x; }
