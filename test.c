#include <assert.h>
#include <stdint.h>
#include <stdio.h>

static inline int64_t getNextSeedBounded(uint32_t* rand, int64_t min, int64_t max) {
    if (min == max) {
        return max;
    }
    if (min > max) {
        int64_t tmp = min;
        min = max;
        max = tmp;
    }
    const int64_t inv_range = min - max;
    (*rand) = ((uint64_t)(*rand) * 0x41a7LLU) % 0x7FFFFFFFLLU;
    int64_t shift = (*rand) % inv_range;
    if (shift >= 0) {
        shift += inv_range;
    }
    return max + shift;
}

int main(void) {
    printf("%f\n", (float)0x7FFFFFFE);
    for (long long int seed = 1; seed < 0x7FFFFFFF; seed += 1000) {
        long long int rng = seed;
        uint32_t rand = seed;
        for (int i = 0; i < 529; i++) {
            rng = (rng*16807) % 0x7FFFFFFF;
            int j = i + rng % (529 - i);
            int s = getNextSeedBounded(&rand, i, 529);
            if (j != s) {
                printf("%d) (%lld) %d != (%u) %d\n", rand, rng, i, j, s);
                assert(0 && "failure");
            }
        }
    }
    return 0;
}
