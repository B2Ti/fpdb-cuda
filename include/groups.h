#pragma once

#include <stdint.h>
#include <stddef.h>
#include "bits_array.hpp"

#define NUM_GROUPS 529
#define NUM_BOUNDS 5

#define BAD_TYPE 136
#define FBAD_TYPE 140

typedef struct Group {
    float score;
    uint16_t type;
    uint16_t count;
    int32_t bounds[10];
} Group;

typedef struct BoundlessGroup {
    float score;
    uint16_t type;
    uint16_t count;
} BoundlessGroup;

Group getGroup(const size_t index);
BoundlessGroup* cudifyGroups(void);

Byte* makeGroupsArray(size_t maximumRound);
Byte* cu_makeGroupsArray(size_t maximumRound);
