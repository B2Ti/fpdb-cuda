from readDatabase import Results
from FreeplayExplorer import process_rounds
from tqdm import tqdm

def simulateChunk(chunk_num: int):
    seed_begin = chunk_num * 100
    seed_end = (chunk_num + 1) * 100
    cash50 = []
    fbads = []
    bads = []
    for seed in tqdm(range(seed_begin, seed_end)):
        cash50_row = []
        fbads_row = []
        bads_row = []
        for round_ in range(141, 1000):
            _, cash, _, nfbads, nbads = process_rounds(seed, round_, round_, False, False)
            cash50_row.append(round(50 * cash))
            fbads_row.append(int(nfbads))
            bads_row.append(int(nbads))
        cash50.append(cash50_row)
        fbads.append(fbads_row)
        bads.append(bads_row)
    return Results(bads, fbads, cash50)

