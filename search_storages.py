#!/usr/bin/env python3
"""Compatibility entry point for the maintained unified storage search command."""

import subprocess
import sys
from pathlib import Path

ROOT_DIR = Path(__file__).resolve().parent
raise SystemExit(
    subprocess.call(["bash", str(ROOT_DIR / "search-storages.sh"), *sys.argv[1:]])
)
