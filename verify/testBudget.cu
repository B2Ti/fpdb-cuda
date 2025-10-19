#include <stdint.h>
#include <stdio.h>

#define NUM_GROUPS 529
#define MAX_COUNT 76
#define R511END 0xffff

#ifdef __INTELLISENSE__
#define KERNEL_ARGS2(grid, block)
#define KERNEL_ARGS3(grid, block, sh_mem)
#define KERNEL_ARGS4(grid, block, sh_mem, stream)
#else
#define KERNEL_ARGS2(grid, block) <<< grid, block >>>
#define KERNEL_ARGS3(grid, block, sh_mem) <<< grid, block, sh_mem >>>
#define KERNEL_ARGS4(grid, block, sh_mem, stream) <<< grid, block, sh_mem, stream >>>
#endif

typedef struct seededRandom {
    uint32_t seed;
} seededRandom;

typedef struct ShuffleCacheEntry {
    int32_t seed;
    uint32_t final_seed;
    uint32_t penultimate_seed;
    uint16_t indexes[NUM_GROUPS];
    float budget_multiplier;
    //The validity of groups is identical from r511-r1k so we cache this as well
    uint16_t r511Groups[MAX_COUNT];
} shuffleCacheEntry;


__device__
inline float getNextSeed(seededRandom* rand) {
    rand->seed = (rand->seed * 0x41a7) % 0x7FFFFFFFLLU;
    float value = ((float)rand->seed) / 2147483646.f;
    return value;
}

__device__
inline int64_t getNextSeedBounded(seededRandom* rand, int64_t min, int64_t max) {
    if (min == max) {
        return max;
    }
    if (min > max) {
        int64_t tmp = min;
        min = max;
        max = tmp;
    }
    const int64_t inv_range = min - max;
    rand->seed = ((uint64_t)rand->seed * 0x41a7LLU) % 0x7FFFFFFFLLU;
    int64_t shift = rand->seed % inv_range;
    if (shift >= 0) {
        shift += inv_range;
    }
    return max + shift;
}

__device__
void shuffleInPlace16(uint16_t array[], size_t len, seededRandom* rand) {
    for (size_t i = 0; i < len; i++) {
        int64_t index = getNextSeedBounded(rand, i, len);
        uint16_t tmp = array[i];
        array[i] = array[index];
        array[index] = tmp;
    }
}

__device__
void setEntrySeed(ShuffleCacheEntry* entry, uint32_t seed) {
    for (uint16_t i = 0; i < NUM_GROUPS; i++) {
        entry->indexes[i] = i;
    }
    entry->seed = seed;
    seededRandom rand = { seed };
    
    shuffleInPlace16(entry->indexes, NUM_GROUPS, &rand);

    entry->penultimate_seed = rand.seed;
    entry->budget_multiplier = 1.5f - getNextSeed(&rand);
    entry->final_seed = rand.seed;
}

__global__
void process(ShuffleCacheEntry *entry) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= 1) return;
    setEntrySeed(entry, 772);
}

int main() {
    ShuffleCacheEntry *_entry;
    cudaMalloc(&_entry, sizeof(ShuffleCacheEntry));
    process KERNEL_ARGS2(16, 16) (_entry);
    ShuffleCacheEntry entry;
    cudaMemcpy(&entry, _entry, sizeof(ShuffleCacheEntry), cudaMemcpyDeviceToHost);
    printf("%d\n", entry.penultimate_seed);
    printf("%d\n", entry.final_seed);
}
