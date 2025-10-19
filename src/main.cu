// cant be bothered to make timing.c how nvcc likes it
// cc timing/timing.c -I include -c -o src/timing.o
// nvcc -gencode=arch=compute_86,code=sm_86 -I include -I build/_deps/zstd-src/lib src/* -o main.out -L build/_deps/zstd-build/lib -lzstd -O2
#include <bits_array.hpp>
#include <assert.h>
#include <cuda_runtime.h>
#include <device_launch_parameters.h>
#include <groups.h>
#include <inttypes.h>
#include <shuffle.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <timing.h>

#include <compressedFile.hpp>
#include <cuda_utils.hpp>
#include <memory>
#include <sstream>
#include <stdexcept>
#include <thread>
#include <thread_pool.hpp>
#include <vector>

const int TOTAL_SEEDS = 1000000000;
const int NUM_SEEDS = 100000;
#define END_ROUND 1000
#define START_ROUND 141

typedef struct SeedResults {
    uint32_t cash[END_ROUND - START_ROUND];
    uint16_t numFBads[END_ROUND - START_ROUND];
    uint16_t numBads[END_ROUND - START_ROUND];
} SeedResults;

__device__ const uint32_t bloonCash[18] =
    {0, 1, 2, 3, 4, 5, 6, 6, 6, 7, 7, 8, 95, 381, 1525, 6101, 381, 13346};

__device__ static inline uint32_t getCash50(int32_t bloonType) {
    return bloonCash[bloonType >> 3];
}

class SearchSetup {
   public:
    std::unique_ptr<Byte, CudaDeleter> group_validity;
    std::unique_ptr<ShuffleCache, ShuffleDeleter> shuffles;
    std::unique_ptr<BoundlessGroup, CudaDeleter> groups;
    std::unique_ptr<SeedResults, CudaDeleter> cu_results;
    std::unique_ptr<SeedResults> results;
    SearchSetup(size_t n_seeds) {
        cudaError_t err;
        const size_t shuffle_size = n_seeds + END_ROUND;
        ShuffleCache *cache = cuda_new<ShuffleCache>(1);
        ShuffleCache _cache = {nullptr, shuffle_size};
        err =
            cudaMalloc(&_cache.cache, shuffle_size * sizeof(ShuffleCacheEntry));
        if (err != cudaSuccess) {
            cudaFree(cache);
            throw std::runtime_error("cudaMalloc");
        }
        err = cudaMemcpy(
            cache, &_cache, sizeof(ShuffleCache), cudaMemcpyHostToDevice
        );
        if (err != cudaSuccess) {
            cudaFree(cache);
            cudaFree(_cache.cache);
            throw std::runtime_error("cudaMalloc");
        }
        shuffles = std::unique_ptr<ShuffleCache, ShuffleDeleter>(
            cache, ShuffleDeleter{}
        );
        Byte *b = cu_makeGroupsArray(END_ROUND);
        if (!b) {
            throw std::runtime_error("cu_makeGroupsArray");
        }
        group_validity = std::unique_ptr<Byte, CudaDeleter>(b, CudaDeleter{});
        BoundlessGroup *g = cudifyGroups();
        if (!g) {
            throw std::runtime_error("cudifyGroups");
        }
        groups = std::unique_ptr<BoundlessGroup, CudaDeleter>(g, CudaDeleter{});
        cu_results = std::unique_ptr<SeedResults, CudaDeleter>(
            cuda_new<SeedResults>(n_seeds, true), CudaDeleter{}
        );
        results = std::unique_ptr<SeedResults>(new SeedResults[n_seeds]);
    }
};

static void searchSeeds(
    const Byte *group_validity,
    ShuffleCache *shuffles,
    const uint32_t seed,
    SeedResults *results
) {
    const uint32_t cash[18] =
        {0, 1, 2, 3, 4, 5, 6, 6, 6, 7, 7, 8, 95, 381, 1525, 6101, 381, 13346};
    for (uint16_t round = START_ROUND; round < END_ROUND; ++round) {
        uint32_t total_cash = 0;
        uint16_t total_num_fbads = 0;
        uint16_t total_num_bads = 0;
        const ShuffleCacheEntry *groupIdxs = &shuffles->cache[seed + round];
        const uint32_t offset = ((uint32_t)round) * NUM_GROUPS;
        const float original_budget =
            (round * 4000 - 225000) * groupIdxs->budget_multiplier;
        float budget = original_budget;

        if (round >= 511) {
            for (uint16_t i = 0; i < MAX_COUNT; ++i) {
                uint32_t groupIndex = groupIdxs->r511Groups[i];

                if (groupIndex == R511END) {
                    break;
                }

                const Group _group = getGroup(groupIndex);
                const Group *group = &_group;

                if (group->score <= budget) {
                    budget -= group->score;
                    total_cash += cash[group->type >> 3] * group->count;

                    if (group->type == FBAD_TYPE)
                        total_num_fbads += group->count;
                    if (group->type == BAD_TYPE) total_num_bads += group->count;
                }
            }
        } else {
            if (round == 501) {
                std::printf("this");
            }
            for (uint16_t i = 0; i < NUM_GROUPS; ++i) {
                uint32_t groupIndex = groupIdxs->indexes[i];
                if (!bitGet(group_validity, offset + groupIndex)) {
                    continue;
                }

                const Group _group = getGroup(groupIndex);
                const Group *group = &_group;

                if (group->score <= budget) {
                    budget -= group->score;
                    total_cash += cash[group->type >> 3] * group->count;

                    if (group->type == FBAD_TYPE)
                        total_num_fbads += group->count;
                    if (group->type == BAD_TYPE) total_num_bads += group->count;
                }
            }
            if (round == 501) {
                std::printf("%d, %d\n", total_num_bads, total_num_fbads);
            }
        }
    }
}

__global__ static void searchSeedsKernel(
    const Byte *groupValidity,
    const ShuffleCache *shuffles,
    const BoundlessGroup *groups,
    const uint32_t seed_start,
    const uint32_t n_seeds,
    SeedResults *results
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= n_seeds) return;

    for (uint16_t round = START_ROUND; round < END_ROUND; ++round) {
        uint32_t totalCash = 0;
        uint16_t totalNumFbads = 0;
        uint16_t totalNumBads = 0;
        const ShuffleCacheEntry *groupIdxs = &shuffles->cache[idx + round];
        const uint32_t offset = ((uint32_t)round) * NUM_GROUPS;
        float budget = (round * 4000 - 225000) * groupIdxs->budget_multiplier;

        if (round >= 511) {
            for (uint16_t i = 0; i < MAX_COUNT; ++i) {
                uint32_t groupIndex = groupIdxs->r511Groups[i];

                if (groupIndex == R511END) {
                    break;
                }

                const BoundlessGroup *group = &groups[groupIndex];

                if (group->score <= budget) {
                    budget -= group->score;
                    totalCash += getCash50(group->type) * group->count;

                    if (group->type == FBAD_TYPE) totalNumFbads += group->count;
                    if (group->type == BAD_TYPE) totalNumBads += group->count;
                }
            }
        } else {
            for (uint16_t i = 0; i < NUM_GROUPS; ++i) {
                uint32_t groupIndex = groupIdxs->indexes[i];
                if (!bitGet(groupValidity, offset + groupIndex)) {
                    continue;
                }

                const BoundlessGroup *group = &groups[groupIndex];

                if (group->score <= budget) {
                    budget -= group->score;
                    totalCash += getCash50(group->type) * group->count;

                    if (group->type == FBAD_TYPE) totalNumFbads += group->count;
                    if (group->type == BAD_TYPE) totalNumBads += group->count;
                }
            }
        }
        results[idx].cash[round - START_ROUND] = totalCash;
        results[idx].numFBads[round - START_ROUND] = totalNumFbads;
        results[idx].numBads[round - START_ROUND] = totalNumBads;
    }
}

static void searchSeedsBegin(
    SearchSetup &setup, int seed_start, int n_blocks, int n_threads
) {
    cudaError_t err;
    err = cu_fillCache(
        setup.shuffles.get(),
        NUM_SEEDS + END_ROUND,
        seed_start,
        setup.group_validity.get()
    );
    if (err != cudaSuccess) {
        throw std::runtime_error("cu_fillCache");
    }

    searchSeedsKernel KERNEL_ARGS2(n_blocks, n_threads)(
        setup.group_validity.get(),
        setup.shuffles.get(),
        setup.groups.get(),
        seed_start,
        NUM_SEEDS,
        setup.cu_results.get()
    );
    err = cudaGetLastError();
    if (err != cudaSuccess) {
        throw std::runtime_error("searchSeedsKernel");
    }
}

static void searchSeedsOutput(
    SeedResults *results,
    CompressedFile *file,
    int seed_start,
    int seeds_per_file
) {
    std::stringstream path;
    path << "database/cash_" << seed_start << "-" << seed_start + seeds_per_file
         << ".bin";
    file->openFile(path.str().c_str());
    for (size_t i = 0; i < seeds_per_file; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults *res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                file->push4_le(res->cash[round], 4);
            }
        }
        file->writeBuffer(14);
    }
    path.str("");
    path.clear();
    path << "database/fbads_" << seed_start << "-"
         << seed_start + seeds_per_file << ".bin";
    file->openFile(path.str().c_str());
    for (size_t i = 0; i < seeds_per_file; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults *res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                file->push4_le(res->numFBads[round], 1);
            }
        }
        file->writeBuffer(10);
    }
    path.str("");
    path.clear();
    path << "database/bads_" << seed_start << "-" << seed_start + seeds_per_file
         << ".bin";
    file->openFile(path.str().c_str());
    for (size_t i = 0; i < seeds_per_file; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults *res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                file->push4_le(res->numBads[round], 1);
            }
        }
        file->writeBuffer(10);
    }
}

//owns results
static void _searchSeedsPooled(
    SeedResults *results,
    CompressedFile *file,
    int seed_start,
    int seeds_per_file
) {
    searchSeedsOutput(results, file, seed_start, seeds_per_file);
    delete[] results;
}

static void searchSeedsPooled(
    Thread &pool_thread,
    SearchSetup &setup,
    CompressedFile *file,
    int seed_start
) {
    auto results = new SeedResults[NUM_SEEDS];
    memcpy(results, setup.results.get(), sizeof(SeedResults[NUM_SEEDS]));
    pool_thread.run(
        _searchSeedsPooled, results, file, seed_start, NUM_SEEDS
    );
}

static void searchSeedsOutputThreaded(
    SearchSetup &setup,
    std::vector<CompressedFile> &files,
    int seed_start,
    int seeds_per_file
) {
    std::vector<std::thread> threads;
    for (size_t i = 0; i < files.size(); i++) {
        auto file = &files[i];
        int seed_offset = i * seeds_per_file;
        threads.push_back(
            std::thread(
                searchSeedsOutput,
                setup.results.get() + seed_offset,
                file,
                seed_start + seed_offset,
                seeds_per_file
            )
        );
    }
    for (auto &thread: threads) {
        thread.join();
    }
}

static void searchSeedsGetResults(SearchSetup &setup) {
    cudaError_t err;
    err = cudaDeviceSynchronize();
    if (err != cudaSuccess) {
        throw std::runtime_error("cudaDeviceSynchronize");
    }
    err = cudaMemcpy(
        setup.results.get(),
        setup.cu_results.get(),
        NUM_SEEDS * sizeof(SeedResults),
        cudaMemcpyDeviceToHost
    );
    if (err != cudaSuccess) {
        throw std::runtime_error("cudaMemcpy");
    }
}

static void searchSeedsAsync() {
    //keep in mind that each file needs about 700mb ram to store the results (at 100k seeds/kernel)
    //for me 5 files is required to stay gpu capped w/ the other settings that run the fastest (100k seeds/kernel, 320 threads/block)
    const int n_files = 5;
    if (ensureDirectoryExists("database/")) {
        throw std::runtime_error("ensureDirectoryExists failed");
    }
    ThreadPool pool(n_files);
    std::vector<CompressedFile> files;
    for (size_t i = 0; i < n_files; i++) {
        files.push_back(CompressedFile(CompressedFile_ModeWrite));
    }

    int n_threads = 320;
    int n_blocks = (NUM_SEEDS + n_threads - 1) / n_threads;

    SearchSetup setup{NUM_SEEDS};

    uint64_t start, end;
    start = time_us();

    searchSeedsBegin(setup, 0, n_blocks, n_threads);

    for (int seed_start = NUM_SEEDS; seed_start < TOTAL_SEEDS;
         seed_start += NUM_SEEDS) {
        searchSeedsGetResults(setup);
        end = time_us();
        printf(
            "Computed up to the %d seed in %" PRIu64 " ms\n",
            seed_start,
            (end - start + 500) / 1000
        );

        searchSeedsBegin(setup, seed_start, n_blocks, n_threads);
        // searchSeedsOutputThreaded(
        //     setup, files, seed_start - NUM_SEEDS, NUM_SEEDS / files.size()
        // );
        size_t thread_idx = pool.waitForThreadIdx();
        searchSeedsPooled(
            pool.getThread(thread_idx),
            setup,
            &files[thread_idx],
            seed_start - NUM_SEEDS
        );

        end = time_us();
        printf(
            "Wrote up to the %d seed in %" PRIu64 " ms\n",
            seed_start,
            (end - start + 500) / 1000
        );
    }

    searchSeedsGetResults(setup);
    size_t thread_idx = pool.waitForThreadIdx();
    searchSeedsPooled(
        pool.getThread(thread_idx),
        setup,
        &files[thread_idx],
        TOTAL_SEEDS - NUM_SEEDS
    );
    pool.joinAll();
}

void test() {
    auto va = makeGroupsArray(END_ROUND);
    ShuffleCache shuffle_cache = {new ShuffleCacheEntry[2000], 2000};
    {
        cudaError_t err;
        Byte *b = cu_makeGroupsArray(END_ROUND);
        if (!b) {
            throw std::runtime_error("cu_makeGroupsArray");
        }
        auto group_validity =
            std::unique_ptr<Byte, CudaDeleter>(b, CudaDeleter{});
        ShuffleCache *cache = cuda_new<ShuffleCache>(1);
        ShuffleCache _cache = {nullptr, 2000};
        err = cudaMalloc(&_cache.cache, 2000 * sizeof(ShuffleCacheEntry));
        if (err != cudaSuccess) {
            cudaFree(cache);
            throw std::runtime_error("cudaMalloc");
        }
        err = cudaMemcpy(
            cache, &_cache, sizeof(ShuffleCache), cudaMemcpyHostToDevice
        );
        if (err != cudaSuccess) {
            cudaFree(cache);
            cudaFree(_cache.cache);
            throw std::runtime_error("cudaMalloc");
        }
        auto shuffles = std::unique_ptr<ShuffleCache, ShuffleDeleter>(
            cache, ShuffleDeleter{}
        );
        err = cu_fillCache(shuffles.get(), 2000, 154000, group_validity.get());
        if (err != cudaSuccess) {
            throw std::runtime_error("cu_fillCache");
        }
        cudaMemcpy(
            shuffle_cache.cache,
            _cache.cache,
            2000 * sizeof(ShuffleCacheEntry),
            cudaMemcpyDeviceToHost
        );
    }
    searchSeeds(va, &shuffle_cache, 323, new SeedResults[2000]);
}

int main() {
    searchSeedsAsync();
    return 0;
}
