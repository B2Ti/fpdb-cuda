#pragma once

#include <cuda_runtime.h>
#include <device_launch_parameters.h>

typedef unsigned char Byte;


// __host__ __device__
// Byte bitGet(const Byte* bytes, const size_t idx);

__host__ __device__
void bitSet(Byte* bytes, const size_t idx, bool value);

#ifdef BITS_ARRAY_H_IMPL
#undef BITS_ARRAY_H_IMPL

// __host__ __device__
// Byte bitGet(const Byte* bytes, const size_t idx){
//     return (bytes[idx >> 3] >> (idx & 0x7)) & 1;
// }

__host__ __device__
void bitSet(Byte* bytes, const size_t idx, bool value){
    if (value) bytes[idx / 8] |= (1 << (idx % 8));
    else bytes[idx / 8] &= ~(1 << (idx % 8));
}

#endif
