#include <stdio.h>

int main(void) {
    printf("%d, ", (float)0x7FFFFFFE == (float)0x80000000);
    printf("%d\n", (float)0x7FFFFFFE == 2147483648.f);
}