// Negative: nested-brace initializers must enforce the same too-many
// guard as flat ones (this used to overflow the array silently).
int a[2][3] = {{1,2,3},{4,5,6},{7,8,9}};
int main() { return 1; }
