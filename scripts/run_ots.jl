#!/usr/bin/env julia

"""
Command-line interface for GridPlanning package.
Run wildfire-aware transmission switching optimizations from the terminal.

Usage:
    julia --project=. scripts/run_ots.jl --network RTS --objective loadshed --date 2021-07-15
"""

using ArgParse
using GridPlanning
using Dates
using Printf

function parse_commandline()
    s = ArgParseSettings(description = "Wildfire-aware optimal transmission switching")

    @add_arg_table! s begin
        "--network", "-n"
            help = "Network name (RTS, CATS, Texas7k, Texas2k, WECC10k, WECC240)"
            arg_type = String
            required = true

        "--objective", "-o"
            help = "Objective function (loadshed, wildfire, cost, tradeoff)"
            arg_type = String
            required = true

        "--model", "-m"
            help = "Model type (DCOTS or LACOTS)"
            arg_type = String
            default = "DCOTS"

        "--method"
            help = "Solution method (optimal or thresholded)"
            arg_type = String
            default = "optimal"

        # Date specification (mutually exclusive handled in logic)
        "--date", "-d"
            help = "Single date (YYYY-MM-DD)"
            arg_type = String

        "--dates"
            help = "Multiple dates comma-separated (YYYY-MM-DD,YYYY-MM-DD,...)"
            arg_type = String

        "--month"
            help = "Full month (e.g., 'June 2021')"
            arg_type = String

        "--year", "-y"
            help = "Full year (e.g., '2020')"
            arg_type = String

        # Method-specific parameters
        "--threshold"
            help = "Absolute risk threshold (for thresholded method)"
            arg_type = Float64

        "--threshold-pct"
            help = "Percentage risk threshold, 0-1 (for thresholded method)"
            arg_type = Float64

        # Objective-specific parameters
        "--tradeoff-weight", "-w"
            help = "Tradeoff weight, 0=loadshed only, 1=wildfire only (for tradeoff objective)"
            arg_type = Float64
            default = 0.5

        "--voll"
            help = "Value of lost load in USD/MWh (for cost objective)"
            arg_type = Float64
            default = 10000.0

        # CATS-specific
        "--risk-metric"
            help = "Risk metric for CATS (max_wfpi, mean_wfpi, cum_wfpi)"
            arg_type = String
            default = "cum_wfpi"

        # Solver parameters
        "--time-limit", "-t"
            help = "Solver time limit in seconds"
            arg_type = Float64
            default = 86400.0

        "--mip-gap"
            help = "MIP optimality gap (0.01 = 1%)"
            arg_type = Float64
            default = 0.01

        # Output options
        "--save", "-s"
            help = "Save results to file (JLD2 or TXT based on extension)"
            arg_type = String

        "--quiet", "-q"
            help = "Suppress detailed output"
            action = :store_true

        "--T"
            help = "Hours per day"
            arg_type = Int
            default = 24

        # Hardening parameters
        "--hardening"
            help = "Enable line hardening (undergrounding)"
            action = :store_true

        "--hardening-effectiveness"
            help = "Risk reduction effectiveness, 0-1 (1.0 = full mitigation)"
            arg_type = Float64
            default = 1.0

        "--hardening-cost-per-mile"
            help = "Hardening cost per mile in USD (default: \$7M)"
            arg_type = Float64
            default = 7e6

        "--hardening-no-enforce-energization"
            help = "Allow hardened lines to be de-energized (default: hardened lines must stay energized)"
            action = :store_true

        # Battery parameters
        "--battery"
            help = "Enable battery energy storage installation"
            action = :store_true

        "--battery-cost-per-pu"
            help = "Battery cost per p.u. (100MWh) in USD (default: \$100M)"
            arg_type = Float64
            default = 1e8

        "--battery-charge-efficiency"
            help = "Battery charging efficiency, 0-1 (default: 0.95)"
            arg_type = Float64
            default = 0.95

        "--battery-discharge-efficiency"
            help = "Battery discharging efficiency, 0-1 (default: 0.95)"
            arg_type = Float64
            default = 0.95

        "--battery-charge-rate"
            help = "Max charge rate as fraction of capacity (default: 1.0)"
            arg_type = Float64
            default = 1.0

        "--battery-discharge-rate"
            help = "Max discharge rate as fraction of capacity (default: 1.0)"
            arg_type = Float64
            default = 1.0

        "--battery-max-network"
            help = "Network-wide battery capacity limit in p.u. (default: unlimited)"
            arg_type = Float64

        "--battery-max-per-node"
            help = "Per-node battery capacity limit in p.u. (default: 10000)"
            arg_type = Float64

        "--battery-exclusive-operation"
            help = "Limit simultaneous charging and discharging"
            action = :store_true

        "--battery-candidate-buses"
            help = "Comma-separated bus IDs for battery candidates, or 'load_buses'"
            arg_type = String

        "--linearized-battery-power"
            help = "Use linear (true) or nonlinear (false) reactive power for LACOTS batteries (default: true)"
            arg_type = Bool
            default = true

        # Solar parameters
        "--solar"
            help = "Enable solar PV installation"
            action = :store_true

        "--solar-cost-per-pu"
            help = "Solar cost per p.u. (100MW) in USD (default: \$100M)"
            arg_type = Float64
            default = 1e8

        "--solar-data-path"
            help = "Path to CSV with hourly solar capacity factors"
            arg_type = String

        "--solar-capacity-factor-default"
            help = "Default capacity factor if no data provided, 0-1 (default: 0.3)"
            arg_type = Float64
            default = 0.3

        "--solar-max-network"
            help = "Network-wide solar capacity limit in p.u. (default: unlimited)"
            arg_type = Float64

        "--solar-max-per-node"
            help = "Per-node solar capacity limit in p.u. (default: 10000)"
            arg_type = Float64

        "--solar-candidate-buses"
            help = "Comma-separated bus IDs for solar candidates"
            arg_type = String

        "--linearized-solar-power"
            help = "Use linear (true) or nonlinear (false) inverter capability for LACOTS solar (default: true)"
            arg_type = Bool
            default = true

        # Shared infrastructure budget
        "--infrastructure-budget"
            help = "Shared budget for batteries + solar + hardening in USD (default: \$1B for non-cost, unlimited for cost)"
            arg_type = Float64
    end

    return parse_args(s)
end

function parse_times(args::Dict)
    """Convert CLI date arguments to times format"""
    if args["date"] !== nothing
        # Single date: YYYY-MM-DD
        date_str = args["date"]
        y, m, d = parse.(Int, split(date_str, '-'))
        return [(y, m, d)]

    elseif args["dates"] !== nothing
        # Multiple dates: YYYY-MM-DD,YYYY-MM-DD,...
        dates_str = args["dates"]
        date_list = split(dates_str, ',')
        return [tuple(parse.(Int, split(strip(ds), '-'))...) for ds in date_list]

    elseif args["month"] !== nothing
        # Full month: "June 2021"
        return args["month"]

    elseif args["year"] !== nothing
        # Full year: "2020"
        return args["year"]

    else
        error("Must specify one of: --date, --dates, --month, or --year")
    end
end

function build_opt_parameters(args::Dict)
    """Build opt_parameters dictionary from CLI arguments"""

    # Parse times
    times = parse_times(args)

    # Build basic parameters
    opt_parameters = Dict(
        :network => args["network"],
        :model => args["model"],
        :objective => args["objective"],
        :times => times,
        :switching_method => args["method"],
        :T => args["T"],
        :time_limit => args["time-limit"],
        :mip_gap => args["mip-gap"]
    )

    # Add method-specific parameters
    if args["method"] == "thresholded"
        if args["threshold"] !== nothing
            opt_parameters[:threshold] = args["threshold"]
        elseif args["threshold-pct"] !== nothing
            opt_parameters[:threshold_pct] = args["threshold-pct"]
        else
            error("Thresholded method requires --threshold or --threshold-pct")
        end
    end

    # Add objective-specific parameters
    if args["objective"] == "tradeoff"
        opt_parameters[:tradeoff_weight] = args["tradeoff-weight"]
    elseif args["objective"] == "cost"
        opt_parameters[:voll] = args["voll"]
    end

    # Add CATS-specific parameter
    if uppercase(args["network"]) in ["CATS", "CALIFORNIATESTS"]
        opt_parameters[:risk_metric] = args["risk-metric"]
    end

    # Add output parameters
    if args["save"] !== nothing
        save_path = args["save"]
        if endswith(save_path, ".jld2")
            opt_parameters[:output_format] = "jld2"
        elseif endswith(save_path, ".txt")
            opt_parameters[:output_format] = "txt"
        else
            error("Save path must end with .jld2 or .txt")
        end
        opt_parameters[:output_path] = save_path
    end

    # Add hardening parameters
    if args["hardening"]
        opt_parameters[:hardening_enabled] = true
        opt_parameters[:hardening_effectiveness] = args["hardening-effectiveness"]
        opt_parameters[:hardening_cost_per_mile] = args["hardening-cost-per-mile"]
        opt_parameters[:hardening_enforce_energization] = !args["hardening-no-enforce-energization"]

    end

    # Add battery parameters
    if args["battery"]
        opt_parameters[:battery_enabled] = true
        opt_parameters[:battery_cost_per_pu] = args["battery-cost-per-pu"]
        opt_parameters[:battery_charge_efficiency] = args["battery-charge-efficiency"]
        opt_parameters[:battery_discharge_efficiency] = args["battery-discharge-efficiency"]
        opt_parameters[:battery_charge_rate] = args["battery-charge-rate"]
        opt_parameters[:battery_discharge_rate] = args["battery-discharge-rate"]
        opt_parameters[:battery_exclusive_operation] = args["battery-exclusive-operation"]
        opt_parameters[:linearized_battery_power] = args["linearized-battery-power"]

        if args["battery-max-network"] !== nothing
            opt_parameters[:battery_max_network] = args["battery-max-network"]
        end
        if args["battery-max-per-node"] !== nothing
            opt_parameters[:battery_max_per_node] = args["battery-max-per-node"]
        end
        if args["battery-candidate-buses"] !== nothing
            val = args["battery-candidate-buses"]
            if lowercase(val) == "load_buses" || lowercase(val) == "load buses"
                opt_parameters[:battery_candidate_buses] = "load buses"
            else
                opt_parameters[:battery_candidate_buses] = parse.(Int, split(val, ','))
            end
        end
    end

    # Add solar parameters
    if args["solar"]
        opt_parameters[:solar_enabled] = true
        opt_parameters[:solar_cost_per_pu] = args["solar-cost-per-pu"]
        opt_parameters[:solar_capacity_factor_default] = args["solar-capacity-factor-default"]
        opt_parameters[:linearized_solar_power] = args["linearized-solar-power"]

        if args["solar-data-path"] !== nothing
            opt_parameters[:solar_data_path] = args["solar-data-path"]
        end
        if args["solar-max-network"] !== nothing
            opt_parameters[:solar_max_network] = args["solar-max-network"]
        end
        if args["solar-max-per-node"] !== nothing
            opt_parameters[:solar_max_per_node] = args["solar-max-per-node"]
        end
        if args["solar-candidate-buses"] !== nothing
            opt_parameters[:solar_candidate_buses] = parse.(Int, split(args["solar-candidate-buses"], ','))
        end
    end

    # Add shared infrastructure budget
    if args["infrastructure-budget"] !== nothing
        opt_parameters[:infrastructure_budget] = args["infrastructure-budget"]
    end

    return opt_parameters
end

function print_results_summary(results::Dict, quiet::Bool=false)
    """Print a formatted summary of optimization results"""

    if quiet
        # Minimal output
        @printf("Status: %s | Time: %.2fs | Load Shed: %.2f MW | Risk Reduction: %.1f%%\n",
                results[:status], results[:solve_time],
                results[:total_load_shed], results[:risk_reduction_pct])
        return
    end

    # Detailed output
    println("\n" * "="^70)
    println("OPTIMIZATION RESULTS")
    println("="^70)

    println("\n📊 Solution Status")
    @printf("   Status:          %s\n", results[:status])
    @printf("   Solve Time:      %.2f seconds\n", results[:solve_time])
    @printf("   Method:          %s\n", results[:switching_method])
    @printf("   Objective Value: %.4f\n", results[:objective_value])

    println("\n⚡ Load Shedding")
    @printf("   Total Load Shed: %.2f MW\n", results[:total_load_shed])

    println("\n🔥 Wildfire Risk")
    @printf("   Total Risk:      %.2f\n", results[:total_risk])
    @printf("   Active Risk:     %.2f\n", results[:active_risk])
    @printf("   Removed Risk:    %.2f\n", results[:removed_risk])
    @printf("   Risk Reduction:  %.1f%%\n", results[:risk_reduction_pct])

    println("\n🔌 Line Switching")
    total_switched = sum(length(lines) for lines in values(results[:switched_off_lines]))
    println("   Total Lines Switched Off: $total_switched")

    # Hardening results (if applicable)
    if haskey(results, :hardened_lines)
        println("\n🛡️  Line Hardening")
        @printf("   Lines Hardened:      %d\n", length(results[:hardened_lines]))
        @printf("   Hardening Cost:      \$%.2fM\n", results[:hardening_cost] / 1e6)
        @printf("   Risk Mitigated:      %.2f\n", results[:mitigated_risk])
        if results[:total_risk] > 0
            mitigated_pct = (results[:mitigated_risk] / results[:total_risk]) * 100
            @printf("   Risk Mitigation:     %.1f%%\n", mitigated_pct)
        end
    end

    # Battery results (if applicable)
    if haskey(results, :batteries_installed)
        println("\n🔋 Battery Storage")
        @printf("   Buses Installed:     %d\n", length(results[:batteries_installed]))
        @printf("   Total Capacity:      %.1f MWh (%.4f p.u.)\n",
                results[:total_battery_capacity] * 100, results[:total_battery_capacity])
        @printf("   Battery Cost:        \$%.2fM\n", results[:battery_cost] / 1e6)
    end

    # Solar results (if applicable)
    if haskey(results, :solar_installed)
        println("\n☀️  Solar PV")
        @printf("   Buses Installed:     %d\n", length(results[:solar_installed]))
        @printf("   Total Capacity:      %.1f MW (%.4f p.u.)\n",
                results[:total_solar_capacity] * 100, results[:total_solar_capacity])
        @printf("   Solar Cost:          \$%.2fM\n", results[:solar_cost] / 1e6)
        @printf("   Total Generation:    %.4f p.u.·h\n", results[:total_solar_generation])
        if haskey(results, :total_solar_q_injection)
            @printf("   Total Q Injection:   %.4f p.u.·h\n", results[:total_solar_q_injection])
        end
    end

    if haskey(results, :output_path) && results[:output_path] !== nothing
        println("\n💾 Saved Results")
        println("   File: $(results[:output_path])")
    end

    println("\n" * "="^70)
end

function main()
    # Parse command-line arguments
    args = parse_commandline()

    # Build opt_parameters dictionary
    opt_parameters = build_opt_parameters(args)

    # Print configuration
    if !args["quiet"]
        println("="^70)
        println("WILDFIRE SWITCHING OPTIMIZATION")
        println("="^70)
        println("\n🌐 Network:   $(args["network"])")
        println("📐 Model:     $(args["model"])")
        println("🎯 Objective: $(args["objective"])")
        println("⚙️  Method:    $(args["method"])")
        println("\nRunning optimization...\n")
    end

    # Run optimization
    try
        results = solve_ots(opt_parameters)

        # Print results
        print_results_summary(results, args["quiet"])

        return 0
    catch e
        println("\n❌ ERROR: $e")
        if !isa(e, InterruptException)
            println("\nStacktrace:")
            for (exc, bt) in Base.catch_stack()
                showerror(stdout, exc, bt)
                println()
            end
        end
        return 1
    end
end

# Run main function if script is executed directly
if abspath(PROGRAM_FILE) == @__FILE__
    exit(main())
end
