#include <stdlib.h>
#include <stdbool.h>
#include <compressedFile.hpp>
#include <err_io.h>
#include <stdexcept>
#include <system_error>

static FILE *fileopen(const char *filename, const char *mode){
    FILE *file;
    #ifdef _MSC_VER
        errno_t err = fopen_s(&file, filename, mode);
        if (err){
            file = NULL;
        }
    #else
        file = fopen(filename, mode);
    #endif
    return file;
}


#if defined _WIN32

#include <windows.h>
#include <conio.h>

int ensureDirectoryExists(const char *path){
    DWORD attrs = GetFileAttributesA(path);
    if (attrs == INVALID_FILE_ATTRIBUTES){
        if (CreateDirectoryA(path, NULL)){
            return 0;
        } else {
            //creation failed
            fprintf(stderr, "ensureDirectoryExists: CreateDirectoryA returned with error code: %lu\n", GetLastError());
            return FILE_FAIL;
        }
    }
    if (attrs & FILE_ATTRIBUTE_DIRECTORY){
        return 0;
    }
    fprintf(stderr, "ensureDirectoryExists: could not create directory\n");
    //something else already exists with the same name
    return FILE_FAIL;
}

int32_t getInput(void) {
    if (_kbhit()) {
        return _getch();
    }
    return EOF;
}

#elif defined __unix || defined __APPLE__

#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>
#include <unistd.h>
#include <termios.h>
#include <fcntl.h>
#include "compressedFile.hpp"

int ensureDirectoryExists(const char *path) {
    struct stat st;

    if (stat(path, &st) == 0) {
        if (S_ISDIR(st.st_mode)) {
            return 0;
        } else {
            fputs("cannot create directory; file exists with the same name\n", stderr);
            return 1;
        }
    }

    if (errno != ENOENT) {
        perror("stat");
        return 1;
    }

    if (mkdir(path, 0755) == 0) {
        return 0;
    } else {
        perror("mkdir");
        return 1;
    }
}

int32_t getInput(void) {
    struct termios oldt, newt;
    int32_t ch;
    int oldf;
    
    //store terminal settings and make getchar non blocking
    tcgetattr(STDIN_FILENO, &oldt);
    newt = oldt;
    newt.c_lflag &= ~(ICANON | ECHO);
    tcsetattr(STDIN_FILENO, TCSANOW, &newt);
    oldf = fcntl(STDIN_FILENO, F_GETFL, 0);
    fcntl(STDIN_FILENO, F_SETFL, oldf | O_NONBLOCK);

    ch = getchar();

    //restore previous terminal settings
    tcsetattr(STDIN_FILENO, TCSANOW, &oldt);
    fcntl(STDIN_FILENO, F_SETFL, oldf);

    return ch; //if ch == EOF return EOF is redunant
}

#else
#error "OS not supported"
#endif

CompressedFile::CompressedFile(CompressedFile_Mode mode, const char *path, size_t buffer_size):
    temp_buffer(),
    cctx(nullptr),
    dctx(nullptr),
    file(nullptr),
    mode(mode),
    buffer(buffer_size)
{
    switch (mode) {
        case (CompressedFile_ModeRead): {
            dctx = ZSTD_createDCtx();
            if (!dctx) {
                throw std::runtime_error("ZSTD_createDCtx failed");
            }
            if (path) {
                file = fopen(path, "rb");
                if (!file) {
                    ZSTD_freeDCtx(dctx);
                    throw std::system_error(errno, std::generic_category(), "Failed to open file");
                }
            }
        } break;
        case (CompressedFile_ModeWrite): {
            cctx = ZSTD_createCCtx();
            if (!cctx) {
                throw std::runtime_error("ZSTD_createCCtx failed");
            }
            if (path) {
                file = fopen(path, "wb");
                if (!file) {
                    ZSTD_freeCCtx(cctx);
                    throw std::system_error(errno, std::generic_category(), "Failed to open file");
                }
            }
        } break;
    }
}

CompressedFile::CompressedFile(CompressedFile&& other) noexcept:
    temp_buffer(std::move(other.temp_buffer)),
    cctx(other.cctx),
    dctx(other.dctx),
    file(other.file),
    mode(other.mode),
    buffer(std::move(other.buffer))
{
    other.cctx = nullptr;
    other.dctx = nullptr;
    other.file = nullptr;
}

CompressedFile::~CompressedFile() {
    int error = 0;
    if (cctx) error |= ZSTD_isError(ZSTD_freeCCtx(cctx));
    if (dctx) error |= ZSTD_isError(ZSTD_freeDCtx(dctx));
    if (file) error |= fclose(file);
    if (error) {
        fprintf(stderr, "CompressedFile destructuror failed to free resources");
    }
}

void CompressedFile::openFile(const char *path) {
    if (file) {
        if (fclose(file)) {
            file = nullptr;
            throw std::system_error(errno, std::generic_category(), "fclose returned an error code");
        }
    }
    file = fopen(path, (mode == CompressedFile_ModeRead) ? "rb" : "wb");
    if (!file) {
        throw std::system_error(errno, std::generic_category(), "Failed to open file");
    }
}

void CompressedFile::changeMode(const char *path, CompressedFile_Mode new_mode) {
    int error = 0;
    if (cctx) error |= ZSTD_isError(ZSTD_freeCCtx(cctx));
    if (dctx) error |= ZSTD_isError(ZSTD_freeDCtx(dctx));
    if (error) {
        throw std::runtime_error("ZSTD freeing CCtx/DCtx failed");
    }
    mode = new_mode;
    openFile(path);
}

void CompressedFile::writeBuffer(const int compression_level) {
    if (mode != CompressedFile_ModeWrite) {
        throw std::runtime_error("File must be in write mode");
    }
    size_t current_bytes = buffer.size();
    size_t bytes_out = ZSTD_compressBound(current_bytes);
    if (ZSTD_isError(bytes_out)) {
        throw std::runtime_error("ZSTD_compressBound returned an error");
    }
    if (temp_buffer.capacity() < bytes_out) {
        temp_buffer.reserve(bytes_out);
    }
    Byte *input = buffer.data();
    size_t input_size = buffer.size();
    Byte *output = temp_buffer.data();
    size_t output_size = temp_buffer.capacity();
    size_t compressed_len = ZSTD_compressCCtx(cctx, output, output_size, input, input_size, compression_level);
    if (ZSTD_isError(compressed_len)) {
        throw std::runtime_error("ZSTD_compressCCtx returned an error");
    }
    if (fwrite(&compressed_len, sizeof(size_t), 1, file) != 1) {
        throw std::system_error(errno, std::generic_category(), "fwrite returned an error");
    }
    if (fwrite(output, 1, compressed_len, file) != compressed_len) {
        throw std::system_error(errno, std::generic_category(), "fwrite returned an error");
    }
    buffer.clear();
}

void CompressedFile::loadBuffer() {
    if (mode != CompressedFile_ModeRead) {
        throw std::runtime_error("File must be in read mode");
    }
    size_t size;
    if (fread(&size, sizeof(size_t), 1, file) != 1) {
        throw std::system_error(errno, std::generic_category(), "fread returned an error");
    }
    if (temp_buffer.capacity() < size) {
        temp_buffer.reserve(size);
    }
    Byte *input = temp_buffer.data();
    if (fread(input, 1, size, file) != size) {
        throw std::system_error(errno, std::generic_category(), "fread returned an error");
    }
    size_t final_size = ZSTD_getFrameContentSize(input, size);
    if (buffer.capacity() < final_size) {
        buffer.reserve(final_size);
    }
    Byte *output = buffer.data();
    size_t output_size = buffer.capacity();
    size_t decompressed_len = ZSTD_decompressDCtx(dctx, output, output_size, input, size);
    if (ZSTD_isError(decompressed_len)) {
        throw std::runtime_error("ZSTD_compressDCtx returned an error");
    }
    buffer.resize(decompressed_len);
}

void CompressedFile::skipBuffer() {
    if (mode != CompressedFile_ModeRead) {
        throw std::runtime_error("File must be in read mode");
    }
    size_t size;
    if (fread(&size, sizeof(size_t), 1, file) != 1) {
        throw std::system_error(errno, std::generic_category(), "fread returned an error");
    }
    if (fseek(file, size, SEEK_CUR)) {
        throw std::system_error(errno, std::generic_category(), "fseek returned an error");
    }
}

void CompressedFile::push4_le(uint32_t value, size_t nbytes) {
    if (nbytes > 4) {
        throw std::runtime_error("nbytes must be less or equal to 4");
    }
    while (nbytes--) {
        buffer.push_back(value & 0xff);
        value >>= 8;
    }
}

void CompressedFile::push4_be(uint32_t value, size_t nbytes) {
    if (nbytes > 4) {
        throw std::runtime_error("nbytes must be less or equal to 4");
    }
    while (nbytes--) {
        buffer.push_back(value & (0xff << (8 * nbytes)));
    }
}
