#!/usr/bin/env julia
# scripts/plot_network_review.jl
# Generate network_overview plots for all supported networks for visual QA.
# Output: test_plots/network_review/network_overview_{NETWORK}_2020-06-15.pdf
# Usage: GKSwstype=nul julia --project=. scripts/plot_network_review.jl

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using GridPlanning
import Plots
Plots.gr()  # ensure GR backend; GKSwstype=nul must be set in environment before launch

const OUT_DIR   = joinpath(@__DIR__, "..", "test_plots", "network_review")
const TEST_DATE = (2020, 6, 15)
const DATA_DIR  = "test_data"

mkpath(OUT_DIR)

# (network, T) — ordered small to large; T=1 for large networks to keep solves fast
networks = [
    ("RTS",     24),
    ("WECC240", 24),
    ("Texas2k",  1),
    ("Texas7k",  1),
    ("CATS",    24),
    ("WECC10k",  1),
]

for (network, T) in networks
    println("\n=== $network (T=$T) ===")
    flush(stdout)

    r = solve_ots(Dict(
        :network          => network,
        :model            => "DCOTS",
        :objective        => "loadshed",
        :times            => [TEST_DATE],
        :switching_method => "thresholded",
        :threshold_pct    => 0.75,
        :T                => T,
        :data_dir         => DATA_DIR,
        :time_limit       => 300.0,
        :mip_gap          => 0.01,
    ))

    n_off = sum(length(v) for v in values(r[:switched_off_lines]))
    println("  status: $(r[:status])  |  switched off: $n_off lines")

    plot_results(r, [:network_overview]; output_dir=OUT_DIR, format="pdf")
    plot_results(r, [:network_overview]; output_dir=OUT_DIR, format="png")
    println("  saved → $(OUT_DIR)/network_overview_$(network)_2020-06-15.{pdf,png}")
end

println("\nDone. Review plots in:\n  $OUT_DIR")
