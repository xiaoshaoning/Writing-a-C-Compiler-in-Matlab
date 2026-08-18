// Negative: & on a bare literal must error. The literal's VALUE collided
// with the LI/LC opcode numbers (9/10), so &(9) and &(10) used to be
// silently accepted as fake pointers.
int main() { int *p; p = &(9); return 1; }
