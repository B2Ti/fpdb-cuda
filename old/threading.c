#include <threading.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <timing.h>
#include <err_io.h>

/**
 * Specifically used for the applyFunction function
 * 
 * Keeps a reference to the thread's complete value to signal when the operation has been completed
 */
typedef struct ThreadArg {
    void *arg;
    ThreadTarget target;
    _Atomic(bool) *complete;
} ThreadArg;

/**
 * Consumes `arg` which must be dynamically allocated
 */
CrossThreadReturnValue applyFunction(void *arg) {
    ThreadArg *args = (ThreadArg*)arg;
    CrossThreadReturnValue code = args->target(args->arg);
    atomic_store_explicit(args->complete, true, memory_order_release);
    free(args);
    return code;
}

bool CrossThread_IsComplete(CrossThread *thread) {
    return atomic_load_explicit(&thread->complete, memory_order_acquire);
}

#if defined _WIN32

int CrossThread_Run(CrossThread *thread, CrossThreadReturnValue (*func)(void *arg), void *arg){
    DWORD threadID;

    ThreadArg *args = malloc(sizeof(ThreadArg));
    if (!args){
        return CrossThreadingFail;
    }
    args->arg = arg;
    args->target = func;
    args->complete = &thread->complete;

    atomic_store(&thread->complete);
    thread->thread = CreateThread(NULL,
                                  0,
                                  (LPTHREAD_START_ROUTINE) applyFunction,
                                  (LPVOID) args,
                                  0,
                                  &threadID);
    if (!thread){
        free(args);
        fprintf(stderr, "CreateCrossThread: CreateThread returned error code %lu\n", GetLastError());
        return CrossThreadingFail;
    }
    return CrossThreadingSuccess;
}

int CrossThread_Join(CrossThread *thread, CrossThreadReturnValue *returnValue) {
    int ret = CrossThreadingSuccess;
    DWORD result = WaitForSingleObject(thread->thread, INFINITE);
    if (result == ((DWORD)0xFFFFFFFFLU)){
        fprintf(stderr, "JoinCrossThreads: WaitForMultipleObjects returned error code %lu\n", GetLastError());
        CloseHandle(thread->thread);
        return CrossThreadingFail;
    }
    if (result >= WAIT_ABANDONED_0){
        fprintf(stderr, "JoinCrossThreads: WaitForMultipleObjects returned WAIT_ABANDONED\n");
        CloseHandle(thread->thread);    
        return AbandonedMutex;
    }
    if (returnValue){
        result = (DWORD)GetExitCodeThread(thread->thread, returnValue);
        if (result == 0){
            fprintf(stderr, "JoinCrossThreads: GetExitCodeThread returned error code %lu\n", GetLastError());
            ret = CrossThreadingFail;
        }
        if (!CloseHandle(thread->thread)){
            ret = CrossThreadingFail;
        }
    }
    return ret;
}

int JoinCrossThreads(int32_t numThreads, CrossThread *threads, CrossThreadReturnValue *returnValues){
    int ret = CrossThreadingSuccess;
    DWORD result = WaitForMultipleObjects(numThreads, threads, true, INFINITE);
    if (result == ((DWORD)0xFFFFFFFFLU)){
        fprintf(stderr, "JoinCrossThreads: WaitForMultipleObjects returned error code %lu\n", GetLastError());
        for (int32_t i = 0; i < numThreads; i++){
            CloseHandle(threads[i]);
        }
        return CrossThreadingFail;
    }
    if (result >= WAIT_ABANDONED_0){
        fprintf(stderr, "JoinCrossThreads: WaitForMultipleObjects returned WAIT_ABANDONED\n");
        for (int32_t i = 0; i < numThreads; i++){
            CloseHandle(threads[i]);
        }
        return AbandonedMutex;
    }
    if (!returnValues){
        for (int32_t i = 0; i < numThreads; i++){
            if (!CloseHandle(threads[i])){
                ret = CrossThreadingFail;
            }
        }
        return ret;
    }
    for (int32_t i = 0; i < numThreads; i++){
        result = (DWORD)GetExitCodeThread(threads[i], &returnValues[i]);
        if (result == 0){
            fprintf(stderr, "JoinCrossThreads: GetExitCodeThread returned error code %lu\n", GetLastError());
            ret = CrossThreadingFail;
        }
        if (!CloseHandle(threads[i])){
            ret = CrossThreadingFail;
        }
    }
    return ret;
}

// int CloseCrossThreads(int32_t numThreads, CrossThread *threads){
//     int32_t i, ret;
//     ret = CrossThreadingSuccess;
//     for (i = 0; i < numThreads; i++){
//         if (!CloseHandle(threads[i])){
//             ret = CrossThreadingFail;
//         }
//     }
//     return ret;
// }

#elif defined __unix || defined __APPLE__

int CrossThread_Run(CrossThread *thread, CrossThreadReturnValue (func)(void *arg), void *arg){
    ThreadArg *args = malloc(sizeof(ThreadArg));
    if (!args){
        return CrossThreadingFail;
    }
    atomic_store(&thread->complete, false);
    args->arg = arg;
    args->target = func;
    args->complete = &thread->complete;
    int resultCode = pthread_create(&thread->thread, NULL, applyFunction, args);
    if (resultCode){
        perror("CreateCrossThread unable to create new thread: ");
    }
    return resultCode;
}

int CrossThread_Join(CrossThread *thread, CrossThreadReturnValue *returnValue) {
    if (pthread_join(thread->thread, returnValue)) {
        perror("pthread_join call failed");
        return CrossThreadingFail;
    }
    return CrossThreadingSuccess;
}

int JoinCrossThreads(int32_t numThreads, CrossThread *threads, CrossThreadReturnValue *returnValues){
    int32_t i = 0;
    int32_t result = 0;
    if (!returnValues){
        for (i=0; i < numThreads; i++){
            result |= pthread_join(threads[i].thread, NULL);
        }
    } else {
        for (i=0; i < numThreads; i++){
            result |= pthread_join(threads[i].thread, &returnValues[i]);
        }
    }
    if (result){
        perror("pthread_join call failed: ");
        return CrossThreadingFail;
    }
    return CrossThreadingSuccess;
}

#else
#error "OS not supported"
#endif

static int JoinSparseThreads(int32_t nthreads, CrossThread *threads) {
    int code = 0;
    CrossThreadReturnValue value = 0;
    for (int32_t i = 0; i < nthreads; i++) {
        if (!threads[i].thread){
            continue;
        }
        if (CrossThread_Join(&threads[i], &value)) {
            code = 1;
        }
        if (!value) {
            code = 1;
        }
    }
    return code;
}

// static int applyOperation(
//     int (*operation)(void *arg, _Atomic(uint64_t) *progress), 
//     ThreadPoolArg arg, 
//     _Atomic(bool) *complete
// ) {
//     int return_code = operation(arg.data, arg.progress);
//     atomic_store_explicit(complete, true, memory_order_release);
//     return return_code;
// }

static int getFreeThread(size_t nthreads, const CrossThread threads[]) {
    for (size_t i = 0; i < nthreads; i++) {
        bool is_complete = atomic_load_explicit(&threads[i].complete, memory_order_acquire);
        if (is_complete) {
            return i;
        }
    }
    return -1;
}

static bool threadsFinished(size_t nthreads, const CrossThread threads[]) {
    for (size_t i = 0; i < nthreads; i++) {
        if (!atomic_load_explicit(&threads[i].complete, memory_order_acquire)) {
            return false;
        }
    }
    return true;
}

static int beginNewThread(
    CrossThread *thread, 
    PoolTarget operation, 
    ThreadPoolArg *arg
) {
    if (thread->thread) {
        if (CrossThread_Join(thread, NULL)) {
            return 1;
        }
    }
    if (CrossThread_Run(thread, (ThreadTarget)operation, arg)) {
        return 1;
    }
    return 0;
}

static int _applyThreadPool(
    int nthreads, 
    size_t narguments, 
    void *_args[], 
    PoolTarget operation, 
    _Atomic(uint64_t) *progress,
    PoolProgressReporter progress_reporter,
    CrossThread *threads,
    ThreadPoolArg *args
) {
    const uint64_t time_start = time_us();

    for (size_t i = 0; i < narguments; i++) {
        for (;;) {
            progress_reporter(progress, time_start);
            int index = getFreeThread(nthreads, threads);
            if (index != -1) {
                args[index].data = _args[i];
                if (beginNewThread(&threads[index], operation, &args[index])){
                    JoinSparseThreads(nthreads, threads);
                    return 1;
                }
                break;
            }
            sleep_ms(10);
        }
    }
    while (!threadsFinished(nthreads, threads)){
        progress_reporter(progress, time_start);
        sleep_ms(1);
    }
    if (JoinSparseThreads(nthreads, threads)) return 1;
    return 0;
}

int applyThreadPool(
    int nthreads, 
    size_t narguments, 
    void *_args[], 
    PoolTarget operation, 
    PoolProgressReporter progress_reporter
) {
    if ((!_args) || (!operation) || (!progress_reporter)) return 1;
    int code = 1;
    _Atomic(uint64_t) progress; 
    atomic_init(&progress, 0);
    CrossThread *threads = NULL;
    ThreadPoolArg *args = NULL;

    if (!(threads = calloc(nthreads, sizeof(CrossThread)))) goto END;
    if (!(args = calloc(nthreads, sizeof(ThreadPoolArg)))) goto END;

    for (size_t i = 0; i < nthreads; i++) {
        atomic_init(&threads[i].complete, true);
        args[i].progress = &progress;
    }

    if (_applyThreadPool(
        nthreads, 
        narguments, 
        _args, 
        operation, 
        &progress,
        progress_reporter, 
        threads, 
        args
    )) goto END;

    code = 0;
    END:
    if (threads) free(threads);
    if (args) free(args);
    return code;
}

int dbgThread(void *_arg, PoolTarget operation) {
    _Atomic(uint64_t) progress;
    atomic_init(&progress, 0);
    ThreadPoolArg arg = {.data = _arg, .progress = &progress};

    _Atomic(bool) complete;
    atomic_init(&progress, false);

    ThreadArg *args = malloc(sizeof(ThreadArg));
    if (!args) {
        PERROR(dbgThread);
        return 1;
    }
    args->arg = &arg;
    args->target = (ThreadTarget)operation;
    args->complete = &complete;
    if (applyFunction(args)) {
        ERROR("applying function caused and error");
        return 1;
    }
    return 0;

    // ThreadArg *args = malloc(sizeof(ThreadArg));
    // if (!args){
    //     return CrossThreadingFail;
    // }
    // args->arg = arg;
    // args->target = func;
    // args->complete = &thread->complete;
    // atomic_store(&thread->complete, false);
    // int resultCode = pthread_create(&thread->thread, NULL, applyFunction, args);
    // if (resultCode){
    //     perror("CreateCrossThread unable to create new thread: ");
    // }
    // return resultCode;
}


/*
//example

#include <timing.h>
#include <inttypes.h>

typedef struct {
    uint64_t x, y;
} ExArg;

CrossThreadReturnValue do_some_computation(ThreadPoolArg *arg) {
    ExArg *args = arg->data;
    for (size_t i = 0; i < 5000000; i++){
        volatile uint64_t z = args->x % args->y;
        volatile uint64_t k = args->x / (args->y + z);
        atomic_fetch_add(arg->progress, 1);
    }
    return 0;
}

void progress_printer(const _Atomic(uint64_t) *progress, uint64_t time_start) {
    uint64_t time_diff = time_us() - time_start;
    uint64_t current = atomic_load(progress);
    printf("\r%" PRIu64 " in %" PRIu64 "us  ", current, time_diff);
    fflush(stdout);
}

int main(void) {
    ExArg *args = calloc(200, sizeof(ExArg));
    for (uint64_t i = 0; i < 200; i++){
        args[i].x = i + 50;
        args[i].y = i * 2 + 60;
    }
    void **_args = calloc(200, sizeof(void *));
    for (size_t i = 0; i < 200; i++){
        _args[i] = &args[i];
    }
    applyThreadPool(10, 200, _args, do_some_computation, progress_printer);
    free(_args);
    free(args);
    printf("\ndone!\n");
    return 0;
}
*/
