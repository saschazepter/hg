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

state = 'none'

for line in sys.stdin:
    if state == 'none':
        if line.startswith('Traceback '):
            state = 'tb'

    elif state == 'tb':
        if line.startswith('  File '):
            state = 'file'
            continue

        elif not line.startswith(' '):
            state = 'none'

        elif not line.replace('^', '').replace('~', '').strip():
            # PEP 657: Fine-grained error locations in tracebacks
            #                       ~~~~~~^^^^^^^^^
            continue
        elif line.startswith(' '):
            # Python 3.13 provide de full statement context
            continue

    elif state == 'file':
        # Ignore one line after "  File ", but sometimes "File" lines are
        # contiguous:
        #      File "<frozen importlib._bootstrap>", line 1007, in _find_and_load
        #      File "<frozen importlib._bootstrap>", line 986, in _find_and_load_unlocked
        #      File "<frozen importlib._bootstrap>", line 680, in _load_unlocked
        if not line.startswith('  File '):
            state = 'tb'
        continue

    print(line, end='')
