#!/usr/bin/env python3

# Filters traceback lines from stdin.


import io
import sys

# Prevent \r from being inserted on Windows.
sys.stdout = io.TextIOWrapper(
    sys.stdout.buffer,
    sys.stdout.encoding,
    sys.stdout.errors,
    newline="\n",
    line_buffering=sys.stdout.line_buffering,
)

in_tb = False

for line in sys.stdin:
    do_print = not in_tb
    if line.startswith('Traceback '):
        in_tb = True
    elif not line.startswith(' '):
        in_tb = False
        do_print = True
    if do_print:
        print(line, end='')
