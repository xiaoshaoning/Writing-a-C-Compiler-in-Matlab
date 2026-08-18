// Backslash escapes in string literals must survive to the .string data
// (the emitted .string used to lose the backslash entirely).
int main() { char *s; s = "a\\b"; return s[1]; }   /* 92 */
