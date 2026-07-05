#!/usr/bin/env bash
#
# Semantic differential: run one or more workloads against BOTH ./httpserver and
# nginx and check they agree on observable HTTP semantics (status codes + GET
# body bytes). See bench/differential.zig for the checker and its allowlist of
# known httpserver-vs-nginx divergences.
#
# Usage:
#   bench/differential.sh [workload.toml ...]     # default: the audit_* fixtures
#
# Requires (nix develop provides all): zig 0.15, nginx (with http_dav_module),
# make/clang, and ss/netstat (via test_scripts/utils.sh).
set -u

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/.." && pwd)"
source "$repo/test_scripts/utils.sh"
cd "$repo"

threads="${THREADS:-4}"
workloads=("$@")
if [[ ${#workloads[@]} -eq 0 ]]; then
    workloads=(workloads/audit_get.toml workloads/audit_put.toml workloads/audit_mix.toml)
fi

nginx_bin="$(command -v nginx || echo /usr/sbin/nginx)"
if [[ ! -x "$nginx_bin" ]]; then
    echo "nginx not found (looked for 'nginx' on PATH and /usr/sbin/nginx)" >&2
    exit 1
fi

# Build the C server and the Zig oracle if missing.
[[ -x ./httpserver ]] || make >/dev/null || { echo "make failed" >&2; exit 1; }
diff_bin=zig-out/bin/bench-differential
[[ -x "$diff_bin" ]] || zig build >/dev/null || { echo "zig build failed" >&2; exit 1; }

# --- per-workload run --------------------------------------------------------
run_one() {
    local workload="$1"
    local root hpid npid conf rc=0

    root="$(mktemp -d)"
    mkdir -p "$root/.client_temp" "$root/.proxy_temp" "$root/.fastcgi_temp" \
             "$root/.uwsgi_temp" "$root/.scgi_temp"

    # IMPORTANT: launch httpserver and wait for it to listen BEFORE picking
    # nginx's port. get_port only excludes ports already being listened on, so
    # calling it twice up front returns the SAME port for both (nothing is
    # listening yet) -> a bind collision where nginx silently loses and the
    # differential ends up testing httpserver against itself.
    local hport nport
    hport="$(get_port)"
    # httpserver serves its cwd, so launch it inside $root.
    ( cd "$root" && exec "$repo/httpserver" -t "$threads" "$hport" ) \
        >"$root/httpserver.log" 2>&1 &
    hpid=$!
    if ! wait_for_listen "$hport"; then
        echo "[$workload] httpserver did not listen on $hport" >&2
        cat "$root/httpserver.log" >&2
        rc=1
    fi

    nport="$(get_port)"   # httpserver now holds $hport, so this differs
    conf="$root/nginx.conf"
    sed -e "s#__WORKERS__#$threads#g" \
        -e "s#__PORT__#$nport#g" \
        -e "s#__ROOT__#$root#g" \
        "$here/nginx.conf.template" > "$conf"
    "$nginx_bin" -c "$conf" -p "$root" >"$root/nginx.log" 2>&1 &
    npid=$!
    if ! wait_for_listen "$nport"; then
        echo "[$workload] nginx did not listen on $nport" >&2
        cat "$root/nginx.log" >&2
        rc=1
    fi

    if [[ $rc -eq 0 ]]; then
        echo "=== $workload : httpserver(:$hport) vs nginx(:$nport) ==="
        "$diff_bin" "$workload" "127.0.0.1:$hport" "127.0.0.1:$nport" "$root"
        rc=$?
    fi

    kill "$hpid" "$npid" 2>/dev/null
    wait "$hpid" "$npid" 2>/dev/null
    rm -rf "$root"
    return $rc
}

overall=0
for w in "${workloads[@]}"; do
    if [[ ! -f "$w" ]]; then
        echo "workload not found: $w" >&2
        overall=1
        continue
    fi
    run_one "$w" || overall=1
done

if [[ $overall -eq 0 ]]; then
    echo "differential: all workloads agree"
else
    echo "differential: FAILURES above" >&2
fi
exit $overall
