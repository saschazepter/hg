#!/usr/bin/env python3

# Filter output by pyflakes to control which warnings we check


import re
import sys

lines = []
for line in sys.stdin:
    # We blacklist tests that are too noisy for us
    pats = [
        r"undefined name 'WindowsError'",
        r"redefinition of unused '[^']+' from line",
        # for cffi, allow re-exports from pure.*
        r"cffi/[^:]*:.*\bimport \*' used",
        r"cffi/[^:]*:.*\*' imported but unused",
        r"mercurial/interfaces/types.py:.+' imported but unused",
    ]

    keep = True
    for pat in pats:
        if re.search(pat, line):
            keep = False
            break  # pattern matches
    if keep:
        fn = line.split(':', 1)[0]
        with open(fn, 'rb') as f:
            data = f.read()
        if b'no-' b'check-code' in data:
            continue
        lines.append(line)

for line in lines:
    sys.stdout.write(line)
print()
