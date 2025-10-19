
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#include <groups.h>
#include <bits_array.h>
#include <timing.h>
#include <compressedFile.h>
#include <shuffle.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <assert.h>
#include <threading.h>

#define END_ROUND 1000
#define START_ROUND 141

typedef struct SeedResults {
    uint32_t cash[END_ROUND - START_ROUND];
    uint16_t numFBads[END_ROUND - START_ROUND];
    uint16_t numBads[END_ROUND - START_ROUND];
} SeedResults;

__device__
const uint32_t bloonCash[18] = {
    0, 1, 2, 3, 4, 5,
    6, 6, 6, 7, 7,
    8, 95, 381, 1525,
    6101, 381, 13346
};

__device__
static uint32_t getCash50(int32_t bloonType) {
    return bloonCash[bloonType >> 3];
}

__global__
static void searchSeedsKernel(
    const uint16_t roundStart,
    const uint16_t roundEnd,
    const Byte* groupValidity,
    const ShuffleCache* shuffles,
    const BoundlessGroup* groups,
    const uint32_t seedStart,
    const uint32_t numSeeds,
    SeedResults* results
) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx >= numSeeds) return;

    for (uint16_t round = roundStart; round < roundEnd; ++round) {
        uint32_t totalCash = 0;
        uint16_t totalNumFbads = 0;
        uint16_t totalNumBads = 0;
        const ShuffleCacheEntry* groupIdxs = &shuffles->cache[idx + round];
        const uint32_t offset = ((uint32_t)round) * NUM_GROUPS;
        float budget = (round * 4000 - 225000) * groupIdxs->budget_multiplier;

        if (round >= 511) {
            for (uint16_t i = 0; i < MAX_COUNT; ++i) {
                uint32_t groupIndex = groupIdxs->r511Groups[i];

                if (groupIndex == R511END) {
                    break;
                }

                const BoundlessGroup* group = &groups[groupIndex];

                if (group->score > budget) {
                    continue;
                }

                budget -= group->score;
                totalCash += getCash50(group->type) * group->count;

                if (group->type == FBAD_TYPE) totalNumFbads += group->count;
                if (group->type == BAD_TYPE) totalNumBads += group->count;
            }
        }
        else {
            for (uint16_t i = 0; i < NUM_GROUPS; ++i) {
                uint32_t groupIndex = groupIdxs->indexes[i];
                if (!bitGet(groupValidity, offset + groupIndex)) {
                    continue;
                }

                const BoundlessGroup* group = &groups[groupIndex];

                if (group->score > budget) {
                    continue;
                }

                budget -= group->score;
                totalCash += getCash50(group->type) * group->count;

                if (group->type == FBAD_TYPE) totalNumFbads += group->count;
                if (group->type == BAD_TYPE) totalNumBads += group->count;
            }
        }
        results[idx].cash[round - roundStart] = totalCash;
        results[idx].numFBads[round - roundStart] = totalNumFbads;
        results[idx].numBads[round - roundStart] = totalNumBads;
    }
}

static cudaError_t createShuffleCache(ShuffleCache** cache, size_t size) {
    cudaError_t err;
    err = cudaMalloc(cache, sizeof(ShuffleCache));
    if (err != cudaSuccess) return err;
    ShuffleCache _cache = { NULL, size };
    err = cudaMalloc(&_cache.cache, size * sizeof(ShuffleCacheEntry));
    if (err != cudaSuccess) {
        cudaFree(cache);
        return err;
    }
    err = cudaMemcpy(*cache, &_cache, sizeof(ShuffleCache), cudaMemcpyHostToDevice);
    if (err != cudaSuccess) {
        cudaFree(_cache.cache);
        cudaFree(*cache);
        return err;
    }
    return err;
}

typedef struct SearchSetup {
    Byte* groupValidity;
    ShuffleCache* shuffles;
    BoundlessGroup* groups;
    SeedResults* cu_results;
    SeedResults* results;
} SearchSetup;

static void finishSearch(SearchSetup* setup) {
    if (setup->groupValidity) cudaFree(setup->groupValidity);
    if (setup->shuffles) cu_freeCache(setup->shuffles);
    if (setup->groups) cudaFree(setup->groups);
    if (setup->cu_results) cudaFree(setup->cu_results);
    if (setup->results) free(setup->results);
}

static int setupSearch(SearchSetup* setup, size_t shuffleSize, size_t nSeeds) {
    cudaError_t err;
    setup->shuffles = NULL;
    setup->groups = NULL;
    setup->results = NULL;
    setup->cu_results = NULL;
    setup->groupValidity = cu_makeGroupsArray(END_ROUND);
    if (!setup->groupValidity) goto fail;
    err = createShuffleCache(&setup->shuffles, shuffleSize);
    if (err != cudaSuccess) goto fail;
    setup->groups = cudifyGroups();
    if (!setup->groups) goto fail;
    err = cudaMalloc(&setup->cu_results, nSeeds * sizeof(SeedResults));
    if (err != cudaSuccess) goto fail;
    err = cudaMemset(setup->cu_results, 0, nSeeds * sizeof(SeedResults));
    if (err != cudaSuccess) goto fail;
    setup->results = (SeedResults*)malloc(nSeeds * sizeof(SeedResults));
    if (!setup->results) goto fail;
    return 0;
fail:
    finishSearch(setup);
    return 1;
}

static int searchSeeds3() {
    if (ensureDirectoryExists("database/")) {
        return 1;
    }
    cudaError_t err;
    SearchSetup setup;
    CompressedFile file;
    char path[100] = { 0 };
    int nSeeds = 100000;
    int nThreads = 256;
    int nBlocks = (nSeeds + nThreads - 1) / nThreads;
    if (CompressedFile_Init(&file, "results.bin", "wb", 300000)) {
        return 1;
    }
    if (setupSearch(&setup, nSeeds + END_ROUND, nSeeds)) {
        CompressedFile_Free(&file);
        return 1;
    }
    uint64_t start, end;
    start = time_us();

    for (int seedStart = 0; seedStart < 1000000000; seedStart += nSeeds) {
        err = cu_fillCache(setup.shuffles, nSeeds + END_ROUND, seedStart, setup.groupValidity);
        if (err != cudaSuccess) goto fail;

        searchSeedsKernel KERNEL_ARGS2(nBlocks, nThreads) (
            START_ROUND,
            END_ROUND,
            setup.groupValidity,
            setup.shuffles,
            setup.groups,
            seedStart,
            nSeeds,
            setup.cu_results
            );
        err = cudaGetLastError();
        if (err != cudaSuccess) goto fail;
        err = cudaDeviceSynchronize();
        if (err != cudaSuccess) 
            goto fail;
        err = cudaMemcpy(setup.results, setup.cu_results, nSeeds * sizeof(SeedResults), cudaMemcpyDeviceToHost);
        if (err != cudaSuccess) goto fail;

        end = time_us();
        printf("Computed up to the %d seed in %llu seconds\n", seedStart + nSeeds, (end - start + 500000) / 1000000);

        if (snprintf(path, 100, "database/seeds_%d-%d.bin", seedStart, seedStart + nSeeds) >= 100) goto fail;
        if (CompressedFile_SetFilename(&file, path, "wb")) goto fail;
        for (size_t i = 0; i < nSeeds; i += 100) {
            for (size_t j = 0; j < 100; j++) {
                SeedResults* res = &setup.results[i + j];
                for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                    if (ByteBuffer_Push4(&file.buffer, res->numFBads[round], 1)) goto fail;
                    if (ByteBuffer_Push4(&file.buffer, res->numBads[round], 1)) goto fail;
                    if (ByteBuffer_Push4(&file.buffer, res->cash[round], 4)) goto fail;
                }
            }
            if (CompressedFile_Write(&file, 7, NULL, NULL)) goto fail;
        }
        end = time_us();
        printf("Wrote up to the %d seed in %llu seconds\n", seedStart + nSeeds, (end - start + 500000) / 1000000);
    }

    finishSearch(&setup);
    CompressedFile_Free(&file);
    return 0;
fail:
    fprintf(stderr, "something went wrong somewhere\n");
    perror("maybe perror will know what: ");
    finishSearch(&setup);
    CompressedFile_Free(&file);
    return 1;
}

static int searchSeedsBegin(SearchSetup* setup, int seedStart, int nSeeds, int nBlocks, int nThreads) {
    cudaError_t err;
    err = cu_fillCache(setup->shuffles, nSeeds + END_ROUND, seedStart, setup->groupValidity);
    if (err != cudaSuccess) return 1;

    searchSeedsKernel KERNEL_ARGS2(nBlocks, nThreads) (
        START_ROUND,
        END_ROUND,
        setup->groupValidity,
        setup->shuffles,
        setup->groups,
        seedStart,
        nSeeds,
        setup->cu_results
    );
    err = cudaGetLastError();
    if (err != cudaSuccess) return 1;
    return 0;
}

static int searchSeedsGetResults(SearchSetup* setup, int nSeeds) {
    cudaError_t err;
    err = cudaDeviceSynchronize();
    if (err != cudaSuccess) return 1;
    err = cudaMemcpy(setup->results, setup->cu_results, nSeeds * sizeof(SeedResults), cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) return 1;
    return 0;
}

typedef struct FileGroup {
    CompressedFile* files;
    size_t numFiles;
} FileGroup;

static int searchSeedsOutput(SeedResults* results, CompressedFile *file, int seedStart, int nSeeds, ZSTD_CCtx *context, ByteBuffer *temp_buffer) {
    char path[100] = { 0 };
    if (snprintf(path, 100, "database/cash_%d-%d.bin", seedStart, seedStart + nSeeds) >= 100) return 1;
    if (CompressedFile_SetFilename(file, path, "wb")) return 1;
    for (size_t i = 0; i < nSeeds; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults* res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                if (ByteBuffer_Push4(&file->buffer, res->cash[round], 4)) return 1;
            }
        }
        if (CompressedFile_Write(file, 7, context, temp_buffer)) return 1;
    }
    if (snprintf(path, 100, "database/fbads_%d-%d.bin", seedStart, seedStart + nSeeds) >= 100) return 1;
    if (CompressedFile_SetFilename(file, path, "wb")) return 1;
    for (size_t i = 0; i < nSeeds; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults* res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                if (ByteBuffer_Push4(&file->buffer, res->numFBads[round], 1)) return 1;
            }
        }
        if (CompressedFile_Write(file, 7, context, temp_buffer)) return 1;
    }
    if (snprintf(path, 100, "database/bads_%d-%d.bin", seedStart, seedStart + nSeeds) >= 100) return 1;
    if (CompressedFile_SetFilename(file, path, "wb")) return 1;
    for (size_t i = 0; i < nSeeds; i += 100) {
        for (size_t j = 0; j < 100; j++) {
            SeedResults* res = &results[i + j];
            for (size_t round = 0; round < END_ROUND - START_ROUND; round++) {
                if (ByteBuffer_Push4(&file->buffer, res->numBads[round], 1)) return 1;
            }
        }
        if (CompressedFile_Write(file, 7, context, temp_buffer)) return 1;
    }
}

typedef struct OutputArgs {
    SeedResults* results;
    CompressedFile* file;
    int seedStart;
    int nSeeds;
} OutputArgs;

static CrossThreadReturnValue searchSeedsOutput2(void* _arg) {
    OutputArgs arg = *(OutputArgs*)_arg;
    // ByteBuffer temp_buffer = {0};
    // ZSTD_CCtx *context = ZSTD_createCCtx();
    // if (!context) return (CrossThreadReturnValue) 1;
    int code = searchSeedsOutput(arg.results, arg.file, arg.seedStart, arg.nSeeds, NULL, NULL);
    // ZSTD_freeCCtx(context);
    //its a bit odd but zero init'ing a ByteBuffer is a valid state to use (maybe I should change that)
    //but using it can allocate mem, so it needs to be freed
    // ByteBuffer_Free(&temp_buffer);
    return (CrossThreadReturnValue)code;
}

static int searchSeedsOutputThreaded(SearchSetup *setup, FileGroup files, int seedStart, int seedsPerFile) {
    int ret = 1;
    CrossThread *threads = NULL;
    OutputArgs *args = NULL;
    threads = (CrossThread *)calloc(files.numFiles, sizeof(CrossThread));
    if (!threads) goto fail;
    args = (OutputArgs *)calloc(files.numFiles, sizeof(OutputArgs));
    if (!args) goto fail;
    for (size_t i = 0; i < files.numFiles; i++) {
        args[i].results = &setup->results[seedsPerFile * i];
        args[i].file = &files.files[i];
        args[i].seedStart = seedStart + seedsPerFile * i;
        args[i].nSeeds = seedsPerFile;
        if (CrossThread_Run(&threads[i], searchSeedsOutput2, &args[i])) {
            //close preceding threads
            JoinCrossThreads(i, threads, NULL);
            goto fail;
        }
    }
    if (JoinCrossThreads(files.numFiles, threads, NULL)) {
        goto fail;
    }

    ret = 0;

fail:

    if (threads) free(threads);
    if (args) free(args);    
}

static int searchSeedsAsync() {
    const int nFiles = 4;
    if (ensureDirectoryExists("database/")) {
        return 1;
    }
    int ret;
    SearchSetup setup;
    CompressedFile file[nFiles];
    FileGroup fileGroup = { file, nFiles };
    int nSeeds = 100000;
    int nThreads = 320;
    int nBlocks = (nSeeds + nThreads - 1) / nThreads;
    for (size_t i = 0; i < nFiles; i++) {
        if (CompressedFile_Init(&file[i], "data.bin", "wb", 300000)) {
            goto fail;
        }
    }
    if (setupSearch(&setup, nSeeds + END_ROUND, nSeeds)) {
        goto fail;
    }
    uint64_t start, end;
    start = time_us();

    if (searchSeedsBegin(&setup, 0, nSeeds, nBlocks, nThreads)) goto fail;

    for (int seedStart = nSeeds; seedStart < 1000000000; seedStart += nSeeds) {
        if (searchSeedsGetResults(&setup, nSeeds)) goto fail;

        end = time_us();
        printf("Computed up to the %d seed in %llu seconds\n", seedStart, (end - start + 500000) / 1000000);

        if (searchSeedsBegin(&setup, seedStart, nSeeds, nBlocks, nThreads)) goto fail;

        if (searchSeedsOutputThreaded(&setup, fileGroup, seedStart - nSeeds, nSeeds / nFiles)) goto fail;
        end = time_us();
        printf("Wrote up to the %d seed in %llu seconds\n", seedStart, (end - start + 500000) / 1000000);
    }
    if (searchSeedsGetResults(&setup, nSeeds)) goto fail;

    if (searchSeedsOutputThreaded(&setup, fileGroup, 1000000000 - nSeeds, nSeeds / nFiles)) goto fail;

    finishSearch(&setup);
    ret = 0;
    for (size_t i = 0; i < nFiles; i++) {
        if (CompressedFile_Free(&file[i])) {
            perror("Freeing compressed file failed: ");
            ret = 1;
        }
    }
    return ret;
fail:
    fprintf(stderr, "something went wrong somewhere\n");
    perror("maybe perror will know what: ");
    finishSearch(&setup);
    for (size_t i = 0; i < nFiles; i++) CompressedFile_Free(&file[i]);
    return 1;
}

int main(void) {
    return searchSeedsAsync();
}
