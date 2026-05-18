#!/usr/bin/env python
import os
import random
import sys

if (seed := os.environ.get("PYTHONHASHSEED")) is not None:
    random.seed(seed)

DEFAULT_SIZE = 2000


def main():
    if len(sys.argv) > 1:
        N = int(sys.argv[1])
    else:
        N = DEFAULT_SIZE

    manyMerge = 1

    print("$...$...")

    for i in range(N):
        if random.randint(0, manyMerge) == 0:
            print(". ", end="")
        else:
            c = random.choices(range(1, i + 5), k=2)
            p1, p2 = c[0], c[1]
            if random.randint(0, 1) == 0 and p2 != 1:
                p1 = 1
            print(f"*{p1}/{p2} ", end="")


if __name__ == "__main__":
    main()
