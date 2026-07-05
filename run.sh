#!/usr/bin/env bash
#
# Convenience wrapper: format, build from clean, then run the full test harness.
# (Previously invoked a nonexistent ./load_repo.sh, which errored out silently
# in the middle of the script.)

set -e

make clean
make format
make

# Full harness (oliver -> sherlock -> watson plus the gate scripts). Requires
# python3+toml and netstat/ss on PATH; on this repo's dev box that is provided
# via: nix-shell -p python3 python3Packages.toml nettools unixtools.netstat
./test_repo.sh
