#pragma once

#include <atomic>
#include <optional>
#include <thread>
#include <utility>
#include <vector>

class Thread {
    template <typename Func, typename... Args>
    void _exec(Func func, Args &&...args) {
        func(std::forward<Args>(args)...);
        complete.store(true);
    }

   public:
    std::thread _thread;
    std::atomic<bool> complete;
    Thread() : _thread(), complete(true) {}
    template <typename Func, typename... Args>
    Thread(Func func, Args &&...args) {
        _thread = std::thread(_exec, func, std::forward(args)...);
    }
    Thread(const Thread &other) = delete;
    ~Thread() = default;
    template <typename Func, typename... Args>
    void run(Func func, Args &&...args) {
        complete.store(false);
        _thread = std::thread([=]() mutable {
            _exec(func, std::forward<Args>(args)...);
        });
    }
};

class ThreadPool {
    std::vector<Thread> threads;

   public:
    // Uses n_threads = number of cpu cores
    ThreadPool();
    ThreadPool(size_t n_threads);
    ThreadPool(const ThreadPool &other) = delete;
    ThreadPool(ThreadPool &&other);
    ~ThreadPool() = default;
    std::optional<size_t> waitForThreadIdx(
        size_t ms_timeout, size_t ms_loop_wait = 2
    );
    size_t waitForThreadIdx();
    std::optional<std::reference_wrapper<Thread>> waitForThread(
        size_t ms_timeout, size_t ms_loop_wait = 2
    );
    Thread &waitForThread();
    Thread &getThread(size_t idx);
    void joinAll();
};
