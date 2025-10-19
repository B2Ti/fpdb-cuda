#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <zstd.h>

#include <vector>

/**
 * checks if a directory exists, if it doesn't exist, create it
 * @returns 
 *  - 0 if the directory exists / has been created
 * 
 *  - 1 if the directory could not be created
 */
int ensureDirectoryExists(const char *path);

#ifndef ZCONF_H
 typedef unsigned char Byte;
#endif

typedef enum CompressedFile_Mode {
    CompressedFile_ModeRead,
    CompressedFile_ModeWrite,
} CompressedFile_Mode;

class CompressedFile {
    std::vector<Byte> temp_buffer;
    ZSTD_CCtx *cctx;
    ZSTD_DCtx *dctx;
    FILE *file;
    CompressedFile_Mode mode;
    public:
    std::vector<Byte> buffer;
    CompressedFile() = delete;
    CompressedFile(CompressedFile_Mode mode, const char *path = nullptr, size_t buffer_size = 0);
    CompressedFile(const CompressedFile &other) = delete;
    CompressedFile(CompressedFile &&other) noexcept;
    ~CompressedFile();
    void openFile(const char *path);
    void changeMode(const char *path, CompressedFile_Mode mode);
    void writeBuffer(const int compression_level);
    void loadBuffer();
    void skipBuffer();
    void push4_le(uint32_t value, size_t nbytes);
    void push4_be(uint32_t value, size_t nbytes);
};
