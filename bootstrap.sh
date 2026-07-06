#!/usr/bin/env bash
#
# First-run setup for a fresh clone/extract: verify test_files/, check the
# toolchain, build, and run the test harness. Safe to re-run.
#
# large_binary.dat (1.1GB, pure `dd if=/dev/urandom` padding) is gitignored
# and excluded from archive transfers of this repo; this script regenerates
# it rather than shipping it.

set -e

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$repo_root"

# --- 1. test_files/ ----------------------------------------------------

expected_files=(
    test_files/antihero.txt
    test_files/frankenstein.txt
    test_files/ipanema.txt
    test_files/large_ascii.txt
    test_files/large_binary.dat
    test_files/medium_ascii.txt
    test_files/medium_binary.dat
    test_files/small_ascii.txt
    test_files/small_binary.dat
    test_files/summertime.txt
    test_files/unforgettable.txt
    test_files/wonderful.txt
)

large_binary=test_files/large_binary.dat
large_binary_bytes=$((1100 * 1024 * 1024))

echo "==> Verifying test_files/"

for f in "${expected_files[@]}"; do
    if [ "$f" = "$large_binary" ]; then
        continue
    fi
    if [ ! -f "$f" ]; then
        echo "Missing $f (git-tracked; restore it with 'git checkout -- $f')" >&2
        exit 1
    fi
done

if [ ! -f "$large_binary" ] || [ "$(stat -c %s "$large_binary" 2>/dev/null)" != "$large_binary_bytes" ]; then
    echo "Regenerating $large_binary ($((large_binary_bytes / 1024 / 1024))MiB, not shipped in the repo/archive)"
    dd if=/dev/urandom of="$large_binary" bs=1M count=1100 status=none
else
    echo "$large_binary already present ($large_binary_bytes bytes)"
fi

# --- 2. Environment ------------------------------------------------------

echo "==> Checking environment"

if command -v nix >/dev/null 2>&1; then
    if [ -z "$IN_NIX_SHELL" ]; then
        echo "Nix detected. Re-run this script inside the dev shell:" >&2
        echo "    nix develop -c ./bootstrap.sh" >&2
        exit 1
    fi
    echo "Running inside nix develop."
else
    missing=()
    for tool in make python3; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1 || command -v gcc >/dev/null 2>&1 \
        || missing+=("a C compiler (cc/clang/gcc)")
    command -v ss >/dev/null 2>&1 || command -v netstat >/dev/null 2>&1 || missing+=("ss or netstat")
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "import toml" >/dev/null 2>&1 || missing+=("python3 'toml' module")
    fi

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "No nix on PATH, and missing tools:" >&2
        printf '  - %s\n' "${missing[@]}" >&2
        exit 1
    fi
    echo "No nix on PATH; found make/compiler/python3+toml/ss directly."
fi

# --- 3. Build ------------------------------------------------------------

echo "==> Building"
make

# --- 4. Test ---------------------------------------------------------------

echo "==> Running test suite"
./test_repo.sh

echo "==> Bootstrap complete: ./httpserver built, test_repo.sh gates passed."
