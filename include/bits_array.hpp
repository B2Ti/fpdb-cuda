#pragma once
#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#ifndef ZCONF_H
 typedef unsigned char Byte;
#endif

__host__ __device__
static inline Byte bitGet(const Byte* bytes, const size_t idx){
    return (bytes[idx >> 3] >> (idx & 0x7)) & 1;
}

__host__ __device__
static inline void bitSet(Byte* bytes, const size_t idx, bool value){
    if (value) bytes[idx / 8] |= (1 << (idx % 8));
    else bytes[idx / 8] &= ~(1 << (idx % 8));
}
