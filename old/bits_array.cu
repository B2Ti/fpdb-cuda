#include <stdlib.h>
#include <bits_array.hpp>

#pragma message "Hello from bits array"

__host__ __device__
Byte bitGet(const Byte* bytes, const size_t idx) {
    return (bytes[idx >> 3] >> (idx & 0x7)) & 1;
}

__host__ __device__
void bitSet(Byte* bytes, const size_t idx, bool value) {
    if (value) bytes[idx / 8] |= (1 << (idx % 8));
    else bytes[idx / 8] &= ~(1 << (idx % 8));
}

