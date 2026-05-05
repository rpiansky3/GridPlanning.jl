using GridPlanning
using JLD2

pass_count = 0
fail_count = 0

function run_example(f, num, label)
    println("\n" * "="^60)
    println("EXAMPLE $num: $label")
    println("="^60)
    try
        result = f()
        println("[PASS] Example $num")
        global pass_count += 1
        return result
    catch e
        println("[FAIL] Example $num: $e")
        global fail_count += 1
        return nothing
    end
end

# CONFIRMED PASSING: Examples 1, 2, 3, 4

# ---------------------------------------------------------------------------
# Example 5: CATS Network with Custom Risk Metric
# ---------------------------------------------------------------------------
run_example(5, "CATS Network with Custom Risk Metric") do
    opt_parameters = Dict(
        :network => "CATS",
        :model => "DCOTS",
        :objective => "tradeoff",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :risk_metric => "max_wfpi",
        :tradeoff_weight => 0.6,
        :time_limit => 900.0
    )
    results = solve_ots(opt_parameters)
    println("Status: $(results[:status])")
    println("Risk reduction: $(results[:risk_reduction_pct])%")
    results
end

# ---------------------------------------------------------------------------
# Example 6: Cost Minimization
# ---------------------------------------------------------------------------
run_example(6, "Cost Minimization") do
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "cost",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :voll => 10000.0,
        :threshold_pct => 0.3
    )
    results = solve_ots(opt_parameters)
    println("Total cost: \$$(results[:objective_value])")
    results
end

# ---------------------------------------------------------------------------
# Example 7: Save Results to File
# ---------------------------------------------------------------------------
run_example(7, "Save Results to File") do
    mkpath("results")
    opt_parameters = Dict(
        :network => "Texas2k",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 1), (2020, 6, 2), (2020, 6, 3)],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => 0.4,
        :output_format => "jld2",
        :output_path => "results/texas2k_june2020_results.jld2"
    )
    results = solve_ots(opt_parameters)
    loaded = load("results/texas2k_june2020_results.jld2")
    println("JLD2 file created and reloaded successfully")
    println("Top-level keys: $(length(keys(loaded)))")
    results
end

# ---------------------------------------------------------------------------
# Example 8: Export Model and Solver Logs
# ---------------------------------------------------------------------------
run_example(8, "Export Model and Solver Logs") do
    mkpath("models"); mkpath("logs")
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "tradeoff",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :tradeoff_weight => 0.5,
        :lp_str => "models/rts_dcots_tradeoff.lp",
        :log_str => "logs/rts_dcots_solve.log"
    )
    results = solve_ots(opt_parameters)
    println("LP file created: $(isfile("models/rts_dcots_tradeoff.lp"))")
    println("Log file created: $(isfile("logs/rts_dcots_solve.log"))")
    results
end

# ---------------------------------------------------------------------------
# Example 9: Comparison Study
# ---------------------------------------------------------------------------
run_example(9, "Comparison Study (optimal vs thresholded)") do
    function compare_methods(network, date, threshold_pct)
        opt_params_optimal = Dict(
            :network => network, :model => "DCOTS", :objective => "loadshed",
            :times => [date], :data_dir => "test_data",
            :switching_method => "optimal", :threshold_pct => threshold_pct
        )
        results_optimal = solve_ots(opt_params_optimal)

        opt_params_threshold = Dict(
            :network => network, :model => "DCOTS", :objective => "loadshed",
            :times => [date], :data_dir => "test_data",
            :switching_method => "thresholded", :threshold_pct => threshold_pct
        )
        results_threshold = solve_ots(opt_params_threshold)

        println("\nComparison for $network on $date:")
        println("Optimal    - Time: $(results_optimal[:solve_time])s, Load shed: $(results_optimal[:total_load_shed]) MW")
        println("Thresholded - Time: $(results_threshold[:solve_time])s, Load shed: $(results_threshold[:total_load_shed]) MW")
        println("Speedup: $(results_optimal[:solve_time] / results_threshold[:solve_time])x")
        println("Load shed increase: $(results_threshold[:total_load_shed] - results_optimal[:total_load_shed]) MW")
        results_threshold
    end
    compare_methods("RTS", (2020, 6, 15), 0.5)
end

# ---------------------------------------------------------------------------
# Example 10: Line Hardening with Loadshed Objective
# ---------------------------------------------------------------------------
run_example(10, "Line Hardening with Loadshed Objective") do
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :hardening_enabled => true,
        :infrastructure_budget => 50e6,
        :hardening_cost_per_mile => 7e6,
        :hardening_effectiveness => 1.0,
        :hardening_enforce_energization => true
    )
    results = solve_ots(opt_parameters)
    println("Lines hardened: $(length(results[:hardened_lines]))")
    println("Hardening cost: \$$(results[:hardening_cost]/1e6)M")
    println("Risk mitigated by hardening: $(results[:mitigated_risk])")
    println("Remaining active risk: $(results[:active_risk])")
    println("Total risk reduction: $(results[:risk_reduction_pct])%")
    for line_id in results[:hardened_lines]
        println("  Line $line_id: hardened (y=$(results[:y][line_id]))")
    end
    results
end

# ---------------------------------------------------------------------------
# Example 11: Cost Minimization with Hardening
# ---------------------------------------------------------------------------
run_example(11, "Cost Minimization with Hardening") do
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "cost",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :voll => 10000.0,
        :hardening_enabled => true,
        :hardening_cost_per_mile => 7e6
    )
    results = solve_ots(opt_parameters)
    println("Total cost: \$$(results[:objective_value])")
    println("Hardening cost: \$$(results[:hardening_cost]/1e6)M")
    println("Generation + load shed cost: \$$(results[:objective_value] - results[:hardening_cost])")
    results
end

# ---------------------------------------------------------------------------
# Example 12: Thresholded Switching with Optimal Hardening (Texas7k)
# ---------------------------------------------------------------------------
run_example(12, "Thresholded Switching with Optimal Hardening (Texas7k, 2 days)") do
    opt_parameters = Dict(
        :network => "Texas7k",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 11), (2020, 6, 12)],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => 0.5,
        :hardening_enabled => true,
        :infrastructure_budget => 100e6,
        :hardening_effectiveness => 0.9
    )
    results = solve_ots(opt_parameters)
    println("Risk mitigated by hardening: $(results[:mitigated_risk])")
    println("Risk removed by switching: $(results[:removed_risk])")
    println("Total risk reduction: $(results[:risk_reduction_pct])%")
    println("Solve time: $(results[:solve_time])s")
    results
end

# ---------------------------------------------------------------------------
# Example 13: Battery Installation on CATS Network
# ---------------------------------------------------------------------------
run_example(13, "Battery Installation on CATS Network") do
    opt_parameters = Dict(
        :network => "CATS",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 21)],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => 0.75,
        :battery_enabled => true,
        :battery_cost_per_pu => 2e7,
        :infrastructure_budget => 500e6,
        :time_limit => 900.0
    )
    results = solve_ots(opt_parameters)
    println("Buses with batteries: $(length(results[:batteries_installed]))")
    println("Total capacity: $(round(results[:total_battery_capacity]*100, digits=1)) MWh")
    println("Battery cost: \$$(round(results[:battery_cost]/1e6, digits=1))M")
    println("Load shed: $(results[:total_load_shed]) MW")
    results
end

# ---------------------------------------------------------------------------
# Example 14: Custom Wildfire Risk Data
# ---------------------------------------------------------------------------
run_example(14, "Custom Wildfire Risk Data") do
    custom_risk = Dict{Int, Dict{Int, Float64}}(
        1 => Dict(5 => 0.8, 12 => 1.2, 23 => 0.5, 45 => 0.9),
        2 => Dict(5 => 0.9, 12 => 1.1, 23 => 0.4),
        3 => Dict(8 => 0.7, 23 => 0.6, 45 => 1.0)
    )
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "tradeoff",
        :times => [(2020, 6, 15), (2020, 6, 16), (2020, 6, 17)],
        :data_dir => "test_data",
        :risk_per_line => custom_risk,
        :tradeoff_weight => 0.5
    )
    results = solve_ots(opt_parameters)
    println("Active risk: $(results[:active_risk])")
    println("Risk reduction: $(results[:risk_reduction_pct])%")
    results
end

# ---------------------------------------------------------------------------
# Example 15: Combined Infrastructure Optimization
# ---------------------------------------------------------------------------
run_example(15, "Combined Infrastructure Optimization") do
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => 0.75,
        :solar_enabled => true,
        :solar_cost_per_pu => 5e7,
        :solar_data_path => "test_data/solar_data/RTS/solar_data.csv",
        :battery_enabled => true,
        :battery_cost_per_pu => 2e7,
        :hardening_enabled => true,
        :hardening_cost_per_mile => 7e6,
        :infrastructure_budget => 500e6
    )
    results = solve_ots(opt_parameters)
    println("Solar:     \$$(round(results[:solar_cost]/1e6, digits=1))M — $(length(results[:solar_installed])) buses")
    println("Batteries: \$$(round(results[:battery_cost]/1e6, digits=1))M — $(length(results[:batteries_installed])) buses")
    println("Hardening: \$$(round(results[:hardening_cost]/1e6, digits=1))M — $(length(results[:hardened_lines])) lines")
    total_infra = results[:solar_cost] + results[:battery_cost] + results[:hardening_cost]
    println("Total:     \$$(round(total_infra/1e6, digits=1))M / \$500M budget")
    println("Load shed: $(results[:total_load_shed]) MW")
    results
end

# ---------------------------------------------------------------------------
# Example 16: Auto-Plotting via opt_parameters
# ---------------------------------------------------------------------------
run_example(16, "Auto-Plotting via opt_parameters") do
    mkpath("figures/rts_run1")
    opt_parameters = Dict(
        :network => "RTS",
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :battery_enabled => true,
        :battery_cost_per_pu => 2e7,
        :infrastructure_budget => 500e6,
        :plots => "all",
        :plot_dir => "figures/rts_run1"
    )
    results = solve_ots(opt_parameters)
    plot_files = readdir("figures/rts_run1")
    println("Plot files created: $(length(plot_files))")
    for f in plot_files
        println("  $f")
    end
    results
end

# ---------------------------------------------------------------------------
# Example 17: Solar PV Installation with Reactive Power Support (LACOTS)
# ---------------------------------------------------------------------------
run_example(17, "Solar PV with Reactive Power Support (LACOTS)") do
    opt_parameters = Dict(
        :network => "RTS",
        :model => "LACOTS",
        :objective => "loadshed",
        :times => [(2020, 6, 15)],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => 0.75,
        :solar_enabled => true,
        :solar_cost_per_pu => 5e7,
        :solar_data_path => "test_data/solar_data/RTS/solar_data.csv",
        :infrastructure_budget => 500e6,
        :linearized_solar_power => true
    )
    results = solve_ots(opt_parameters)
    println("Solar installed: $(length(results[:solar_installed])) buses")
    println("Total capacity: $(round(results[:total_solar_capacity]*100, digits=1)) MW")
    println("Total P generation: $(round(results[:total_solar_generation], digits=2)) p.u.·h")
    println("Total Q injection: $(round(results[:total_solar_q_injection], digits=2)) p.u.·h")
    println("Solar cost: \$$(round(results[:solar_cost]/1e6, digits=1))M")
    if !isempty(results[:solar_installed])
        bus = results[:solar_installed][1]
        cap = results[:s][bus]
        println("\nBus $bus ($(round(cap*100, digits=1)) MW) sample hours:")
        for t in [1, 6, 12, 18, 24]
            p = round(results[:p_solar][(1, t, bus)], digits=4)
            q = round(results[:q_solar][(1, t, bus)], digits=4)
            println("  Hour $t: P=$p, Q=$q")
        end
    end
    results
end

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
println("\n" * "="^60)
println("SUMMARY: $pass_count passed, $fail_count failed")
println("="^60)
