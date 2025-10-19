#pragma once

#include <stdexcept>

template<typename T>
T *cuda_new(size_t n, bool zero_init = false) {
    cudaError_t err;
    T *ptr;
    err = cudaMalloc(&ptr, n * sizeof(T));
    if (err != cudaSuccess) {
        std::string error = "cudaMalloc"; 
        throw std::runtime_error(error + cudaGetErrorString(err));
    }
    if (zero_init) {
        err = cudaMemset(ptr, 0, n * sizeof(T));
        if (err != cudaSuccess) {
            cudaFree(ptr);
            std::string error = "cudaMalloc"; 
            throw std::runtime_error(error + cudaGetErrorString(err));
        }
    }
    return ptr;
}

template<typename T>
void cuda_hostToDev(T *dev_dst, T *host_src) {
    cudaError_t err;
    T check;
    err = cudaMemcpy(dev_dst, host_src, sizeof(T), cudaMemcpyHostToDevice);
    if (err != cudaSuccess) {
        std::string error = "cudaMemcpy";
        throw std::runtime_error(error + cudaGetErrorString(err));
    }
    err = cudaMemcpy(&check, dev_dst, sizeof(T), cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) {
        std::string error = "cudaMemcpy";
        throw std::runtime_error(error + cudaGetErrorString(err));
    }
    if (*host_src != check) {
        throw std::runtime_error("Data structure is not aligned on host and device");
    }
}

template<typename T>
void cuda_devToHost(T *host_dst, T *dev_src) {
    cudaError_t err;
    err = cudaMemcpy(host_dst, dev_src, sizeof(T), cudaMemcpyDeviceToHost);
    if (err != cudaSuccess) {
        std::string error = "cudaMemcpy";
        throw std::runtime_error(error + cudaGetErrorString(err));
    }
}

void cuda_free(void *ptr) {
    cudaError_t err;
    err = cudaFree(ptr);
    if (err != cudaSuccess) {
        std::string error = "cudaFree";
        throw std::runtime_error(error + cudaGetErrorString(err));
    }
}
struct CudaDeleter {
    template<typename T>
    void operator()(T *dev_ptr) const {
        cudaFree(dev_ptr);
    }
};





