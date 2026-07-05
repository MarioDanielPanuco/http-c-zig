#!/usr/bin/env bash
#
# Benchmark campaign: the full experiment matrix behind docs/performance.md.
# scaling.sh answers one question interactively; this runs the whole designed
# experiment and emits ONE tidy CSV (a row per measurement, every factor a
# column) for bench/analysis/*.jl to consume.
#
# Experiments (each server: httpserver, nginx):
#   threads  T(N) at fixed load        N in THREADS_SWEEP, CONC fixed
#   conc     load-response at fixed N  CONC in CONC_SWEEP, N=CONC_AT_N
#   size     response-size crossover   SIZES x SIZE_NS, CONC fixed
#   put      write-path scaling        PUT small, N in PUT_SWEEP
#
# Each (server, point) launches a fresh server, does one un-recorded warmup
# run, then REPS recorded runs (median/variance handled downstream in Julia).
#
# Output:
#   bench/results/campaign_<stamp>.csv   the dataset
#   bench/results/campaign_<stamp>.meta  machine + parameters (provenance)
#
# Usage:  bench/campaign.sh            (tunables via env, see defaults below)
# Informational, not gated; needs real cores — don't bother in CI.
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
source "$repo/test_scripts/utils.sh"
cd "$repo"

EXPERIMENTS="${EXPERIMENTS:-threads conc size put}"
THREADS_SWEEP="${THREADS_SWEEP:-1 2 3 4 6 8 12 16}"
CONC_SWEEP="${CONC_SWEEP:-1 2 4 8 16 32 64 128 256}"
CONC_AT_N="${CONC_AT_N:-8}"
SIZES="${SIZES:-small med large}"
SIZE_NS="${SIZE_NS:-1 4 8 16}"
PUT_SWEEP="${PUT_SWEEP:-1 2 4 8 16}"
CONC="${CONC:-64}"       # fixed offered load for threads/size/put experiments
DUR="${DUR:-4}"          # seconds per recorded run
REPS="${REPS:-3}"        # recorded runs per point
WARMUP_S="${WARMUP_S:-1}"

declare -A bytesz=( [small]=1024 [med]=65536 [large]=1048576 )

nginx_bin="$(command -v nginx || echo /usr/sbin/nginx)"
[[ -x "$nginx_bin" ]] || { echo "nginx not found" >&2; exit 1; }

make >/dev/null || { echo "make failed" >&2; exit 1; }
zig build -Doptimize=ReleaseFast >/dev/null || { echo "zig build failed" >&2; exit 1; }
loadgen="$repo/zig-out/bin/bench-loadgen"
[[ -x "$loadgen" ]] || { echo "bench-loadgen not built" >&2; exit 1; }

root="$(mktemp -d)"
mkdir -p "$root/.client_temp" "$root/.proxy_temp" "$root/.fastcgi_temp" \
         "$root/.uwsgi_temp" "$root/.scgi_temp"
trap 'rm -rf "$root"' EXIT

for s in small med large; do
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

mkdir -p bench/results
stamp="$(date +%Y-%m-%d_%H%M%S)"
csv="bench/results/campaign_${stamp}.csv"
meta="bench/results/campaign_${stamp}.meta"

echo "experiment,server,threads,conc,method,size,rep,req_per_sec,p50_ms,p90_ms,p99_ms,requests,errors,mb_per_sec" > "$csv"

{
    echo "date: $(date -Iseconds)"
    echo "host: $(uname -a)"
    echo "cpu: $(awk -F: '/model name/{print $2; exit}' /proc/cpuinfo | sed 's/^ //')"
    echo "nproc: $(nproc)"
    echo "governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo n/a)"
    echo "nginx: $("$nginx_bin" -v 2>&1)"
    echo "params: EXPERIMENTS=[$EXPERIMENTS] THREADS_SWEEP=[$THREADS_SWEEP] CONC_SWEEP=[$CONC_SWEEP]"
    echo "        CONC_AT_N=$CONC_AT_N SIZES=[$SIZES] SIZE_NS=[$SIZE_NS] PUT_SWEEP=[$PUT_SWEEP]"
    echo "        CONC=$CONC DUR=${DUR}s REPS=$REPS WARMUP_S=${WARMUP_S}s"
} > "$meta"

# point <experiment> <target> <N> <conc> <method> <size>
# Fresh server, warmup, REPS recorded runs, rows appended to $csv.
point() {
    local exp="$1" target="$2" N="$3" conc="$4" method="$5" size="$6"
    local port pid rep line
    port="$(get_port)"
    pid="$(launch "$target" "$port" "$N")"
    if ! wait_for_listen "$port"; then
        echo "SKIP $exp/$target N=$N: no listen on $port" >&2
        cat "$root"/*.log >&2
        kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
        return 1
    fi
    run() {
        if [[ "$method" == PUT ]]; then
            "$loadgen" "127.0.0.1:$port" PUT "/put_${target}_${size}.dat" \
                -c "$conc" -d "$1" -b "$root/body_$size.dat"
        else
            "$loadgen" "127.0.0.1:$port" GET "/get_$size.dat" -c "$conc" -d "$1"
        fi
    }
    run "$WARMUP_S" >/dev/null   # warmup, discarded
    for rep in $(seq 1 "$REPS"); do
        line="$(run "$DUR")"
        # loadgen: rps p50 p90 p99 reqs errors mbps
        echo "$exp,$target,$N,$conc,$method,$size,$rep,${line// /,}" >> "$csv"
        echo "  $exp $target N=$N c=$conc $method/$size rep$rep: $line" >&2
    done
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
}

for exp in $EXPERIMENTS; do
    echo "== experiment: $exp ==" >&2
    case "$exp" in
    threads)
        for target in httpserver nginx; do
            for N in $THREADS_SWEEP; do point threads "$target" "$N" "$CONC" GET small; done
        done ;;
    conc)
        for target in httpserver nginx; do
            for c in $CONC_SWEEP; do point conc "$target" "$CONC_AT_N" "$c" GET small; done
        done ;;
    size)
        for target in httpserver nginx; do
            for s in $SIZES; do
                for N in $SIZE_NS; do point size "$target" "$N" "$CONC" GET "$s"; done
            done
        done ;;
    put)
        for target in httpserver nginx; do
            for N in $PUT_SWEEP; do point put "$target" "$N" "$CONC" PUT small; done
        done ;;
    *) echo "unknown experiment '$exp'" >&2 ;;
    esac
done

echo
echo "Wrote $csv"
echo "      $meta"
