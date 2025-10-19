cmake_minimum_required(VERSION 3.15)
project(MyZstdProject LANGUAGES CXX CUDA)

set(CMAKE_CXX_STANDARD 17)

include(FetchContent)

find_package(zstd 1.5.7 QUIET)

if (NOT zstd_FOUND)
    message(STATUS "zstd 1.5.7 not found on system, fetching it from GitHub...")

    FetchContent_Declare(
        zstd
        GIT_REPOSITORY https://github.com/facebook/zstd.git
        GIT_TAG v1.5.7
        SOURCE_SUBDIR build/cmake
    )
    FetchContent_MakeAvailable(zstd)
endif()

set(ZSTD_BUILD_SHARED ON)
set(ZSTD_BUILD_STATIC OFF)
set(ZSTD_BUILD_PROGRAMS OFF)

# file(GLOB SOURCE_FILES "src/*.c")

# add_library(fpdb_source OBJECT "${SOURCE_FILES}")
# target_include_directories(fpdb_source PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
# target_include_directories(fpdb_source PUBLIC ${zstd_SOURCE_DIR}/lib)

# add_executable(database database/main.c)

# set(ZSTD_BUILD_SHARED ON)
# set(ZSTD_BUILD_STATIC OFF)
# set(ZSTD_BUILD_PROGRAMS OFF)

# target_include_directories(database PRIVATE ${zstd_SOURCE_DIR}/lib)
# target_link_libraries(database PRIVATE libzstd_shared)
# target_link_libraries(database PRIVATE fpdb_source)

