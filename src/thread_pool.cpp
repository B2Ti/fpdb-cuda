#include <chrono>
#include <thread_pool.hpp>

using hr_clock = std::chrono::high_resolution_clock;

size_t size_t_or(size_t lhs, size_t rhs) noexcept {
    return (lhs != 0) ? lhs : rhs;
}

ThreadPool::ThreadPool()
    : ThreadPool(size_t_or(std::thread::hardware_concurrency(), 1)) {}

ThreadPool::ThreadPool(size_t n_threads):
    threads(n_threads)
{}

ThreadPool::ThreadPool(ThreadPool &&other)
    : threads(std::move(other.threads)) {}

std::optional<size_t> ThreadPool::waitForThreadIdx(
    size_t ms_timeout, size_t ms_loop_wait
) {
    auto duration = std::chrono::milliseconds(ms_timeout);
    auto wait = std::chrono::milliseconds(ms_loop_wait);

    auto begin = hr_clock::now();

    do {
        for (size_t i = 0; i < threads.size(); i++) {
            auto &thread = threads[i];
            if (thread.complete.load()) {
                return std::optional<size_t>(i);
            }
        }
        std::this_thread::sleep_for(wait);
    } while (hr_clock::now() - begin < duration);
    
    return std::optional<size_t>();
}

size_t ThreadPool::waitForThreadIdx() {
    auto wait = std::chrono::milliseconds(2);
    auto begin = hr_clock::now();
    for (;;) {
        for (size_t i = 0; i < threads.size(); i++) {
            auto &thread = threads[i];
            if (thread.complete.load()) {
                if (thread._thread.joinable()) {
                    thread._thread.join();
                }
                return i;
            }
        }
        std::this_thread::sleep_for(wait);
    }
}

std::optional<std::reference_wrapper<Thread>> ThreadPool::waitForThread(
    size_t ms_timeout, size_t ms_loop_wait
) {
    auto duration = std::chrono::milliseconds(ms_timeout);
    auto wait = std::chrono::milliseconds(ms_loop_wait);

    auto begin = hr_clock::now();

    do {
        for (auto &thread: threads) {
            if (thread.complete.load()) {
                return std::optional<std::reference_wrapper<Thread>>(
                    std::ref(thread)
                );
            }
        }
        std::this_thread::sleep_for(wait);
    } while (hr_clock::now() - begin < duration);

    return std::optional<std::reference_wrapper<Thread>>();
}

Thread &ThreadPool::waitForThread() {
    auto wait = std::chrono::milliseconds(2);
    auto begin = hr_clock::now();
    for (;;) {
        for (auto &thread: threads) {
            if (thread.complete.load()) {
                if (thread._thread.joinable()) {
                    thread._thread.join();
                }
                return thread;
            }
        }
        std::this_thread::sleep_for(wait);
    }
}

Thread &ThreadPool::getThread(size_t idx) {
    return threads[idx];
}

void ThreadPool::joinAll() {
    for (auto &thread: threads) {
        if (thread._thread.joinable()) {
            thread._thread.join();
        }
    }
}
