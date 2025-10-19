from __future__ import annotations
import json
import argparse
from typing import overload, Union
import numpy as np
import os

working_dir = os.path.split(__file__)[0]

number = Union[int, float]

bloon_data:dict

with open(os.path.join(working_dir, "bloonData.json")) as f:
    bloon_data = json.load(f)

freeplay_groups:list[dict]
with open(os.path.join(working_dir, "cleanedFreeplayGroups2.json")) as f:
    freeplay_groups = json.load(f)

class Calculator:
    @staticmethod
    def cash_multiplier(round:int) -> number:
        if round <= 50: return 1
        if round <= 60: return 0.5
        if round <= 85: return 0.2
        if round <= 100: return 0.1
        if round <= 120: return 0.05
        return 0.02
    @staticmethod
    def speed_multiplier(round:int) -> number:
        if round <= 80: return 1
        if round <= 100: return 1 + (round - 80) * 0.02
        if round <= 150: return 1.6 + (round - 101) * 0.02
        if round <= 200: return 3 + (round - 151) * 0.02
        if round <= 250: return 4.5 + (round - 201) * 0.02
        return 6 + (round - 252) * 0.02
    @staticmethod
    def health_multiplier(round) -> number:
        if round <= 80: return 1
        if round <= 100: return (round - 30) / 50
        if round <= 124: return (round - 72) / 20
        if round <= 150: return (3 * round - 320) / 20
        if round <= 250: return (7 * round - 920) / 20
        if round <= 300: return round - 208.5
        if round <= 400: return (3 * round - 717) / 2
        if round <= 500: return (5 * round - 1517) / 2
        return 5 * round - 2008.5
    @staticmethod
    def get_bloon_cash(bloon:str, round:int) -> number:
        freeplay = round > 80
        bloon = bloon.replace("Fortified", "").replace("Camo", "").replace("Regrow", "")
        mult = Calculator.cash_multiplier(round)
        data = bloon_data[bloon]
        if data['isMoab']:
            return mult * data['cash']
        return mult * data["superCash" if freeplay else "cash"]
    @staticmethod
    def get_RBE(bloon:str, round:int) -> int:
        health_mult = Calculator.health_multiplier(round)
        fortified = "Fortified" in bloon
        freeplay = round > 80
        bloon = bloon.replace("Fortified", "").replace("Camo", "").replace("Regrow", "")
        moab = bloon_data[bloon]
        if fortified:
            health_mult *= 2
            #print(f"mult: {health_mult}")
            ceramic_health = bloon_data['CeramicFortified']["superRBE" if freeplay else "RBE"]
        else:
            ceramic_health = bloon_data['Ceramic']["superRBE" if freeplay else "RBE"]
        if moab['isMoab']:
            return (moab['sumMoabHealth'] * health_mult +
                    moab['numCeramics'] * ceramic_health)
        bloon_d:dict = bloon_data[bloon + ("Fortified" if fortified else "")]
        return bloon_d["superRBE" if freeplay else "RBE"]

class seeded_random:
    def __init__(self, seed: int):
        self.seed = seed
    @overload
    def get_next_seed(self, bounds: tuple[int, int]) -> int: ...
    @overload
    def get_next_seed(self, bounds = None) -> float: ...
    def get_next_seed(self, bounds: tuple[int, int] | None = None):
        if bounds is None:
            return self._get_next_seed()
        min_, max_ = bounds
        if type(min_) is int and type(max_) is int:
            return self._get_next_seed_bounded(min_, max_)
        raise TypeError("min and max must be both ints or both None")
    def _get_next_seed(self):
        self.seed = (self.seed * 0x41a7) % 0x7FFFFFFF
        value = self.seed / np.float32(0x7FFFFFFE)
        return float(value)
    def _get_next_seed_bounded(self, min_:int, max_:int):
        if min_ == max_:
            return max_
        inv_range = min_ - max_
        self.seed = (self.seed * 0x41a7) % 0x7FFFFFFF
        shift = self.seed % inv_range
        if shift == 0:
            shift += inv_range
        return max_ + shift


def format_group(i:int, obj:dict) -> str:
    group = obj["group"]
    return f"| {group['bloon']:<16} |{i:<5}|{group['count']:<10} |{group['end']:<16} |"

def shuffle_seeded(l:list, seed: int):
    rand = seeded_random(seed)
    list_len:int = len(l) - 1
    i:int = list_len
    while True:
        value = rand.get_next_seed()
        index = int(list_len * value)
        l[i], l[index] = l[index], l[i]
        i -= 1
        if (i < 0):
            return l

def shuffle_in_place(l:list, seed: int):
    rand = seeded_random(seed)
    list_len:int = len(l)
    for i in range(list_len):
        index = rand.get_next_seed((i, list_len))
        l[i], l[index] = l[index], l[i]
    return 

def shuffle_rand_in_place(l:list, rand:seeded_random):
    list_len:int = len(l)
    for i in range(list_len):
        index = rand.get_next_seed((i, list_len))
        l[i], l[index] = l[index], l[i]
    return l

def get_budget(round:int):
    if round > 100:
        return np.float32(round * 4000 - 225000)
    budget = round ** 7.7
    helper = round ** 1.75
    if round > 50:
        return np.float32(budget * 5e-11 + helper + 20)
    return np.float32(((1 + round * 0.01) * (round * -3 + 400) * ((budget * 5e-11 + helper + 20) / 160) * 0.6))

def get_score(model:dict, round:int) -> number:
    bloon:str = model["group"]["bloon"]
    count:int = model["group"]["count"]
    mult:float = 1.0
    if "Camo" in bloon:
        mult += 0.1
        bloon = bloon.replace("Camo", "")
    if "Regrow" in bloon:
        mult += 0.1
        bloon = bloon.replace("Regrow", "")
    RBE:number = Calculator.get_RBE(bloon, round) * mult * count
    if count == 1: return RBE
    spacing:float = model["group"]["end"] / (60 * count)
    if spacing >= 1: return 0.8 * RBE
    if spacing >= 0.5: return RBE
    if spacing > 0.1: return 1.1 * RBE
    if spacing > 0.08: return 1.4 * RBE
    return 1.8 * RBE

def process_rounds(seed:int, start:int, end:int, printall:bool, printtotal:bool) -> tuple[number,number,number,number,number]:
    total_RBE:int = 0
    total_cash:float = 0.0
    total_time:int = 0
    total_fbads: int = 0
    total_bads: int = 0
    while start <= end:
        rand = seeded_random(seed + start)
        test_groups = list(range(529))
        shuffle_rand_in_place(test_groups, rand)
        if start > 1:
            mult = np.float32(1.5) - np.float32(rand.get_next_seed())
            if seed == 101 and start == 160:
                print(mult)
            budget = get_budget(start) * mult
        else:
            budget = get_budget(start)
        original_budget = budget
        round_RBE = 0
        round_cash = 0.0
        round_time = 0
        round_fbads = 0
        round_bads = 0
        if printall:
            print("+"+"-"*54+"+")
            print(f"| ROUND {start:<46} |")
            print(f"+{'-'*18}+{'-'*17}+{'-'*17}+")
            print(f"|{' '*12}Bloon |Group|     Count |{' '*10}Length |")
            print(f"+{'-'*18}+{'-'*17}+{'-'*17}+")
        for i in test_groups:
            obj:dict = freeplay_groups[i]
            bounds:list = obj["bounds"]
            for j in range(len(bounds)):
                if bounds[j]["lowerBounds"] <= start <= bounds[j]["upperBounds"]:
                    break
            else:
                continue
            score = np.float32(get_score(obj, start) if obj['score'] == 0 else obj['score'])
            if score > budget: continue
            if i == 470:
                pass
            bloon:str = obj["group"]["bloon"]
            count:int = obj["group"]["count"]
            round_RBE += Calculator.get_RBE(bloon, start) * count
            round_cash += Calculator.get_bloon_cash(bloon, start) * count
            round_time += obj["group"]["end"]
            if "Bad" in bloon:
                if "Fortified" in bloon:
                    round_fbads += count
                else:
                    round_bads += count
            budget -= score
            if printall:
                print(format_group(i, obj))
        if printall:
            print("+"+"-"*54+"+")
            print(f"| {f'Score budget: {original_budget-budget:,.2f}/{original_budget:,.2f}':<52} |")
            print(f"| {f'Round RBE: {round_RBE:,}':<52} |")
            print(f"| {f'Round Cash: {round_cash:,.2f}':<52} |")
            print(f"| {f'Round Length: {round_time:,}':<52} |")
            print(f"| {f'Health Multiplier: {Calculator.health_multiplier(start)}':<52} |")
            print(f"| {f'Speed Multiplier: {Calculator.speed_multiplier(start)}':<52} |")
        start += 1
        total_cash += round_cash
        total_RBE += round_RBE
        total_time += round_time
        total_bads += round_bads
        total_fbads += round_fbads
    if printtotal:
        print(f"+{'-'*24}TOTAL{'-'*25}+")
        print(f"| {f'Total RBE: {total_RBE:,}':<52} |")
        print(f"| {f'Total Cash: {total_cash:,.2f}':<52} |")
        print(f"| {f'Total Time: {total_time:,}':<52} |")
        print("+"+"-"*54+"+")
    return total_RBE, total_cash, total_time, total_fbads, total_bads

from tqdm import tqdm
def err_test():
    max_error = 0
    max_error_percent = 0
    for seed in tqdm(range(1_000_001_000), ascii=True):
        rand = seeded_random(seed)
        test_groups = list(range(529))
        shuffle_rand_in_place(test_groups, rand)
        mult = 1.5 - rand.get_next_seed()
        bits = 12
        if mult == 1:
            mult = 0.99999
        imult = int(mult / 1.5 * (2 ** bits))
        err = mult - imult / (2 ** bits) * 1.5
        percent = 100 * err / mult
        #print("error: ", err)
        if abs(err) > max_error:
            max_error = abs(err)
            print(f"max error: {max_error:.10f}, % = {percent:.10f}, seed ({seed})")
        if abs(percent) > max_error_percent:
            max_error_percent = percent
            print(f"error: {max_error:.10f}, max % = {percent:.10f}, seed ({seed})")
def main() -> None:
    process_rounds(154323, 501, 501, False, False)
    parser = argparse.ArgumentParser()
    parser.add_argument("seed", type=int)
    parser.add_argument("start", type=int)
    parser.add_argument("end", type=int)
    parser.add_argument("-t", "--total", action='store_true', help='show only the total results (hide the individual rounds)')
    args = parser.parse_args()
    SEED:int = args.seed
    START:int = args.start
    END:int = args.end
    process_rounds(SEED, START, END, not args.total, True)

if __name__ == "__main__":
    main()
