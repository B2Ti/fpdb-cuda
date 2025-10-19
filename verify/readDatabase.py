from __future__ import annotations
from typing import Literal
import zstd
import sys
import os
import ctypes
import numpy as np
from time import perf_counter as pfc

END_ROUND = 1000
START_ROUND = 141
CHUNK_SIZE = 100

class Results:
    bads: list[list[int]]
    fbads: list[list[int]]
    cash50: list[list[int]]
    def __init__(self, bads: list[list[int]], fbads: list[list[int]], cash50: list[list[int]]):
        self.bads = bads
        self.fbads = fbads
        self.cash50 = cash50
    def __eq__(self, other) -> bool:
        if type(other) != Results:
            return False
        return (
            self.bads == other.bads and 
            self.fbads == other.fbads and 
            self.cash50 == other.cash50
        )

def _bytesTo2dByteList(data: bytes, x: int, y: int) -> list[list[int]]:
    list_2d = []
    for i in range(y):
        idx = i * x
        row = list(data[idx: idx + x])
        list_2d.append(row)
    return list_2d

def bytesTo2dList(data: bytes, x: int, y: int, size: int) -> list[list[int]]:
    if (size == 1): return _bytesTo2dByteList(data, x, y)
    list_2d = []
    for i in range(y):
        row = []
        for j in range(x):
            idx = size * (i * x + j)
            value = int.from_bytes(data[idx: idx + size], "little")
            row.append(value)
        list_2d.append(row)
    return list_2d

def bytesTo2dListNp(data: bytes, x: int, y: int, size: Literal[1, 2, 4, 8]) -> list[list[int]]:
    dtype = {1: np.uint8, 2: np.uint16, 4: np.uint32, 8: np.uint64}[size]
    arr: np.ndarray = np.frombuffer(data, dtype=dtype)
    arr = arr.reshape((y, x))
    return arr.tolist()

def readChunk(chunk_num: int) -> Results:
    file, chunk = divmod(chunk_num, 1000)
    seed_str = f"{100_000 * file}-{100_000 * (1 + file)}"
    with open(f"database/bads_{seed_str}.bin", "rb") as f:
        for i in range(chunk):
            size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
            f.seek(size, os.SEEK_CUR)
        size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
        data = zstd.decompress(f.read(size))
    begin = pfc()
    bads = bytesTo2dList(data, END_ROUND - START_ROUND, CHUNK_SIZE, 1)
    end = pfc()
    # begin = pfc()
    # bads = []
    # for i in range(CHUNK_SIZE):
    #     round_bads = []
    #     for j in range(END_ROUND - START_ROUND):
    #         idx = i * (END_ROUND - START_ROUND) + j
    #         nbads = data[idx]
    #         round_bads.append(nbads)
    #     bads.append(round_bads)
    # end = pfc()
    print(f"took {end - begin}s")
    with open(f"database/fbads_{seed_str}.bin", "rb") as f:
        for i in range(chunk):
            size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
            f.seek(size, os.SEEK_CUR)
        size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
        data = zstd.decompress(f.read(size))
    fbads = bytesTo2dList(data, END_ROUND - START_ROUND, CHUNK_SIZE, 1)
    # fbads = []
    # for i in range(CHUNK_SIZE):
    #     round_fbads = []
    #     for j in range(END_ROUND - START_ROUND):
    #         idx = i * (END_ROUND - START_ROUND) + j
    #         nfbads = data[idx]
    #         round_fbads.append(nfbads)
    #     fbads.append(round_fbads)
    with open(f"database/cash_{seed_str}.bin", "rb") as f:
        for i in range(chunk):
            size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
            f.seek(size, os.SEEK_CUR)
        size = int.from_bytes(f.read(ctypes.sizeof(ctypes.c_size_t)), sys.byteorder)
        data = zstd.decompress(f.read(size))
    begin = pfc()
    cash50 = bytesTo2dListNp(data, END_ROUND - START_ROUND, CHUNK_SIZE, 4)
    end = pfc()
    # cash50 = []
    # for i in range(CHUNK_SIZE):
    #     round_cash50 = []
    #     for j in range(END_ROUND - START_ROUND):
    #         idx = i * (END_ROUND - START_ROUND) + j
    #         cash = int.from_bytes(data[4 * idx:4 + 4 * idx], "little")
    #         round_cash50.append(cash)
    #     cash50.append(round_cash50)
    print(f"took {end - begin}s")
    results = Results(bads, fbads, cash50)
    return results

def main() -> None:
    readChunk(0)

if __name__ == '__main__':
    main()
