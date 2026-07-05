#!/usr/bin/env bash
#
# Thread-scaling head-to-head: how well does each server's parallelism knob
# actually buy throughput? Sweep the worker count and, for each point, drive
# constant offered load with bench-loadgen (Zig-native, one-request-per-
# connection -- httpserver's exact model, no oha/wrk reconnect artifacts).
#
#   httpserver  -t N            (N worker threads + 1 dispatcher)
#   nginx       worker_processes N
#
# Reports, per (server, size):
#   throughput T(N) at each N, and
#   scaling efficiency  E(N) = T(N) / (N * T(1))   -- 1.0 = perfect linear
#                                                     scaling, <1 = contention.
# And per (N, size): the httpserver/nginx throughput ratio -- the portable
# "score" (raw req/s isn't comparable across machines; a same-box ratio is).
#
# The offered load (CONC connections) is held FIXED across the sweep so only
# the server's worker count changes. Default fixtures are small so the test is
# request-handling/syscall bound (what threads help), not NIC-bandwidth bound.
#
# Output: bench/results/scaling_<date>.md (+ .csv). Informational, not gated --
# scaling only means something on a machine with real cores (a 2-vCPU CI runner
# has nothing to scale), so this is a local tool.
#
# Usage:  bench/scaling.sh
# Tunables (env):
#   THREADS_SWEEP  worker counts to sweep      (default "1 2 4 8")
#   CONC           loadgen connections (load)  (default 64)
#   DUR            seconds per point           (default 5)
#   SIZES          fixture sizes               (default "small")   small|med|large
#   METHOD         GET or PUT                  (default GET)
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
source "$repo/test_scripts/utils.sh"
cd "$repo"

THREADS_SWEEP="${THREADS_SWEEP:-1 2 4 8}"
CONC="${CONC:-64}"
DUR="${DUR:-5}"
SIZES="${SIZES:-small}"
METHOD="${METHOD:-GET}"

declare -A bytesz=( [small]=1024 [med]=65536 [large]=1048576 )

nginx_bin="$(command -v nginx || echo /usr/sbin/nginx)"
[[ -x "$nginx_bin" ]] || { echo "nginx not found" >&2; exit 1; }

# Build the C server + the Zig loadgen (ReleaseFast -- this is a perf tool).
make >/dev/null || { echo "make failed" >&2; exit 1; }
zig build -Doptimize=ReleaseFast >/dev/null || { echo "zig build failed" >&2; exit 1; }
loadgen="$repo/zig-out/bin/bench-loadgen"
[[ -x "$loadgen" ]] || { echo "bench-loadgen not built" >&2; exit 1; }

root="$(mktemp -d)"
mkdir -p "$root/.client_temp" "$root/.proxy_temp" "$root/.fastcgi_temp" \
         "$root/.uwsgi_temp" "$root/.scgi_temp"
trap 'rm -rf "$root"' EXIT

for s in $SIZES; do
    head -c "${bytesz[$s]}" /dev/urandom > "$root/get_$s.dat"
    head -c "${bytesz[$s]}" /dev/urandom > "$root/body_$s.dat"
done

launch() { # target port workers -> echoes pid
    local target="$1" port="$2" workers="$3"
    if [[ "$target" == httpserver ]]; then
        ( cd "$root" && exec "$repo/httpserver" -t "$workers" "$port" ) >"$root/h.log" 2>&1 &
        echo $!
    else
        local conf="$root/nginx_$port.conf"
        sed -e "s#__WORKERS__#$workers#g" -e "s#__PORT__#$port#g" -e "s#__ROOT__#$root#g" \
            "$here/nginx.conf.template" > "$conf"
        "$nginx_bin" -c "$conf" -p "$root" >"$root/n.log" 2>&1 &
        echo $!
    fi
}

run_load() { # target port size -> "rps p50 p90 p99 reqs errors mbps"
    local target="$1" port="$2" size="$3"
    if [[ "$METHOD" == PUT ]]; then
        "$loadgen" "127.0.0.1:$port" PUT "/put_${target}_${size}.dat" \
            -c "$CONC" -d "$DUR" -b "$root/body_$size.dat"
    else
        "$loadgen" "127.0.0.1:$port" GET "/get_$size.dat" -c "$CONC" -d "$DUR"
    fi
}

mkdir -p bench/results
stamp="$(date +%Y-%m-%d_%H%M%S)"
md="bench/results/scaling_${stamp}.md"
csv="bench/results/scaling_${stamp}.csv"

echo "server,threads,method,size,req_per_sec,p50_ms,p90_ms,p99_ms,errors" > "$csv"
declare -A RPS   # RPS[target|N|size] = req/s

for target in httpserver nginx; do
    for N in $THREADS_SWEEP; do
        port="$(get_port)"
        pid="$(launch "$target" "$port" "$N")"
        if ! wait_for_listen "$port"; then
            echo "$target(-t $N) did not listen on $port" >&2
            cat "$root"/*.log >&2
            kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
            continue
        fi
        for s in $SIZES; do
            read -r rps p50 p90 p99 reqs errs mbps <<<"$(run_load "$target" "$port" "$s")"
            RPS["$target|$N|$s"]="$rps"
            echo "$target,$N,$METHOD,$s,$rps,$p50,$p90,$p99,$errs" >> "$csv"
        done
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    done
done

# --- render the report -------------------------------------------------------
base_N="$(awk '{print $1}' <<<"$THREADS_SWEEP")"   # first swept N == T(1) base

{
    echo "# Thread-scaling: httpserver vs nginx — $stamp"
    echo
    echo "METHOD=$METHOD CONC=$CONC DUR=${DUR}s SWEEP=[$THREADS_SWEEP] SIZES=[$SIZES]"
    echo
    echo "Offered load (CONC connections) held fixed; only the server worker count varies."
    echo "E(N) = T(N) / (N * T($base_N)) — scaling efficiency, 1.0 = perfect linear."
    echo "ratio = httpserver req/s ÷ nginx req/s at the same N (the portable score)."
    echo
    echo "| size | N | httpserver req/s | E(N) | nginx req/s | E(N) | httpserver÷nginx |"
    echo "|------|--:|-----------------:|-----:|------------:|-----:|-----------------:|"
} > "$md"

for s in $SIZES; do
    hbase="${RPS[httpserver|$base_N|$s]:-0}"
    nbase="${RPS[nginx|$base_N|$s]:-0}"
    for N in $THREADS_SWEEP; do
        h="${RPS[httpserver|$N|$s]:-0}"
        n="${RPS[nginx|$N|$s]:-0}"
        read -r he ne ratio <<<"$(awk -v h="$h" -v n="$n" -v hb="$hbase" -v nb="$nbase" \
            -v N="$N" -v bN="$base_N" 'BEGIN{
                he = (hb>0 && N>0) ? h/((N/bN)*hb) : 0;
                ne = (nb>0 && N>0) ? n/((N/bN)*nb) : 0;
                r  = (n>0) ? h/n : 0;
                printf "%.2f %.2f %.2f", he, ne, r;
            }')"
        echo "| $s | $N | $h | $he | $n | $ne | $ratio |" >> "$md"
    done
done

echo >> "$md"
echo "Raw per-point latency (p50/p90/p99) is in ${csv##*/}." >> "$md"

echo
echo "Wrote $md and $csv"
cat "$md"
