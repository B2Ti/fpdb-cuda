//c++ testThreadPool.cpp src/thread_pool.cpp -o testThreads.out -I include
#include <thread_pool.hpp>
#include <chrono>
#include <thread>
#include <iostream>
#include <mutex>

std::mutex lock;

void work(int loops, double seconds) {
    std::chrono::duration<double> duration(seconds);
    for (int i = 0; i < loops; i++) {
        std::this_thread::sleep_for(duration);
        {
            std::lock_guard<std::mutex> guard(lock);
            std::cout << "Done some work: " << i << std::endl;
        }
    }
}

int main() {
    ThreadPool pool(25);
    for (size_t i = 0; i < 100; i++) {
        Thread &t = pool.waitForThread();
        t.run(work, 5, 1.0);
    }
    pool.joinAll();
}