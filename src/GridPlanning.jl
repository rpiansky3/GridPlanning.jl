module GridPlanning

using JuMP
using Gurobi
using PowerModels
using CSV
using DataFrames
using Dates
using JLD2
using Printf
using HTTP
using JSON
using Logging
using Plots
using Shapefile
using DBFTables
using GeoInterface

# Include source files
include("preprocessing.jl")
include("solar_data.jl")
include("census_data.jl")
include("population_assignment.jl")
include("add_variables.jl")
include("add_constraints.jl")
include("add_objective.jl")
include("base_OPS.jl")
include("save_results.jl")
include("plotting_helpers.jl")
include("plotting.jl")

# Export main interface
export solve_ots, load_txt, get_network_solar_data, get_network_census, plot_results,
       load_census_data

"""
    _maybe_plot_results(results::Dict, opt_parameters::Dict)

Called automatically by solve_ots when :plots is set. Selects the appropriate
feature list from :plots and saves output to :plot_dir.

NOTE: Called on the raw results dict before format_output. This is safe because
format_output (save_results.jl) never mutates the dict — it only writes to file
and returns results unchanged. All plotting keys (:network, :times,
:batteries_installed, etc.) are populated by run_optimization.
"""
function _maybe_plot_results(results::Dict, opt_parameters::Dict)
    plots_val = get(opt_parameters, :plots, false)
    (plots_val == false || plots_val == "none") && return

    plot_dir = get(opt_parameters, :plot_dir, "")
    output_dir = isempty(plot_dir) ? "." : plot_dir

    has_batteries = haskey(results, :batteries_installed) && !isempty(results[:batteries_installed])
    has_solar     = haskey(results, :solar_installed)     && !isempty(results[:solar_installed])

    geo_features = [:network_overview]
    ts_features  = Symbol[:load_shed_timeseries]
    has_batteries && push!(ts_features, :battery_dispatch)
    has_solar     && push!(ts_features, :solar_generation)

    features = if plots_val == "inv_only"
        geo_features
    elseif plots_val == "timeseries_only"
        ts_features
    else  # "all"
        vcat(geo_features, ts_features)
    end

    mkpath(output_dir)
    try
        plot_results(results, features; output_dir=output_dir)
    catch e
        @warn "Auto-plot generation failed: $e"
    end
end

"""
    solve_ots(opt_parameters::Dict)

Solve an Optimal Transmission Switching problem with wildfire risk considerations.

# Required Parameters
- `:network` => String - Network name (e.g., "RTS", "CATS", "Texas7k", "Texas2k", "WECC240")
- `:model` => String - "DCOTS" or "LACOTS"
- `:objective` => String - "loadshed", "wildfire", "cost", or "tradeoff"
- `:times` => Array or String - Time specification:
    - Array of tuples: [(year, month, day), ...]
    - Year string: "2020"
    - Month string: "June 2021"

# Optional Parameters
- `:switching_method` => String - Solution method: "optimal" (default) or "thresholded"
- `:wildfire_data` => Dict - Wildfire risk data (line_id => risk_value). Auto-loaded from data/USGS_FPI if not provided
- `:risk_metric` => String - For CATS: risk metric to use ("max_wfpi", "mean_wfpi", "cum_wfpi", etc.) (default: "cum_wfpi")
- `:T` => Int - Hours per day (default: 24)
- `:tradeoff_weight` => Float64 - For "tradeoff" objective, 0=loadshed, 1=wildfire (default: 0.5)
- `:threshold` => Float64 - Risk threshold (loadshed obj) or loadshed threshold (wildfire obj). Required for "thresholded" method.
- `:threshold_pct` => Float64 - Percentage threshold (0.8 = keep 80% of risk, remove 20%)
- `:voll` => Float64 - Value of Lost Load in \$/MWh for "cost" objective (default: 10000.0)
- `:warm_start` => Dict or String - For LACOTS: warm start values or "auto" to run DCOTS first
- `:non_linear` => Bool - For LACOTS: use non-linear apparent power constraints (default: false)
- `:time_limit` => Float64 - Solver time limit in seconds (default: 86400.0)
- `:mip_gap` => Float64 - MIP optimality gap (default: 0.01)
- `:output_format` => String - "dict", "jld2", or "txt" (default: "dict")
- `:output_path` => String - File path for output (required if format is "jld2" or "txt")
- `:lp_str` => String - If provided, save the optimization model to an LP file at this path (default: "")
- `:log_str` => String - If provided, save Gurobi solver log output to a file at this path (default: "")

# Returns
Results dictionary or writes to file based on output_format
"""
function solve_ots(opt_parameters::Dict)
    # Validate required parameters
    validate_parameters!(opt_parameters)

    # Set defaults for optional parameters
    set_defaults!(opt_parameters)

    # Preprocess: parse times, load data, generate loads
    preprocessed_data = preprocess(opt_parameters)

    # Convert percentage threshold to absolute value if specified
    convert_percentage_threshold!(opt_parameters)

    # Run optimization
    results = run_optimization(opt_parameters, preprocessed_data)

    # Auto-generate plots if requested (before format_output; safe because
    # format_output never mutates the dict)
    _maybe_plot_results(results, opt_parameters)

    # Handle output
    output = format_output(results, opt_parameters)

    return output
end

"""
    validate_parameters!(opt_parameters::Dict)

Validate that all required parameters are present and have valid values.
"""
function validate_parameters!(opt_parameters::Dict)
    # wildfire_data is now optional - it will be auto-loaded from data/USGS_FPI
    required_keys = [:network, :model, :objective, :times]

    for key in required_keys
        if !haskey(opt_parameters, key)
            error("Missing required parameter: $key")
        end
    end

    # Validate model type
    if !(opt_parameters[:model] in ["DCOTS", "LACOTS"])
        error("Invalid model type: $(opt_parameters[:model]). Must be 'DCOTS' or 'LACOTS'")
    end

    # Validate switching method type (optional parameter, defaults to "optimal")
    # Controls whether line switching is optimized or computed via threshold heuristic
    if haskey(opt_parameters, :switching_method)
        if !(opt_parameters[:switching_method] in ["optimal", "thresholded"])
            error("Invalid switching_method: $(opt_parameters[:switching_method]). Must be 'optimal' or 'thresholded'")
        end
    end

    # Validate objective type
    valid_objectives = ["loadshed", "wildfire", "cost", "tradeoff"]
    if !(opt_parameters[:objective] in valid_objectives)
        error("Invalid objective: $(opt_parameters[:objective]). Must be one of: $valid_objectives")
    end

    # Validate threshold requirement for thresholded switching method
    if haskey(opt_parameters, :switching_method) && opt_parameters[:switching_method] == "thresholded"
        if !haskey(opt_parameters, :threshold) && !haskey(opt_parameters, :threshold_pct)
            error("thresholded switching method requires either :threshold or :threshold_pct parameter")
        end
    end

    # Validate tradeoff weight if applicable
    if opt_parameters[:objective] == "tradeoff"
        if !haskey(opt_parameters, :tradeoff_weight)
            error("tradeoff_weight required for 'tradeoff' objective")
        end
        w = opt_parameters[:tradeoff_weight]
        if !(0 <= w <= 1)
            error("tradeoff_weight must be between 0 and 1, got: $w")
        end
    end

    # Validate output path if needed
    if haskey(opt_parameters, :output_format) && opt_parameters[:output_format] in ["jld2", "txt"]
        if !haskey(opt_parameters, :output_path) || opt_parameters[:output_path] === nothing
            error("output_path required for output_format '$(opt_parameters[:output_format])'")
        end
    end

    # Validate :plots parameter
    if haskey(opt_parameters, :plots)
        v = opt_parameters[:plots]
        valid_plots = [false, "none", "all", "inv_only", "timeseries_only"]
        if v ∉ valid_plots
            error("Invalid :plots value: $v. Must be one of: false, \"none\", \"all\", \"inv_only\", \"timeseries_only\"")
        end
    end
end

"""
    set_defaults!(opt_parameters::Dict)

Set default values for optional parameters.
"""
function set_defaults!(opt_parameters::Dict)
    defaults = Dict(
        :switching_method => "optimal", # "optimal" or "thresholded"
        :T => 24,
        :tradeoff_weight => 0.5,
        :threshold => nothing,
        :voll => 10000.0,
        :warm_start => nothing,
        :non_linear => false,
        :time_limit => 86400.0,
        :mip_gap => 0.01,
        :output_format => "dict",
        :output_path => nothing,
        :risk_metric => "cum_wfpi",  # For CATS: max_wfpi, mean_wfpi, cum_wfpi, etc.
        :wildfire_data => nothing,    # Will be auto-loaded if not provided
        :lp_str => "",                # If provided, save model to LP file at this path
        :log_str => "",               # If provided, save Gurobi log to file at this path
        :plots => false,              # false/"none"/"all"/"inv_only"/"timeseries_only"
        :plot_dir => "",              # "" = current dir, or a path string
        :data_dir => "data"           # Root data directory; use "test_data" for the reference subset
    )

    for (key, value) in defaults
        if !haskey(opt_parameters, key)
            opt_parameters[key] = value
        end
    end
end

"""
    convert_percentage_threshold!(opt_parameters::Dict)

Convert percentage-based threshold to absolute value if :threshold_pct is specified.
threshold_pct is the percentage of total risk that should remain energized (active risk).
For example, threshold_pct = 0.8 means keep active risk <= 80% of total risk (remove 20%).
"""
function convert_percentage_threshold!(opt_parameters::Dict)
    if haskey(opt_parameters, :threshold_pct) && opt_parameters[:threshold_pct] !== nothing
        pct = opt_parameters[:threshold_pct]
        wf_data = opt_parameters[:wildfire_data]

        # Calculate total risk across all days
        D = length(wf_data)
        total_risk = sum(sum(values(wf_data[d])) for d in 1:D)

        # Set absolute threshold as percentage of total risk
        # threshold_pct = 0.8 means active risk should be <= 80% of total
        # (i.e., remove at least 20% of risk)
        absolute_threshold = pct * total_risk

        println("Converting threshold percentage $(pct*100)% to absolute value: $(round(absolute_threshold, digits=0))")
        println("Total risk: $(round(total_risk, digits=0))")

        opt_parameters[:threshold] = absolute_threshold
    end
end

function __init__()
    with_logger(NullLogger()) do
        PowerModels.silence()
    end
end

end # module
