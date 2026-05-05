"""
verify_reference_data.jl

Verifies that the test_data/ reference dataset works end-to-end for all 6 supported
networks using June 15, 2020 (the only date available for all networks including CATS).

Usage:
    julia --project=. scripts/verify_reference_data.jl

Each network is run with the thresholded method (no MIP, fast) and a permissive threshold
so the test focuses on data loading and model construction rather than solution quality.
"""

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using GridPlanning

const NETWORKS = ["RTS", "CATS", "Texas7k", "Texas2k", "WECC10k", "WECC240"]
const TEST_DATE = (2020, 6, 15)  # June 15, 2020 — available for all 6 networks

println("=" ^ 60)
println("Reference Data Verification — test_data/ June 15, 2020")
println("=" ^ 60)

results_summary = Dict{String, String}()

for network in NETWORKS
    print("  $network ... ")
    flush(stdout)
    try
        results = solve_ots(Dict(
            :network          => network,
            :model            => "DCOTS",
            :objective        => "loadshed",
            :times            => [TEST_DATE],
            :switching_method => "thresholded",
            :threshold_pct    => 0.0,   # de-energize nothing; just verify data loads
            :data_dir         => "test_data",
            :time_limit       => 120.0,
        ))
        status = string(results[:status])
        shed   = round(results[:total_load_shed], digits=1)
        println("PASS  (status=$status, load_shed=$(shed) MW)")
        results_summary[network] = "PASS"
    catch e
        msg = sprint(showerror, e)
        println("FAIL")
        println("    Error: $msg")
        results_summary[network] = "FAIL: $msg"
    end
end

println()
println("=" ^ 60)
println("Summary")
println("=" ^ 60)
passed = count(v -> v == "PASS", values(results_summary))
total  = length(NETWORKS)
for network in NETWORKS
    status = results_summary[network]
    mark   = startswith(status, "PASS") ? "✓" : "✗"
    println("  $mark  $network — $status")
end
println()
println("$passed / $total networks passed.")
