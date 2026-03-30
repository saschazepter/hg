import os
import sys


def main():
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <file>", file=sys.stderr)
        sys.exit(1)

    path = sys.argv[1]

    try:
        fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.close(fd)
        created = True
    except FileExistsError:
        created = False

    try:
        t0 = os.stat(path).st_mtime
        while True:
            os.utime(path)
            if os.stat(path).st_mtime != t0:
                break
    finally:
        if created:
            os.unlink(path)


if __name__ == "__main__":
    main()
