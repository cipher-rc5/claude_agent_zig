#!/usr/bin/env python3
"""Opt-in real CLI matrix; use --prepare or --check-auth without model calls."""

import sys
from live_matrix import main

if __name__ == "__main__":
    sys.exit(main())
