#!/usr/bin/env python3

import os
import sys

# We use this to check whether readdir is implemented correctly for fuse. scandir happens
# to call readdir, but if we need to test more libc functions, it would be better to
# directly call them

path = sys.argv[1] if len(sys.argv) > 1 else None
for item in sorted(os.scandir(path), key=lambda x: x.name):
    if item.is_symlink():
        kind = "l"
    elif item.is_dir(follow_symlinks=False):
        kind = "d"
    elif item.is_file(follow_symlinks=False):
        kind = "f"
    else:
        kind = "?"
    print(kind, item.name)
