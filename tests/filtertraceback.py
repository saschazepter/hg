#!/usr/bin/env python3

# Filters traceback lines from stdin.


import io
import sys

if sys.version_info[0] >= 3:
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

    elif state == 'file':
        # Ignore lines after "  File "
        state = 'tb'
        continue

    print(line, end='')
