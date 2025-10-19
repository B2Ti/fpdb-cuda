from readDatabase import readChunk, Results
from computeCheck import simulateChunk

def findDiff(result1: Results, result2: Results) -> None:
    assert len(result1.bads) == len(result2.bads)
    for i in range(len(result1.bads)):
        assert len(result1.bads[i]) == len(result2.bads[i])
        for j in range(len(result1.bads[i])):
            if result1.bads[i][j] != result2.bads[i][j]:
                pass
    assert len(result1.fbads) == len(result2.fbads)
    for i in range(len(result1.fbads)):
        assert len(result1.fbads[i]) == len(result2.fbads[i])
        for j in range(len(result1.fbads[i])):
            if result1.fbads[i][j] != result2.fbads[i][j]:
                pass
    assert len(result1.cash50) == len(result2.cash50)
    for i in range(len(result1.cash50)):
        assert len(result1.cash50[i]) == len(result2.cash50[i])
        for j in range(len(result1.cash50[i])):
            if result1.cash50[i][j] != result2.cash50[i][j]:
                pass

def main() -> None:
    chunk_num = 1542
    results1 = readChunk(chunk_num)
    results2 = simulateChunk(chunk_num)
    findDiff(results1, results2)
    print("YES!")

if __name__ == '__main__':
    main()
