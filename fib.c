int fib(int n) { if (n <= 1) { return 1; } return fib(n-1) + fib(n-2); }
int main() { 
    int i; i = 0;
    
    while (i <= 10)
    { 
        printf("fib(%2d) = %d\n", i, fib(i)); i = i + 1; 
    }
    
    return 0;
}

