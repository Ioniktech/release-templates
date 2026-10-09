from __future__ import annotations

import sys

from . import __version__, greeting


def main(argv: list[str] | None = None) -> int:
    args = sys.argv[1:] if argv is None else argv

    if args and args[0] in ('-V', '--version'):
        print(__version__)
        return 0

    print(greeting(*args[:1]))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
