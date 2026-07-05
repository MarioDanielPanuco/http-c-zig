#!/usr/bin/env bash
#
# Benchmark ./httpserver against nginx on GET and PUT across a file-size ladder,
# with two load generators:
#   oha  --disable-keepalive : TRUE one-request-per-connection, matching
#                              httpserver's close-per-request model -> honest
#                              latency percentiles (p50/p99).
#   wrk  --latency           : peak throughput ceiling. wrk keeps connections
#                              alive; against a close-per-request server it
#                              reconnects and logs socket errors -- captured in
#                              the table, not hidden. Read as "keep-alive-on".
#
# Output: bench/results/<date>.md (a comparison table) + a .csv. This is an
# informational harness -- CI runs it non-gating (runners are too noisy to
# threshold on).
#
# Usage:  bench/bench.sh
# Tunables (env): REQS (oha total), CONC (concurrency), DUR (wrk seconds),
#                 THREADS (server workers + wrk threads).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
source "$repo/test_scripts/utils.sh"
cd "$repo"

REQS="${REQS:-5000}"
CONC="${CONC:-50}"
DUR="${DUR:-10}"
THREADS="${THREADS:-4}"

for tool in oha wrk; do
    command -v "$tool" >/dev/null || { echo "$tool not found (need it for bench)" >&2; exit 1; }
done
nginx_bin="$(command -v nginx || echo /usr/sbin/nginx)"
[[ -x "$nginx_bin" ]] || { echo "nginx not found" >&2; exit 1; }
[[ -x ./httpserver ]] || make >/dev/null || { echo "make failed" >&2; exit 1; }

root="$(mktemp -d)"
mkdir -p "$root/.client_temp" "$root/.proxy_temp" "$root/.fastcgi_temp" \
         "$root/.uwsgi_temp" "$root/.scgi_temp"
trap 'rm -rf "$root"' EXIT

# GET fixtures + PUT bodies: small/med/large.
declare -A sizes=( [small]=1024 [med]=65536 [large]=1048576 )
for name in "${!sizes[@]}"; do
    head -c "${sizes[$name]}" /dev/urandom > "$root/get_$name.dat"
    head -c "${sizes[$name]}" /dev/urandom > "$root/body_$name.dat"
done

mkdir -p bench/results
stamp="$(date +%Y-%m-%d_%H%M%S)"
md="bench/results/${stamp}.md"
csv="bench/results/${stamp}.csv"

echo "server,tool,method,size,req_per_sec,p50_ms,p99_ms,errors" > "$csv"

# oha --output-format json (on stdin) -> "req_per_sec p50_ms p99_ms errors".
# NB: uses `python3 -c` (not a heredoc) so stdin stays the piped oha JSON --
# a `python3 - <<'PY'` heredoc would steal stdin and read the program instead.
parse_oha() {
    python3 -c '
import json, sys
d = json.load(sys.stdin)
s = d.get("summary", {})
p = d.get("latencyPercentiles", {})
rps = s.get("requestsPerSec", 0.0)
p50 = (p.get("p50") or s.get("average") or 0.0) * 1000.0
p99 = (p.get("p99") or 0.0) * 1000.0
codes = d.get("statusCodeDistribution", {})
ok = sum(v for k, v in codes.items() if str(k).startswith("2"))
total = s.get("total", 0) or sum(codes.values())
errors = max(total - ok, 0)
print(f"{rps:.0f} {p50:.2f} {p99:.2f} {errors}")
'
}

run_oha() { # url [put-body-file]
    local url="$1" body="${2:-}"
    if [[ -n "$body" ]]; then
        oha -n "$REQS" -c "$CONC" --disable-keepalive --no-tui --output-format json \
            -m PUT -D "$body" "$url" 2>/dev/null | parse_oha
    else
        oha -n "$REQS" -c "$CONC" --disable-keepalive --no-tui --output-format json \
            "$url" 2>/dev/null | parse_oha
    fi
}

run_wrk() { # url [put-body-file]  -> "req_per_sec p99_ms errors"
    local url="$1" body="${2:-}" out
    if [[ -n "$body" ]]; then
        out="$(WRK_BODY_FILE="$body" wrk -t"$THREADS" -c"$CONC" -d"${DUR}s" --latency \
               -s "$here/put.lua" "$url" 2>/dev/null)"
    else
        out="$(wrk -t"$THREADS" -c"$CONC" -d"${DUR}s" --latency "$url" 2>/dev/null)"
    fi
    local rps p99 errs
    rps="$(awk '/Requests\/sec/{print $2}' <<<"$out")"
    # wrk --latency prints "99%   0.94ms" (value keeps its unit suffix).
    p99="$(awk '/^ *99%/{print $2}' <<<"$out")"
    errs="$(awk '/Socket errors|Non-2xx/{print $0}' <<<"$out" | tr '\n' ';')"
    echo "${rps:-0} ${p99:-n/a} ${errs:-0}"
}

launch() { # target port -> echoes pid
    local target="$1" port="$2"
    if [[ "$target" == httpserver ]]; then
        ( cd "$root" && exec "$repo/httpserver" -t "$THREADS" "$port" ) >"$root/h.log" 2>&1 &
        echo $!
    else
        local conf="$root/nginx_$port.conf"
        sed -e "s#__WORKERS__#$THREADS#g" -e "s#__PORT__#$port#g" -e "s#__ROOT__#$root#g" \
            "$here/nginx.conf.template" > "$conf"
        "$nginx_bin" -c "$conf" -p "$root" >"$root/n.log" 2>&1 &
        echo $!
    fi
}

{
    echo "# httpserver vs nginx — $stamp"
    echo
    echo "REQS=$REQS CONC=$CONC DUR=${DUR}s THREADS=$THREADS"
    echo
    echo "oha: --disable-keepalive (1 req/conn, matches httpserver). "
    echo "wrk: keep-alive on (reconnects on close; socket errors expected vs httpserver)."
    echo
    echo "| server | tool | method | size | req/s | p50 ms | p99 ms | errors |"
    echo "|--------|------|--------|------|------:|-------:|-------:|--------|"
} > "$md"

for target in httpserver nginx; do
    port="$(get_port)"
    pid="$(launch "$target" "$port")"
    if ! wait_for_listen "$port"; then
        echo "$target did not listen on $port" >&2
        cat "$root"/*.log >&2
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        continue
    fi

    for name in small med large; do
        url="http://127.0.0.1:$port/get_$name.dat"
        read -r rps p50 p99 errs <<<"$(run_oha "$url")"
        echo "| $target | oha | GET | $name | $rps | $p50 | $p99 | $errs |" >> "$md"
        echo "$target,oha,GET,$name,$rps,$p50,$p99,$errs" >> "$csv"

        read -r wrps wp99 werr <<<"$(run_wrk "$url")"
        echo "| $target | wrk | GET | $name | $wrps | n/a | $wp99 | $werr |" >> "$md"
        echo "$target,wrk,GET,$name,$wrps,,$wp99,$werr" >> "$csv"
    done

    for name in small med large; do
        url="http://127.0.0.1:$port/put_target_$name.dat"
        body="$root/body_$name.dat"
        read -r rps p50 p99 errs <<<"$(run_oha "$url" "$body")"
        echo "| $target | oha | PUT | $name | $rps | $p50 | $p99 | $errs |" >> "$md"
        echo "$target,oha,PUT,$name,$rps,$p50,$p99,$errs" >> "$csv"

        read -r wrps wp99 werr <<<"$(run_wrk "$url" "$body")"
        echo "| $target | wrk | PUT | $name | $wrps | n/a | $wp99 | $werr |" >> "$md"
        echo "$target,wrk,PUT,$name,$wrps,,$wp99,$werr" >> "$csv"
    done

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
done

echo
echo "Wrote $md and $csv"
cat "$md"
