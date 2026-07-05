#!/usr/bin/env bash
#
# san_stress.sh — sanitizer-instrumented stress runs ("C-lite", see
# docs/DECISIONS.md's C-lite entry and docs/ZTEST.md §4's RESOLVED note).
#
# Runs the EXISTING test suites (test_repo.sh + test_workload.sh) against a
# TSan- or ASan-instrumented build of the C server, produced by
# `zig build -Dsan=<thread|address>`. This is orchestration only: no new test
# harness, no @cImport white-box layer (that stays parked per the C-lite
# ruling) -- just the black-box suites the repo already has, run against an
# instrumented binary instead of a plain one.
#
# Usage: test_scripts/san_stress.sh [thread|address] [STRESS_ITERS]
#   thread|address   which sanitizer to build with (default: thread)
#   STRESS_ITERS     how many times to loop conflict_stress_mix (default: 5)
#
# Must be run from the repo root, inside `nix develop` (or an equivalent
# shell already providing zig, python3+toml, and netstat -- the same
# precondition test_repo.sh itself has). This script does not wrap itself in
# nix-shell/nix develop.
#
# CI (.github/workflows/ci.yml `sanitizers` job) runs this with `thread`
# only. TSan is the genuinely new coverage here: it can observe the
# happens-before relationships the black-box suites can't (a race that
# doesn't happen to perturb response ordering is invisible to
# sherlock/watson). ASan stays a local/manual tool, not a CI gate: memory
# safety is already gated by valgrind in M4 (0 definite/indirect leaks,
# documented in docs/STATE.md); this ASan pass is a second detector for the
# same class of bug (plus a few ASan catches valgrind is weaker on, like
# stack-buffer-overflow and use-after-return), not new required coverage, so
# it isn't worth a second CI job/timeout budget.
#
# Note on TSan vs. flock: the per-URI locking in src/httpserver.c is `flock`
# on sidecar lockfiles (DECISIONS.md D12), which TSan does not model as a
# synchronization primitive (it only understands pthread mutexes/condvars/
# semaphores/atomics). That's expected and fine here: flock's critical
# sections protect FILE contents via syscalls (open/ftruncate/read/write on
# the target file), not shared *memory*, so there is nothing for TSan to
# racily observe there in the first place. The memory TSan actually needs to
# reason about (threadpool/queue shared state, the log module's mutex) is
# guarded by real pthread primitives -- so a clean TSan run is the
# expectation, not a formality (see docs/ZTEST.md's C-lite RESOLVED note).

set -u

SAN="${1:-thread}"
STRESS_ITERS="${2:-5}"

if [[ "$SAN" != "thread" && "$SAN" != "address" ]]; then
    echo "usage: $0 [thread|address] [STRESS_ITERS]" >&2
    echo "  got san='$SAN' (must be 'thread' or 'address')" >&2
    exit 1
fi

if ! [[ "$STRESS_ITERS" =~ ^[0-9]+$ ]] || [[ "$STRESS_ITERS" -lt 1 ]]; then
    echo "usage: $0 [thread|address] [STRESS_ITERS]" >&2
    echo "  got STRESS_ITERS='$STRESS_ITERS' (must be a positive integer)" >&2
    exit 1
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 1

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/san_stress.XXXXXX")"
backup=""
staged=0

cleanup() {
    # Only touch ./httpserver if we actually staged the instrumented binary
    # in its place -- if `zig build` itself failed we haven't touched it yet,
    # and blindly rm'ing/mv'ing here could destroy a pre-existing binary that
    # was never ours to manage.
    if [[ "$staged" -eq 1 ]]; then
        if [[ -n "$backup" ]]; then
            mv -f "$backup" ./httpserver
        else
            rm -f ./httpserver
        fi
    fi
    rm -rf "$tmpdir"
}
trap cleanup EXIT

echo "== building instrumented server: zig build -Dsan=$SAN =="
if ! zig build -Dsan="$SAN"; then
    echo "FAIL: zig build -Dsan=$SAN failed" >&2
    exit 1
fi

if [[ -f ./httpserver ]]; then
    backup="$tmpdir/httpserver.orig"
    cp ./httpserver "$backup"
fi
cp zig-out/bin/httpserver ./httpserver
staged=1

report_glob=""
case "$SAN" in
    thread)
        # halt_on_error=0: races are probabilistic: let the whole stress run
        # finish so one report doesn't hide others, and don't let it kill an
        # otherwise-fine run early. log_path routes reports to a file instead
        # of stderr, so they don't land in the audit log the harness captures
        # via `2>auditlog`.
        export TSAN_OPTIONS="log_path=$tmpdir/tsan-report halt_on_error=0"
        report_glob="$tmpdir/tsan-report.*"
        ;;
    address)
        # detect_leaks=0: the server's SIGTERM/SIGINT handler shuts down via
        # _exit() (docs/DECISIONS.md D13/D17 -- async-signal-safe, no atexit
        # hooks run), and every test-harness script in test_scripts/ tears
        # the server down with `kill -9` regardless (never a graceful
        # signal), so LeakSanitizer's atexit-based check essentially never
        # gets a chance to run either way. On the one path where it could
        # (an early opt_parse failure exiting via `exit()`), it would just
        # re-flag the same threadpool/queue allocations valgrind's M4 run
        # already classified as benign (still-reachable/possibly-lost, not
        # definite/indirect -- see docs/STATE.md's M4 acceptance). Leak
        # accounting stays valgrind's job (it already covers it properly);
        # this ASan pass is for memory-safety (overflow/UAF/double-free/
        # etc.), where the default halt_on_error=1 is fine -- unlike a race,
        # a memory-safety violation is deterministic at the buggy access, so
        # there's no stress-coverage reason to keep going past the first one.
        export ASAN_OPTIONS="log_path=$tmpdir/asan-report detect_leaks=0"
        report_glob="$tmpdir/asan-report.*"
        ;;
esac

overall_rc=0

echo "== full ./test_repo.sh =="
if ! ./test_repo.sh; then
    echo "FAIL: test_repo.sh reported failures" >&2
    overall_rc=1
fi

echo "== looping conflict_stress_mix x$STRESS_ITERS =="
for ((i = 1; i <= STRESS_ITERS; i++)); do
    echo "--- conflict_stress_mix iteration $i/$STRESS_ITERS ---"
    if ! test_scripts/test_workload.sh workloads/conflict_stress_mix.toml 4; then
        echo "FAIL: conflict_stress_mix iteration $i failed" >&2
        overall_rc=1
    fi
done

shopt -s nullglob
reports=($report_glob)
shopt -u nullglob
if [[ "${#reports[@]}" -gt 0 ]]; then
    echo "FAIL: sanitizer report(s) found:" >&2
    for r in "${reports[@]}"; do
        echo "---- $r ----" >&2
        cat "$r" >&2
    done
    overall_rc=1
fi

if [[ "$overall_rc" -eq 0 ]]; then
    echo "san_stress ($SAN, $STRESS_ITERS iters): PASS -- suites green, zero sanitizer reports"
else
    echo "san_stress ($SAN, $STRESS_ITERS iters): FAIL" >&2
fi

exit "$overall_rc"
