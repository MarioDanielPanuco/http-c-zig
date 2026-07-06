# ztest

A Zig-native replacement for the bash+python test harness
(`test_scripts/{olivertwist,sherlock,watson}.py`, `test_repo.sh`), built as
milestone M6 of `docs/PLAN.md`. Talks raw TCP (not `std.http.Client`), so
malformed/partial requests stay expressible, and checks the audit log the
way sherlock (ordering) + watson (replay consistency) do together.

## Running it

From the repo root:

```bash
zig build test          # unit tests: TOML parser, audit-log checker
zig build test-http      # workload suite against the built-in Zig mock server
zig build test-http -- /path/to/httpserver   # ... against any server binary
HTTPSERVER_BIN=/path/to/httpserver zig build test-http -- ignored  # env var also works
```

`zig build test-http` with no `--` args defaults to the mock server at
`ztest/mock/main.zig` (built automatically), so the suite runs green with
zero setup even before the C server compiles.

It must be run from the repo root: it reads `workloads/*.toml` and
`test_files/*` relative to cwd, same precondition the bash harness has.

## What's implemented

- **`ztest/src/toml.zig`** — a hand-rolled parser for the tiny TOML subset
  `workloads/*.toml` actually uses (flat `[[events]]` tables, string/int
  values, `#` comments). Unit-tested, including a smoke pass over every
  real file in `workloads/`.
- **`ztest/src/wire.zig`** — HTTP/1.1 wire-format helpers (status-line /
  request-line / header parsing) shared by the driver and the mock server.
- **`ztest/src/events.zig`** — typed workload events: decodes the parsed
  `toml.Table` list into a validated `Event` union once (with defaults:
  `method="GET"`, `seconds=4`, `size=4096`), so the driver, the audit
  checks, and `bench/differential.zig` all switch on typed payloads. All
  Zig tools share ONE `ztest` module instance (see `build.zig`), which is
  also what lets the bench differential reuse `oliver.zig`'s Driver
  instead of carrying a copy.
- **`ztest/src/oliver.zig`** — the workload driver: opens raw TCP
  connections, replays `CREATE`/`SEND_LINE`/`SEND_HEADERS`/`SEND_BODY`/
  `SEND_ALL`/`RECV_PARTIAL`/`WAIT`/`LOAD`/`UNLOAD`/`SLEEP` events against a
  live server, and records the observed status code + response body per
  request id.
- **`ztest/src/audit.zig`** — `parseAuditLog` (well-formedness: exactly 4
  comma-separated fields, numeric status/rid, `Oper` matches the actual
  request method), `checkOrdering` (sherlock: is the audit log a valid
  linear extension of the partial order — if R2 only connected after R1's
  `WAIT` completed, R1 must be logged first?), and `checkReplay` (watson:
  replay `LOAD` + the GET/PUT sequence implied by the audit log's order
  into a fresh scratch filesystem, and check the resulting bodies match
  what the driver actually observed on the wire).
- **`ztest/src/main.zig`** (`ztest-runner`) — phase 1 smoke test (an
  embedded, hand-written PUT/PUT/GET/GET-missing sequence) plus phase 2:
  every workload `test_scripts/*.sh` exercises (see `WORKLOADS` in that
  file), each spawned against a fresh temp directory + a free port, with
  its stderr captured as the audit log.
- **`ztest/mock/main.zig`** — a minimal spec-following HTTP server (GET/PUT,
  per-URI locking, audit log, `Request-Id` capture) used to validate the
  runner itself independently of the C server. See its module doc comment for
  the response-body convention (reason phrase + `\n`, lifted from
  `old_proj_states/asgn2/response.c`, which is also what `watson.py`
  literally compares against).

## Known deviations from the Python reference

- **The driver is fully serial**, executing TOML events strictly in file
  order with blocking socket calls, whereas `olivertwist.py` additionally
  runs an opportunistic epoll-based background drain (`readem`) to cap
  open-fd count under `--maxreqs` and opportunistically pre-read responses.
  Neither changes anything sherlock/watson-observable: the ordering check
  only cares about explicit `CREATE`/`WAIT` events (which stay in file
  order here by construction, since ztest's driver doesn't reorder
  anything), and the replay check only cares about the final bytes each
  `WAIT` captured, not when they arrived. The workloads here are small
  enough (dozens of connections) that fd-capping doesn't matter either.
- **`block`/`SO_RCVBUF` tuning is not implemented.** `olivertwist.py` uses
  an artificially small `SO_RCVBUF` (the `block` field in some workloads)
  to force real TCP backpressure and pin a slow reader against a server
  worker. ztest's driver ignores that field; `RECV_PARTIAL`/`WAIT` still
  do the right blocking reads, so ordering/replay correctness is unaffected,
  but the *timing* characteristics of `*_pause_*` workloads may differ
  slightly from a run against the Python driver.
- **Because `checkOrdering`/`checkReplay` derive the partial order directly
  from the parsed workload** (not from a separately-recorded, timestamped
  send-log the way sherlock.py consumes olivertwist's own log), a
  precondition worth stating explicitly: this is only valid because the
  ztest driver is serial. If oliver.zig ever grows real concurrency
  (see below), this assumption needs revisiting -- the driver would need
  to record its own send-log the way olivertwist.py does.
- **The mock server is thread-per-connection, not a fixed `-t N` worker
  pool.** `-t` is accepted (for CLI compatibility) but doesn't bound
  concurrency, so the mock can't stand in for `test_scripts/threads_custom.sh`
  (which asserts the *exact* OS thread count). That check isn't
  implemented in ztest at all yet.
- **`APPEND`** (a method `watson.py`'s `Connect` class supports generically)
  is never used by any workload in `workloads/` and isn't implemented here.
- **Malformed workloads fail at decode time**, before any connection is
  opened (`events.decode` reports the event index and missing field),
  whereas olivertwist.py failed lazily mid-run. All checked-in workloads
  decode cleanly; `SLEEP` without `seconds` defaults to 4 everywhere
  (including the bench differential, which used to default to 0).

## Relationship to `docs/zig-interop.md`

That doc sketches a broader, complementary Zig test architecture: import
the C symbols directly via `@cImport` and run a seven-layer taxonomy
(L1 unit -> L7 soak) with ASan/TSan/UBSan wired through `zig cc`. It's a
white-box companion to this harness, not a replacement -- it needs the C
symbols (`conn_*`, `queue_*`, `threadpool_*`, ...) to actually exist and
link, which isn't true yet (see docs/PLAN.md's M1). What's done here from
that doc:

- `build.zig -Dsan=address|thread|undefined` instruments the C
  `httpserver` build with the requested sanitizer (its Level-0/1 adoption
  step) -- available now, useful the moment the C track's build succeeds.

What's still open (natural follow-ups once M1/M2 land on `main`):

- L1/L2 unit + memory-safety tests calling `conn_parse`/`response_get_code`/
  etc. directly via `@cImport`, once those symbols exist and are stable.
- L3 concurrency tests (atomic counters, threadpool no-task-loss/no-deadlock,
  logger race) under `-Dsan=thread` -- this is the layer ztest's own
  integration-style checks (ordering/replay) can't reach, since they only
  observe externally-visible behavior, not internal invariants.
- L6 fuzzing the request parser (`zig build test --fuzz`) and L7 soak runs.

This harness (`ztest/`) is deliberately the L4/L5-equivalent layer from
that taxonomy: real server, real sockets, real log verification -- just
built bottom-up from what `workloads/*.toml` already encode rather than
from scratch.

The white-box `@cImport` items above stayed a parked decision until
2026-07-04, when the user ruled a narrower path instead ("C-lite", see
`docs/DECISIONS.md` D20 and `docs/ZTEST.md` §4's RESOLVED note): rather than
build a new `@cImport` harness, `test_scripts/san_stress.sh` runs this
repo's *existing* black-box suites (`test_repo.sh` + a looped
`conflict_stress_mix` workload) against `zig build -Dsan=thread|address`
builds of the C server, with a TSan-only CI job. That also required fixing
`build.zig`'s `-Dsan=` toggle itself, which had only ever instrumented the C
*compile* step and never linked a sanitizer runtime. The white-box taxonomy
above is otherwise unchanged and still not built.

## Validated against

- The bundled mock server (`ztest/mock/main.zig`): full suite green,
  repeatable across multiple runs.
- The sibling main-tree checkout's `httpserver` (built via `make` there,
  read-only, once the C track had something that compiled): most workloads
  ran to completion and produced real, actionable findings -- e.g. this
  harness caught the audit log's `Oper` field containing the response
  message ("OK"/"Created"/"Bad Request") instead of the request method,
  and a PUT existed-check race producing 200/201 status mismatches against
  the replayed order. Both are genuine C-side bugs already tracked in
  `docs/PLAN.md`'s audit, not artifacts of this harness -- see the report
  this session wrote for the exact commands and output.
