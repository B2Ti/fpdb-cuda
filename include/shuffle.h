#pragma once

#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <stdint.h>

#include "groups.h"
#include "bits_array.hpp"

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
    uint16_t indexes[NUM_GROUPS];
    float budget_multiplier;
    //The validity of groups is identical from r511-r1k so we cache this as well
    uint16_t r511Groups[MAX_COUNT];
} shuffleCacheEntry;

typedef struct ShuffleCache {
    ShuffleCacheEntry* cache;
    size_t size;
} shuffleCache;

__device__
float getNextSeed(seededRandom* rand);

__device__
int64_t getNextSeedBounded(seededRandom* rand, int64_t min, int64_t max);

__device__
void shuffleInPlace16(uint16_t array[], size_t len, seededRandom* rand);

__device__
void setEntrySeed(ShuffleCacheEntry* entry, uint32_t seed, const Byte* groupValidity);

__global__
void _fillCache(ShuffleCache* cache, size_t offset, const Byte* groupValidity);

int cpyCache(ShuffleCache* dst, const ShuffleCache* src, cudaMemcpyKind kind);

void cu_freeCache(ShuffleCache* cache);

cudaError_t cu_fillCache(ShuffleCache* cache, size_t size, size_t offset, const Byte* groupValidity);

cudaError_t fillCache(ShuffleCache* cache, size_t size, size_t offset, const Byte* groupValidity);

struct ShuffleDeleter {
    void operator()(ShuffleCache *ptr) const;
};
