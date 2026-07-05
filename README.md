# HTTP-C

A multi-threaded HTTP/1.1 static file server written in C (POSIX), with a Zig
build/test layer and a benchmark + differential-testing harness that pits it
against nginx.

The server speaks a small, well-defined slice of HTTP: `GET` (serve a file) and
`PUT` (write a file), one request per connection, with a per-URI-locked
**audit log** whose ordering is a valid linearization of the requests.

## Multi-threading design

A worker thread pool manages parallelization. `-t N` creates **N worker
threads**; the main thread is the dispatcher (it accepts connections and hands
each to the pool). So the process runs **N workers + 1 dispatcher = N+1 OS
threads**. `-t` defaults to 3 workers (4 OS threads total). See
`docs/DECISIONS.md` D17 for the thread-count convention and the
`test_scripts/threads_custom.sh` gate.

## Build

```bash
make                 # build ./httpserver with the rubric flags
                     # (-Wall -Wextra -Werror -pedantic -std=gnu17)
make clean           # remove ./httpserver and *.o
make format          # clang-format src/*.c lib/*.h
```

Or via the Zig build (also builds the mock server, the ztest runner, and the
bench oracle):

```bash
zig build            # -> zig-out/bin/{httpserver,mock-httpserver,ztest-runner,bench-differential}
```

A Nix flake pins the whole toolchain (clang, zig 0.15, python+toml, valgrind,
nginx, oha, wrk, …). Everything below runs inside it:

```bash
nix develop          # enter the dev shell
nix develop -c <cmd> # run a single command in it
```

## Run

```bash
./httpserver [-t threads] [-l logfile] <port>
```

- `-t threads` — worker thread count (default 3).
- `-l logfile` — audit log destination (default: stderr).
- `<port>` — TCP port to listen on (32768–65535 in the test harness).

Example — listen on 8080 with 2 workers, audit log to a file:

```bash
./httpserver -t 2 -l audit.log 8080
```

The server serves files from its current working directory: `GET /foo.txt`
reads `./foo.txt`; `PUT /foo.txt` writes it (201 if new, 200 if it existed).

## Test

Correctness is checked black-box: drive the real server over TCP and verify its
audit log is a valid linearization (ordering) and reproduces the observed
response bytes (replay). Two parallel harnesses do this.

```bash
./test_repo.sh                       # bash+python: oliver -> sherlock -> watson
zig build test                       # ztest unit tests (TOML parser, audit checker)
zig build test-http                  # ztest workload suite vs the built-in mock
zig build test-http -- zig-out/bin/httpserver   # ... vs the real C server
```

Single workload, N threads:

```bash
test_scripts/test_workload.sh workloads/audit_mix.toml 4
```

Sanitizers (see `docs/DECISIONS.md` D20/D21):

```bash
nix develop -c test_scripts/san_stress.sh thread 10    # TSan (also in CI)
nix develop -c test_scripts/san_stress.sh address 2    # ASan (local only)
```

## Benchmark & differential (vs nginx)

`bench/` compares the server against nginx (the open-source baseline, configured
one-request-per-connection to match). All of it needs the Nix dev shell for
nginx/oha/wrk.

**Semantic differential** — replays the `audit_*` workloads against both servers
and checks they agree on observable HTTP semantics (status codes + GET body
bytes), with an allowlist for legitimate nginx-vs-httpserver divergences (e.g.
PUT-overwrite 200 vs 204, error-page bodies). The audit-log *linearizability*
guarantee is unique to this server, so it stays checked by the harnesses above;
this is the cross-implementation HTTP-semantics oracle.

```bash
nix develop -c bench/differential.sh                       # all audit_* fixtures
nix develop -c bench/differential.sh workloads/audit_put.toml
zig build differential -- <workload.toml> <hostA:portA> <hostB:portB> <serve_root>
```

**Benchmark** — throughput + latency for GET/PUT across a file-size ladder, with
two load generators: `oha --disable-keepalive` (true one-request-per-connection,
matching the server — the honest latency numbers) and `wrk` (peak throughput
ceiling; keep-alive on, so it reconnects against the server's close and logs
socket errors — reported, not hidden). Writes a comparison table to
`bench/results/<date>.md` (+ `.csv`).

```bash
nix develop -c bench/bench.sh
# tunables: REQS (oha total), CONC (concurrency), DUR (wrk seconds), THREADS
nix develop -c env REQS=20000 CONC=100 DUR=15 bench/bench.sh
```

Expect nginx to win GET throughput (sendfile zero-copy + event loop vs this
server's thread-per-connection read/write loop) — a legitimate architectural
gap. The point is a quantified, reproducible comparison plus proof the server's
HTTP semantics match a reference implementation.

## Repo layout

- `src/` — server implementation (connection, request, response, dispatch, threadpool)
- `lib/` — headers and helper modules (queue, listener, logging)
- `ztest/` — Zig black-box test layer (driver, audit checker, mock server)
- `test_scripts/` — bash+python harness (oliver/sherlock/watson) + sanitizer stress
- `workloads/` — TOML workload specifications
- `bench/` — nginx differential oracle + benchmark harness
- `docs/` — shared design docs (PLAN, STATE, ROADMAP, DECISIONS, REFERENCE)
