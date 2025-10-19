#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>

#define AbandonedMutex 2
#define CrossThreadingFail 1
#define CrossThreadingSuccess 0

#if defined _WIN32
#include <windows.h>
typedef HANDLE ThreadHandle;
typedef DWORD CrossThreadReturnValue;
#elif defined __unix
#include <pthread.h>
typedef pthread_t ThreadHandle;
typedef void* CrossThreadReturnValue;
#else
#error "OS not supported"
#endif

typedef struct CrossThread {
    ThreadHandle thread;
    _Atomic(bool) complete;
} CrossThread;

typedef CrossThreadReturnValue (*ThreadTarget)(void *arg);

//so if you are used to the windows standard library then unfortunately you cannot
//seperate joining the thread and getting the return value with pthreads (the other threading library)
int CrossThread_Run(CrossThread *thread, ThreadTarget func, void *arg);
bool CrossThread_IsComplete(CrossThread *thread);
int CrossThread_Join(CrossThread *thread, CrossThreadReturnValue *returnValue);
//returnValues = ptr to return value pointers, which will be set to the exit/return values of the threads
//if returnValues == NULL the exit/return values will be discarded
//this function is required to close the threads on unix systems, and will also do so for windows
int JoinCrossThreads(int32_t numThreads, CrossThread *theads, CrossThreadReturnValue *returnValues);

typedef struct ThreadPoolArg { 
    void *data;
    _Atomic(uint64_t) *progress;
} ThreadPoolArg;

typedef CrossThreadReturnValue (*PoolTarget)(ThreadPoolArg *);
typedef void (*PoolProgressReporter)(const _Atomic(uint64_t) *progress, uint64_t time_start);

/**
 * Uses a threadpool to apply operation to each argument in args.
 * Operation recieves a ThreadPoolArg which has data = arg and an atomic progress counter that it should increment while running
 * The progress reporter also takes a reference to the progress counter, and should print the progress to the user
 */
int applyThreadPool(
    int nthreads, 
    size_t narguments, 
    void *_args[], 
    PoolTarget operation, 
    PoolProgressReporter progress_reporter
);

/**
 * Runs a PoolTarget on the current thread
 */
int dbgThread(void *_arg, PoolTarget operation);
