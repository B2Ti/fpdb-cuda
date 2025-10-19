#include <shuffle.h>
#include <stdexcept>

__device__
inline float getNextSeed(seededRandom* rand) {
    rand->seed = (rand->seed * 0x41a7LLU) % 0x7FFFFFFFLLU;
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
void shuffleInline(uint16_t array[], seededRandom *rand) {
    for (size_t i = 0; i < 529; i++) {
        rand->seed = ((uint64_t)rand->seed * 0x41a7LLU) % 0x7FFFFFFFLLU;
        int64_t index = i + rand->seed % (529 - i);
        uint16_t tmp = array[i];
        array[i] = array[index];
        array[index] = tmp;
    }
}

__host__ __device__
static Byte bitGet(const Byte* bytes, const size_t idx){
    return (bytes[idx >> 3] >> (idx & 0x7)) & 1;
}

__device__
void setEntryValidity(ShuffleCacheEntry* entry, const Byte* validityArray) {
    const uint32_t offset = 512 * NUM_GROUPS;
    uint16_t groups = 0;
    for (uint16_t i = 0; i < MAX_COUNT; i++) {
        entry->r511Groups[i] = R511END;
    }
    for (uint16_t i = 0; i < NUM_GROUPS; i++) {
        if (!bitGet(validityArray, offset + entry->indexes[i])) {
            continue;
        }
        if (groups >= MAX_COUNT) {
            for (volatile int *x = nullptr;;) {
                //force a invalid memory access
                //easier than proper handling when the logic itself is 100% broken
                *x = *(x++);
            }
        }   
        entry->r511Groups[groups] = entry->indexes[i];
        groups++;
    }
}

__device__
void setEntrySeed(ShuffleCacheEntry* entry, uint32_t seed, const Byte* validityArray) {
    for (uint16_t i = 0; i < NUM_GROUPS; i++) {
        entry->indexes[i] = i;
    }
    entry->seed = seed;
    seededRandom rand = { seed };
    
    #ifdef FORCE_INLINE
    shuffleInline(entry->indexes, &rand);
    #else
    shuffleInPlace16(entry->indexes, NUM_GROUPS, &rand);
    #endif

    if (validityArray) {
        setEntryValidity(entry, validityArray);
    }
    entry->budget_multiplier = 1.5f - getNextSeed(&rand);
}

__global__
void _fillCache(ShuffleCache* cache, size_t offset, const Byte* validityArray) {
    const int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= cache->size) {
        return;
    }
    const uint32_t entryIdx = offset + (size_t)idx;
    setEntrySeed(&cache->cache[idx], entryIdx, validityArray);
    return;
}

int cpyCache(ShuffleCache* dst, const ShuffleCache* src, cudaMemcpyKind kind) {
    cudaError_t err = cudaMemcpy(dst, src, sizeof(ShuffleCache), kind);
    if (err != cudaSuccess) return 1;
    shuffleCacheEntry* cache = dst->cache;
    dst->cache = (ShuffleCacheEntry*)malloc(dst->size * sizeof(ShuffleCacheEntry));
    if (!dst->cache) {
        return 1;
    }
    err = cudaMemcpy(dst->cache, cache, dst->size * sizeof(ShuffleCacheEntry), kind);
    if (err != cudaSuccess) return 1;
    return 0;
}

void cu_freeCache(ShuffleCache* cache) {
    if (!cache) return;
    ShuffleCache _cache;
    cudaError_t err = cudaMemcpy(&_cache, cache, sizeof(ShuffleCache), cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) {
        throw std::runtime_error("cudaMemcpy");
    }
    if (_cache.cache) cudaFree(_cache.cache);
    cudaFree(cache);
}

cudaError_t cu_fillCache(ShuffleCache* cache, size_t size, size_t offset, const Byte* validityArray) {
    cudaError_t err;
    int nThreads = 128;
    int nBlocks = (size + nThreads - 1) / nThreads;
    _fillCache KERNEL_ARGS2(nBlocks, nThreads) (cache, offset, validityArray);
    err = cudaGetLastError();
    if (err != cudaSuccess) return err;
    err = cudaDeviceSynchronize();
    return err;
}

cudaError_t fillCache(ShuffleCache* cache, size_t size, size_t offset, const Byte* validityArray) {
    cudaError_t err;
    ShuffleCache* _cache;
    err = cudaMalloc(&_cache, sizeof(ShuffleCache));
    if (err != cudaSuccess) return err;
    {
        ShuffleCacheEntry* _entries;
        err = cudaMalloc(&_entries, size * sizeof(ShuffleCacheEntry));
        if (err != cudaSuccess) {
            cudaFree(_cache);
            return err;
        }
        ShuffleCache __cache = {
            _entries, size
        };
        err = cudaMemcpy(_cache, &__cache, sizeof(ShuffleCache), cudaMemcpyHostToDevice);
        if (err != cudaSuccess) {
            cudaFree(_entries);
            cudaFree(_cache);
            return err;
        }
    }
    int nthreads = 128;
    int nblocks = (size + nthreads - 1) / nthreads;
    _fillCache KERNEL_ARGS2(nblocks, nthreads) (_cache, offset, validityArray);
    err = cudaGetLastError();
    if (err != cudaSuccess) {
        cu_freeCache(_cache);
        return err;
    }
    err = cudaDeviceSynchronize();
    if (err != cudaSuccess) {
        cu_freeCache(_cache);
        return err;
    }
    if (cpyCache(cache, _cache, cudaMemcpyDeviceToHost)) {
        cu_freeCache(_cache);
        return cudaErrorUnknown;
    }
    return cudaSuccess;
}

void ShuffleDeleter::operator()(ShuffleCache *ptr) const {
    cudaError_t err;
    ShuffleCache cache;
    err = cudaMemcpy(&cache, ptr, sizeof(ShuffleCache), cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) {
        //we cannot find the ptr to the allocated cache - it is leaked
        throw std::runtime_error("cudaMemcpy - memory leaked");
    }
    err = cudaFree(cache.cache);
    if (err != cudaSuccess) {
        cudaFree(ptr);
        throw std::runtime_error("cudaFree");
    }
    err = cudaFree(ptr);
    if (err != cudaSuccess) {
        throw std::runtime_error("cudaFree");
    }
}
