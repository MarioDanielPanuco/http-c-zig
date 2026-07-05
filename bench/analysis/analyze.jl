#!/usr/bin/env -S julia
#
# bench/analysis/analyze.jl -- turns a bench/campaign.sh CSV into the SVG
# figures embedded by docs/performance.md, and prints a metric summary to
# stdout so numbers can be quoted without re-running Julia.
#
# Usage (from repo root, inside the nix devShell -- there is no system julia):
#   nix develop -c julia bench/analysis/analyze.jl bench/results/campaign_<stamp>.csv
#
# Input schema (see bench/campaign.sh, tidy, one row per recorded run):
#   experiment,server,threads,conc,method,size,rep,req_per_sec,p50_ms,p90_ms,
#   p99_ms,requests,errors,mb_per_sec
#
# experiment in {threads, conc, size, put}; server in {httpserver, nginx};
# rep in 1..REPS (medians are taken over rep, min/max reported as a band).
#
# Packages: exactly CSV, DataFrames, Plots + stdlib (Statistics, Printf).
# The depot is read-only (hermetic nix devShell) -- no Pkg.add, ever.

ENV["GKSwstype"] = "100"   # headless GR -- must be set before `using Plots`

using CSV
using DataFrames
using Plots
using Statistics
using Printf

gr()
# Extra margin so rotated y-labels are not clipped at the figure edge.
default(; left_margin = 6Plots.PlotMeasures.mm, bottom_margin = 3Plots.PlotMeasures.mm)

const FIGDIR = "docs/figures"

# Okabe-Ito colorblind-safe palette. httpserver/nginx keep the SAME color in
# every figure; size/metric variants are distinguished by line style/marker.
const COLOR_HTTPSERVER = RGB(0 / 255, 114 / 255, 178 / 255)   # blue
const COLOR_NGINX      = RGB(213 / 255, 94 / 255, 0 / 255)    # vermillion
const COLOR_REFERENCE  = RGB(0.55, 0.55, 0.55)                # neutral gray

servercolor(s::AbstractString) = s == "httpserver" ? COLOR_HTTPSERVER : COLOR_NGINX

const SIZE_ORDER = ["small", "med", "large"]
const SIZE_LABEL = Dict("small" => "1 KiB", "med" => "64 KiB", "large" => "1 MiB")
const SIZE_STYLE = Dict("small" => :solid, "med" => :dash, "large" => :dot)

const SERVERS = ["httpserver", "nginx"]

# Hardware fact (campaign .meta sidecar): AMD Ryzen 7 9800X3D -- 8 PHYSICAL
# cores, 16 logical via SMT. N <= 8 threads run on real cores; N = 12/16 lean
# on SMT siblings AND compete with the load generator's 64 client threads.
# USL is fitted on the N <= PHYS_CORES points (the "physical core" regime);
# the fitted curve is extrapolated over the SMT points to show deviation.
const PHYS_CORES = 8

# Which column each experiment sweeps over (used for monotonicity checks and
# picking the natural x-axis).
const SWEEP_VAR = Dict(
    "threads" => :threads,
    "conc"    => :conc,
    "size"    => :threads,
    "put"     => :threads,
)

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

"""Rows belonging to one experiment."""
filter_exp(df::DataFrame, exp::AbstractString) = df[df.experiment .== exp, :]

"""
Group `df` by `groupcols` and, for every column in `valcols`, add
`<col>_med`, `<col>_min`, `<col>_max` (median/min/max across `rep`).
"""
function agg(df::DataFrame, groupcols::Vector{Symbol}, valcols::Vector{Symbol})
    pairs = Pair[]
    for v in valcols
        push!(pairs, v => median => Symbol(v, :_med))
        push!(pairs, v => minimum => Symbol(v, :_min))
        push!(pairs, v => maximum => Symbol(v, :_max))
    end
    return combine(groupby(df, groupcols), pairs...)
end

"""Print a DataFrame in full (no row/col truncation) -- used for stdout tables."""
function print_df(df::DataFrame)
    if nrow(df) == 0
        println("  (no data)")
        return
    end
    show(stdout, df; allrows = true, allcols = true, summary = false)
    println()
end

xticks_for(ns) = (Float64.(sort(unique(ns))), string.(sort(unique(ns))))

# ---------------------------------------------------------------------------
# USL fit: T(N) = lambda*N / (1 + sigma*(N-1) + kappa*N*(N-1))
#
# For fixed (sigma, kappa), T is linear in lambda, so lambda is solved by
# ordinary least squares through the origin against f(N) = N/D(N). We grid
# search (sigma, kappa), then zoom the grid around the best point a few
# times ("local refinement") -- pure Julia, no optimization package.
# ---------------------------------------------------------------------------

function usl_predict(N::AbstractVector{<:Real}, lambda, sigma, kappa)
    D = 1 .+ sigma .* (N .- 1) .+ kappa .* N .* (N .- 1)
    return lambda .* N ./ D
end

function usl_sse_lambda(Ns::Vector{Float64}, Ts::Vector{Float64}, sigma::Float64, kappa::Float64)
    D = 1 .+ sigma .* (Ns .- 1) .+ kappa .* Ns .* (Ns .- 1)
    if any(D .<= 0)
        return Inf, 0.0
    end
    f = Ns ./ D
    denom = sum(f .^ 2)
    lambda = denom > 0 ? sum(Ts .* f) / denom : 0.0
    pred = lambda .* f
    sse = sum((Ts .- pred) .^ 2)
    return sse, lambda
end

function fit_usl(Ns::Vector{Float64}, Ts::Vector{Float64})
    best_sse, best_sigma, best_kappa, best_lambda = Inf, 0.0, 0.0, 0.0

    function scan!(sigma_lo, sigma_hi, kappa_lo, kappa_hi; n = 61)
        for sigma in range(sigma_lo, sigma_hi; length = n)
            for kappa in range(kappa_lo, kappa_hi; length = n)
                sse, lambda = usl_sse_lambda(Ns, Ts, sigma, kappa)
                if sse < best_sse
                    best_sse, best_sigma, best_kappa, best_lambda = sse, sigma, kappa, lambda
                end
            end
        end
    end

    # Coarse grid: sigma up to 0.5 (serialization fraction), kappa up to 0.05
    # (per-pair coherency cost) -- generous for an 8-16 core sweep.
    scan!(0.0, 0.5, 0.0, 0.05)

    # Local refinement: zoom the window around the current best a few times.
    sigma_span, kappa_span = 0.5, 0.05
    for _ in 1:6
        sigma_span /= 5
        kappa_span /= 5
        scan!(max(0.0, best_sigma - sigma_span), best_sigma + sigma_span,
              max(0.0, best_kappa - kappa_span), best_kappa + kappa_span)
    end

    return best_lambda, best_sigma, best_kappa, best_sse
end

# Grid boundary check: warn if the fit landed on the top edge of the coarse
# search box (would mean the true optimum lies outside the searched region).
const SIGMA_MAX = 0.5
const KAPPA_MAX = 0.05
function usl_boundary_warnings(server, sigma, kappa)
    w = String[]
    sigma >= 0.999 * SIGMA_MAX &&
        push!(w, "USL fit for $server: sigma=$(round(sigma; digits=4)) sits on the grid boundary ($SIGMA_MAX) -- widen the sigma scan")
    kappa >= 0.999 * KAPPA_MAX &&
        push!(w, "USL fit for $server: kappa=$(round(kappa; digits=5)) sits on the grid boundary ($KAPPA_MAX) -- widen the kappa scan")
    return w
end

# ---------------------------------------------------------------------------
# Figures
# ---------------------------------------------------------------------------

"""1. scaling_throughput.svg -- throughput vs N (threads exp), both servers,
   median of reps with min-max band, log2 x-axis."""
function scaling_throughput_figure(agg_thr::DataFrame)
    p = plot(; xlabel = "Threads (N)", ylabel = "Throughput (req/s)",
             title = "Throughput Scaling vs Thread Count",
             xscale = :log2, legend = :topleft, size = (850, 550))
    for server in SERVERS
        sub = sort(agg_thr[agg_thr.server .== server, :], :threads)
        isempty(sub) && continue
        Ns = Float64.(sub.threads)
        med = sub.req_per_sec_med
        lo = sub.req_per_sec_min
        hi = sub.req_per_sec_max
        plot!(p, Ns, med; ribbon = (med .- lo, hi .- med), fillalpha = 0.2,
              label = server, color = servercolor(server), lw = 2,
              marker = :circle, ms = 4)
    end
    plot!(p; xticks = xticks_for(agg_thr.threads))
    savefig(p, joinpath(FIGDIR, "scaling_throughput.svg"))
end

"""2. scaling_efficiency.svg -- E(N) = T(N)/(N*T(1)) per server, 1.0 reference."""
function scaling_efficiency_figure(agg_thr::DataFrame)
    p = plot(; xlabel = "Threads (N)", ylabel = "Efficiency E(N) = T(N) / (N * T(1))",
             title = "Parallel Efficiency vs Thread Count",
             xscale = :log2, legend = :bottomleft, size = (850, 550))
    hline!(p, [1.0]; label = "ideal (E=1)", color = COLOR_REFERENCE, ls = :dash)
    vline!(p, [Float64(PHYS_CORES)]; label = "physical cores ($PHYS_CORES); SMT beyond",
           color = COLOR_REFERENCE, ls = :dot, lw = 2)

    eff_table = DataFrame(server = String[], threads = Int[], efficiency = Float64[])
    for server in SERVERS
        sub = sort(agg_thr[agg_thr.server .== server, :], :threads)
        isempty(sub) && continue
        base_rows = sub[sub.threads .== 1, :req_per_sec_med]
        isempty(base_rows) && continue
        base = base_rows[1]
        Ns = Float64.(sub.threads)
        E = sub.req_per_sec_med ./ (Ns .* base)
        plot!(p, Ns, E; label = server, color = servercolor(server), lw = 2,
              marker = :circle, ms = 4)
        for (n, e) in zip(sub.threads, E)
            push!(eff_table, (server, n, e))
        end
    end
    plot!(p; xticks = xticks_for(agg_thr.threads))
    savefig(p, joinpath(FIGDIR, "scaling_efficiency.svg"))
    return eff_table
end

"""3. usl_fit.svg -- measured T(N) + USL curve fitted on the N <= PHYS_CORES
   points, extrapolated (dotted) across the SMT regime. Returns per-server
   (lambda, sigma, kappa, sse) plus the SMT-point deviations from the fit."""
function usl_fit_figure(agg_thr::DataFrame)
    p = plot(; xlabel = "Threads (N)", ylabel = "Throughput (req/s)",
             title = "USL Fit (N <= $PHYS_CORES physical cores; extrapolated into SMT)",
             xscale = :log2, legend = :topleft, size = (850, 550))
    vline!(p, [Float64(PHYS_CORES)]; label = "physical cores ($PHYS_CORES)",
           color = COLOR_REFERENCE, ls = :dot, lw = 2)
    results = Dict{String, NTuple{5, Float64}}()  # server -> (lambda, sigma, kappa, sse, r2)
    deviations = DataFrame(server = String[], threads = Int[],
                           measured_rps = Float64[], usl_pred_rps = Float64[],
                           deviation_pct = Float64[])

    for server in SERVERS
        sub = sort(agg_thr[agg_thr.server .== server, :], :threads)
        isempty(sub) && continue
        Ns = Float64.(sub.threads)
        Ts = Float64.(sub.req_per_sec_med)
        phys = Ns .<= PHYS_CORES
        count(phys) >= 3 || continue   # need a few points for a 3-parameter law
        lambda, sigma, kappa, sse = fit_usl(Ns[phys], Ts[phys])
        sstot = sum((Ts[phys] .- mean(Ts[phys])) .^ 2)
        r2 = sstot > 0 ? 1 - sse / sstot : NaN
        results[server] = (lambda, sigma, kappa, sse, r2)

        scatter!(p, Ns, Ts; label = "$server measured", color = servercolor(server), ms = 5)
        # Fit region: dashed. Extrapolation into the SMT regime: dotted.
        Nfit = collect(range(minimum(Ns), Float64(PHYS_CORES); length = 120))
        plot!(p, Nfit, usl_predict(Nfit, lambda, sigma, kappa);
              label = "$server USL fit (N<=$PHYS_CORES)", color = servercolor(server),
              ls = :dash, lw = 2)
        if maximum(Ns) > PHYS_CORES
            Next = collect(range(Float64(PHYS_CORES), maximum(Ns); length = 80))
            plot!(p, Next, usl_predict(Next, lambda, sigma, kappa);
                  label = "$server USL extrapolated", color = servercolor(server),
                  ls = :dot, lw = 2)
        end
        # Record how the SMT points deviate from the physical-core law.
        for (n, t) in zip(sub.threads, Ts)
            n > PHYS_CORES || continue
            pred = usl_predict([Float64(n)], lambda, sigma, kappa)[1]
            push!(deviations, (server, n, t, pred, 100 * (t - pred) / pred))
        end
    end
    plot!(p; xticks = xticks_for(agg_thr.threads))
    savefig(p, joinpath(FIGDIR, "usl_fit.svg"))
    return results, deviations
end

"""4. latency_throughput.svg -- conc experiment: p50/p99 vs achieved throughput."""
function latency_throughput_figure(df::DataFrame)
    exp_df = filter_exp(df, "conc")
    a = agg(exp_df, [:server, :conc], [:req_per_sec, :p50_ms, :p99_ms])
    p = plot(; xlabel = "Achieved Throughput (req/s)", ylabel = "Latency (ms, log scale)",
             title = "Load-Response Curve: Latency vs Throughput",
             yscale = :log10, legend = :topleft, size = (850, 550))
    for server in SERVERS
        sub = sort(a[a.server .== server, :], :conc)
        isempty(sub) && continue
        x = sub.req_per_sec_med
        plot!(p, x, sub.p50_ms_med; label = "$server p50", color = servercolor(server),
              ls = :solid, lw = 2, marker = :circle, ms = 4)
        plot!(p, x, sub.p99_ms_med; label = "$server p99", color = servercolor(server),
              ls = :dash, lw = 2, marker = :diamond, ms = 4)
    end
    savefig(p, joinpath(FIGDIR, "latency_throughput.svg"))
    return sort(a, [:server, :conc])
end

"""5. size_crossover.svg + size_bandwidth.svg -- size experiment."""
function size_figures(df::DataFrame)
    exp_df = filter_exp(df, "size")
    a = agg(exp_df, [:server, :size, :threads], [:req_per_sec, :mb_per_sec])

    p1 = plot(; xlabel = "Threads (N)", ylabel = "Throughput (req/s)",
              title = "Response-Size Crossover: Throughput vs N",
              xscale = :log2, legend = :outertopright, size = (950, 550))
    p2 = plot(; xlabel = "Threads (N)", ylabel = "Bandwidth (MB/s)",
              title = "Response-Size Crossover: Bandwidth vs N",
              xscale = :log2, legend = :outertopright, size = (950, 550))

    for server in SERVERS, sz in SIZE_ORDER
        sub = sort(a[(a.server .== server) .& (a.size .== sz), :], :threads)
        isempty(sub) && continue
        Ns = Float64.(sub.threads)
        label = "$server $(SIZE_LABEL[sz])"
        style = SIZE_STYLE[sz]
        plot!(p1, Ns, sub.req_per_sec_med; label = label, color = servercolor(server),
              ls = style, lw = 2, marker = :circle, ms = 3)
        plot!(p2, Ns, sub.mb_per_sec_med; label = label, color = servercolor(server),
              ls = style, lw = 2, marker = :circle, ms = 3)
    end
    plot!(p1; xticks = xticks_for(a.threads))
    plot!(p2; xticks = xticks_for(a.threads))
    savefig(p1, joinpath(FIGDIR, "size_crossover.svg"))
    savefig(p2, joinpath(FIGDIR, "size_bandwidth.svg"))
    return sort(a, [:server, :size, :threads])
end

"""6. put_scaling.svg -- PUT throughput vs N both servers, plus httpserver GET overlay."""
function put_scaling_figure(df::DataFrame)
    put_df = filter_exp(df, "put")
    a_put = agg(put_df, [:server, :threads], [:req_per_sec])

    thr_df = filter_exp(df, "threads")
    a_get_h = agg(thr_df[thr_df.server .== "httpserver", :], [:threads], [:req_per_sec])

    p = plot(; xlabel = "Threads (N)", ylabel = "Throughput (req/s)",
             title = "PUT Scaling vs GET (httpserver)",
             xscale = :log2, legend = :topleft, size = (850, 550))
    for server in SERVERS
        sub = sort(a_put[a_put.server .== server, :], :threads)
        isempty(sub) && continue
        plot!(p, Float64.(sub.threads), sub.req_per_sec_med; label = "$server PUT",
              color = servercolor(server), lw = 2, marker = :circle, ms = 4)
    end
    if !isempty(a_get_h)
        sub = sort(a_get_h, :threads)
        plot!(p, Float64.(sub.threads), sub.req_per_sec_med;
              label = "httpserver GET (threads exp)", color = servercolor("httpserver"),
              ls = :dot, lw = 2, marker = :square, ms = 4)
    end
    all_ns = vcat(a_put.threads, a_get_h.threads)
    if !isempty(all_ns)
        plot!(p; xticks = xticks_for(all_ns))
    end
    savefig(p, joinpath(FIGDIR, "put_scaling.svg"))
    return sort(a_put, [:server, :threads])
end

# ---------------------------------------------------------------------------
# httpserver / nginx ratio table (threads experiment)
# ---------------------------------------------------------------------------

function ratio_table(agg_thr::DataFrame)
    h = sort(agg_thr[agg_thr.server .== "httpserver", [:threads, :req_per_sec_med]], :threads)
    n = sort(agg_thr[agg_thr.server .== "nginx", [:threads, :req_per_sec_med]], :threads)
    rename!(h, :req_per_sec_med => :httpserver_rps)
    rename!(n, :req_per_sec_med => :nginx_rps)
    m = innerjoin(h, n; on = :threads)
    isempty(m) && return m
    m.ratio = m.httpserver_rps ./ m.nginx_rps
    return m
end

# ---------------------------------------------------------------------------
# Anomaly detection: non-monotonic medians, errors > 0, rep spread > 10%.
# ---------------------------------------------------------------------------

function detect_anomalies(df::DataFrame)
    anomalies = String[]

    # errors > 0
    for r in eachrow(df[df.errors .> 0, :])
        push!(anomalies, @sprintf(
            "errors: exp=%s server=%s N=%d conc=%d %s/%s rep=%d -> %d errors (of %d requests)",
            r.experiment, r.server, r.threads, r.conc, r.method, r.size, r.rep, r.errors, r.requests))
    end

    # rep spread > 10% of median throughput, within each fully-keyed point
    keycols_full = [:experiment, :server, :threads, :conc, :method, :size]
    for g in groupby(df, keycols_full)
        vals = g.req_per_sec
        length(vals) < 2 && continue
        med = median(vals)
        spread = maximum(vals) - minimum(vals)
        if med > 0 && spread / med > 0.10
            k = g[1, keycols_full]
            push!(anomalies, @sprintf(
                "rep spread: exp=%s server=%s N=%d conc=%d %s/%s -> %.1f%% of median (range %s..%s, median %.0f)",
                k.experiment, k.server, k.threads, k.conc, k.method, k.size,
                100 * spread / med, string(minimum(vals)), string(maximum(vals)), med))
        end
    end

    # non-monotonic medians along each experiment's natural sweep variable
    for exp in unique(df.experiment)
        haskey(SWEEP_VAR, exp) || continue
        sweep = SWEEP_VAR[exp]
        edf = filter_exp(df, exp)
        keycols = exp == "size" ? [:server, :size] : [:server]
        for grp in groupby(edf, keycols)
            gdf = DataFrame(grp)
            a = agg(gdf, [sweep], [:req_per_sec])
            sort!(a, sweep)
            nrow(a) < 2 && continue
            meds = a.req_per_sec_med
            xs = a[!, sweep]
            kdesc = join(["$(c)=$(grp[1, c])" for c in keycols], " ")
            for i in 2:length(meds)
                if meds[i] < meds[i - 1]
                    push!(anomalies, @sprintf(
                        "non-monotonic: exp=%s %s  %s %s->%s : throughput %.0f -> %.0f (decrease)",
                        exp, kdesc, string(sweep), string(xs[i - 1]), string(xs[i]),
                        meds[i - 1], meds[i]))
                end
            end
        end
    end

    return anomalies
end

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

function main()
    length(ARGS) >= 1 || error("usage: julia analyze.jl <campaign_csv>")
    csvpath = ARGS[1]
    isfile(csvpath) || error("no such file: $csvpath")

    df = CSV.read(csvpath, DataFrame)
    mkpath(FIGDIR)

    println("=" ^ 80)
    println("Campaign analysis: $csvpath  ($(nrow(df)) rows)")
    println("=" ^ 80)

    present = Set(df.experiment)

    # --- threads experiment: figures 1-3 + ratio table ---
    if "threads" in present
        thr_df = filter_exp(df, "threads")
        agg_thr = sort(agg(thr_df, [:server, :threads],
                            [:req_per_sec, :p50_ms, :p90_ms, :p99_ms]),
                       [:server, :threads])

        println("\n[threads] per-N medians (req/s min-max; latency ms):")
        print_df(agg_thr)

        scaling_throughput_figure(agg_thr)

        eff_table = scaling_efficiency_figure(agg_thr)
        println("\n[threads] efficiency E(N) = T(N) / (N * T(1)):")
        print_df(eff_table)
        println("  NOTE: the machine has $PHYS_CORES physical cores (16 logical via SMT).")
        println("  E(N) for N > $PHYS_CORES divides by N logical threads, but those threads share")
        println("  $PHYS_CORES physical cores with each other AND with the load generator's 64 client")
        println("  threads -- so E(N) past N=$PHYS_CORES measures SMT yield + generator interference,")
        println("  not parallel efficiency of the server. Judge scaling on N <= $PHYS_CORES.")

        usl_results, usl_dev = usl_fit_figure(agg_thr)
        println("\n[threads] USL fit on N <= $PHYS_CORES (physical-core regime):")
        println("  T(N) = lambda*N / (1 + sigma*(N-1) + kappa*N*(N-1))")
        for server in SERVERS
            haskey(usl_results, server) || continue
            lambda, sigma, kappa, sse, r2 = usl_results[server]
            @printf("  %-10s lambda=%.2f  sigma=%.5f  kappa=%.6f  (SSE=%.1f, R2=%.4f)\n",
                    server, lambda, sigma, kappa, sse, r2)
            if r2 < 0.9
                println("             ^ POOR FIT (R2 < 0.9): the fit-region data is noisy or")
                println("               non-monotonic (see anomalies); coefficients not meaningful.")
            end
        end
        println("  sigma = contention/serialization (throughput loss ~linear in N);")
        println("  kappa = coherency/crosstalk (throughput loss ~quadratic in N, e.g. lock/cache-line contention).")
        if nrow(usl_dev) > 0
            println("\n[threads] SMT-regime points (N > $PHYS_CORES) vs physical-core USL extrapolation:")
            print_df(usl_dev)
            println("  (deviation_pct < 0: SMT threads yield less than a real core would --")
            println("   expected, since N=12/16 share $PHYS_CORES cores with the load generator.)")
        end
        for server in SERVERS
            haskey(usl_results, server) || continue
            sigma, kappa = usl_results[server][2], usl_results[server][3]
            for w in usl_boundary_warnings(server, sigma, kappa)
                println("  WARNING: $w")
            end
        end

        rt = ratio_table(agg_thr)
        println("\n[threads] httpserver / nginx throughput ratio per N:")
        print_df(rt)
    else
        agg_thr = DataFrame()
        println("\n[threads] SKIPPED -- no rows for this experiment in $csvpath")
    end

    # --- conc experiment: figure 4 ---
    if "conc" in present
        lat_agg = latency_throughput_figure(df)
        println("\n[conc] per-conc medians (throughput req/s, p50/p99 ms):")
        print_df(lat_agg)
    else
        println("\n[conc] SKIPPED -- no rows for this experiment in $csvpath")
    end

    # --- size experiment: figure 5 (x2) ---
    if "size" in present
        size_agg = size_figures(df)
        println("\n[size] per-size,N medians (throughput req/s, bandwidth MB/s):")
        print_df(size_agg)
    else
        println("\n[size] SKIPPED -- no rows for this experiment in $csvpath")
    end

    # --- put experiment: figure 6 ---
    if "put" in present
        put_agg = put_scaling_figure(df)
        println("\n[put] per-N medians (PUT throughput req/s):")
        print_df(put_agg)
    else
        println("\n[put] SKIPPED -- no rows for this experiment in $csvpath")
    end

    # --- anomalies (whole dataset) ---
    anomalies = detect_anomalies(df)
    println("\n" * "=" ^ 80)
    println("Anomalies ($(length(anomalies)) found):")
    if isempty(anomalies)
        println("  none")
    else
        for a in anomalies
            println("  - $a")
        end
    end
    println("=" ^ 80)
end

main()
