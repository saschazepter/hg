#!/usr/bin/env python
"""
This simple script outputs a sequence of numbers separated by newlines. The
amount of numbers and their approximate values can be controlled by two command
line arguments.

Usage: $0 COUNT MAXADD. COUNT will determine the amount of numbers printed, and
MAXADD will limit the value that will be added to each of those numbers.
"""

from __future__ import print_function

import random
import sys


def main():
    count = int(sys.argv[1])
    maxadd = int(sys.argv[2])
    for x in range(count):
        print(x + random.randint(0, maxadd))


if __name__ == '__main__':
    main()
