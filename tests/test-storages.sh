#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(dirname -- "$(readlink -f -- "$0")")"
exec python3 "$SCRIPT_DIR/test_storages.py"
