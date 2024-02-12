#!/usr/bin/env python3
#
# A tool to help producing large and poorly compressible files
#
# Usage:
#   $TESTDIR/seq.py 1000 | $TESTDIR/sha256line.py > my-file.txt


import hashlib
import sys


for line in sys.stdin:
    print(hashlib.sha256(line.encode('utf8')).hexdigest())
