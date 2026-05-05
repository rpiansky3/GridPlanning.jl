"""
Preprocessing functions for data loading, time parsing, and load generation.
"""

"""
    tighten_branch_limits!(ref::Dict)

Tighten each branch's thermal limit (rate_a) using DC power flow physics.
The maximum power a branch can carry is bounded by |b| * max_angle_diff regardless
of the rated thermal limit, so we set rate_a = min(rate_a, |b| * max_angle_diff).
This also sets rate_a for branches that have none in the network file.
"""
function tighten_branch_limits!(ref::Dict)
    for (l, branch) in ref[:branch]
        _, b = PowerModels.calc_branch_y(branch)
        ang_bound = max(abs(get(branch, "angmin", -π)), abs(get(branch, "angmax", π)))
        btheta_bound = abs(b) * ang_bound
        current_rate_a = get(branch, "rate_a", Inf)
        branch["rate_a"] = min(current_rate_a, btheta_bound)
    end
end

"""
    preprocess(opt_parameters::Dict) -> Dict

Main preprocessing function that orchestrates all data loading and preparation.
Returns a dictionary containing all preprocessed data needed for optimization.
"""
function preprocess(opt_parameters::Dict)
    # Validate hardening parameters early (sets defaults)
    validate_hardening_parameters(opt_parameters)

    # Validate battery parameters early (sets defaults)
    validate_battery_parameters(opt_parameters)

    # Validate solar parameters early (sets defaults)
    validate_solar_parameters(opt_parameters)

    # Parse times into array of (year, month, day) tuples
    times_array = parse_times(opt_parameters[:times])
    D = length(times_array)  # Number of days
    T = opt_parameters[:T]   # Hours per day

    # Resolve data directory (default: "data"; use "test_data" for reference subset)
    data_dir = get(opt_parameters, :data_dir, "data")

    # Load network data
    network_name = opt_parameters[:network]
    network_data = load_network(network_name, data_dir)

    # Detect if CATS network
    is_cats = occursin("California", network_name) || occursin("CATS", network_name)

    # Build reference dictionary
    ref = PowerModels.build_ref(network_data)[:it][:pm][:nw][0]
    tighten_branch_limits!(ref)

    # Prepare data structure
    preprocessed = Dict(
        :times_array => times_array,
        :D => D,
        :T => T,
        :network_data => network_data,
        :base_ref => ref,
        :is_cats => is_cats,
        :hourly_refs => Dict(),
        :hourly_loads => Dict()
    )

    # Load CATS-specific data if needed
    if is_cats
        cats_data = load_cats_data(data_dir)
        preprocessed[:cats_data] = cats_data
        preprocessed[:load_mapping] = map_buses_to_loads(network_data)
        preprocessed[:bad_lines] = identify_bad_lines(ref)

        # Generate hourly refs for each day and hour
        for d in 1:D
            year, month, day = times_array[d]
            preprocessed[:hourly_refs][d] = Dict()
            preprocessed[:hourly_loads][d] = Dict()

            for t in 1:T
                # Calculate hour of year using 2019 (the year of CATS production data),
                # so runs on other years still index correctly into the 2019 time-series.
                hour_of_year = calculate_hour_of_year(2019, month, day, t)

                # Update network data for this hour
                network_copy = deepcopy(network_data)
                update_cats_network!(network_copy, hour_of_year, cats_data, preprocessed[:load_mapping])

                # Build reference for this hour
                preprocessed[:hourly_refs][d][t] = PowerModels.build_ref(network_copy)[:it][:pm][:nw][0]
                tighten_branch_limits!(preprocessed[:hourly_refs][d][t])
            end
        end
    else
        # Generate synthetic loads for non-CATS networks
        for d in 1:D
            year, month, day = times_array[d]
            preprocessed[:hourly_loads][d] = generate_loads(ref, year, month, day)
        end
    end

    # Load wildfire data if not provided
    if haskey(opt_parameters, :risk_per_line) && opt_parameters[:risk_per_line] !== nothing
        # User provided custom risk data - validate structure
        validate_risk_per_line(opt_parameters[:risk_per_line], D)
        opt_parameters[:wildfire_data] = opt_parameters[:risk_per_line]
        preprocessed[:wildfire_data_loaded] = false
        println("✓ Using user-provided risk_per_line data")
    elseif haskey(opt_parameters, :wildfire_data) && opt_parameters[:wildfire_data] !== nothing
        # Legacy parameter support (backward compatibility)
        validate_risk_per_line(opt_parameters[:wildfire_data], D)
        preprocessed[:wildfire_data_loaded] = false
        println("✓ Using user-provided wildfire_data (legacy parameter)")
    else
        # Auto-load from files
        risk_metric = get(opt_parameters, :risk_metric, "cum_wfpi")
        wildfire_data = load_wildfire_data(network_name, times_array, ref, is_cats, risk_metric, data_dir)
        opt_parameters[:wildfire_data] = wildfire_data
        preprocessed[:wildfire_data_loaded] = true
    end

    # Determine hardenable lines and calculate line lengths if hardening is enabled
    if get(opt_parameters, :hardening_enabled, false)
        println("\n--- Preparing Hardening Infrastructure ---")

        # Determine which lines can be hardened
        hardenable_lines = determine_hardenable_lines(opt_parameters, opt_parameters[:wildfire_data])
        opt_parameters[:hardenable_lines] = hardenable_lines
        preprocessed[:hardenable_lines] = hardenable_lines

        # Load bus coordinates
        bus_data = load_bus_coordinates(network_name, data_dir)

        if isempty(bus_data)
            @warn "No bus coordinate data available. Line lengths will be set to 0."
        end

        # Calculate line lengths
        line_lengths = calculate_line_lengths(ref, bus_data)
        preprocessed[:line_lengths] = line_lengths

        # Report statistics
        num_lines = length(line_lengths)
        total_miles = sum(values(line_lengths))
        nonzero_lengths = count(>(0), values(line_lengths))

        println("\n--- Line Length Data Summary ---")
        println("✓ Calculated line lengths for $num_lines lines")
        println("  Total network length: $(round(total_miles, digits=1)) miles")
        println("  Lines with coordinates: $nonzero_lengths / $num_lines")

        # Calculate maximum possible hardening cost
        max_hardening_cost = sum(line_lengths[l] for l in hardenable_lines) * opt_parameters[:hardening_cost_per_mile]
        preprocessed[:max_hardening_cost] = max_hardening_cost

        println("\n--- Hardening Budget Analysis ---")
        println("  Hardenable lines: $(length(hardenable_lines))")
        total_hardenable_miles = sum(line_lengths[l] for l in hardenable_lines)
        println("  Total hardenable miles: $(round(total_hardenable_miles, digits=1))")
        println("  Max hardening cost: \$$(round(max_hardening_cost/1e9, digits=2))B")

        budget = opt_parameters[:hardening_budget]
        if budget < Inf
            budget_pct = 100.0 * budget / max_hardening_cost
            println("  Budget allows: $(round(budget_pct, digits=1))% of max hardening")
        end
    end

    # Determine battery candidate buses if battery planning is enabled
    if get(opt_parameters, :battery_enabled, false)
        println("\n--- Preparing Battery Infrastructure ---")

        # Determine which buses can have batteries
        battery_locs = determine_battery_candidate_buses(opt_parameters, ref)
        preprocessed[:battery_locs] = battery_locs

        println("✓ Battery candidate buses identified: $(length(battery_locs)) buses")
    end

    # Determine solar candidate buses and load capacity factors if solar planning is enabled
    if get(opt_parameters, :solar_enabled, false)
        println("\n--- Preparing Solar Infrastructure ---")

        solar_locs = determine_solar_candidate_buses(opt_parameters, ref)
        preprocessed[:solar_locs] = solar_locs

        solar_cf = load_solar_capacity_factors(opt_parameters, solar_locs, times_array, T)
        preprocessed[:solar_cf] = solar_cf

        println("✓ Solar candidate buses identified: $(length(solar_locs)) buses")
    end

    return preprocessed
end

"""
    parse_times(times_input) -> Vector{Tuple{Int,Int,Int}}

Parse times input into array of (year, month, day) tuples.
Supports:
- Array of tuples: [(2021, 7, 15), (2021, 7, 16)]
- Year string: "2020"
- Month string: "June 2021"
"""
function parse_times(times_input)
    if times_input isa Vector
        # Already an array of tuples
        return times_input
    elseif times_input isa String
        return parse_time_string(times_input)
    else
        error("Invalid times format. Expected array of tuples or string.")
    end
end

"""
    parse_time_string(time_str::String) -> Vector{Tuple{Int,Int,Int}}

Parse a time string like "2020" or "June 2021" into array of date tuples.
"""
function parse_time_string(time_str::String)
    time_str = strip(time_str)

    # Check if it's just a year (e.g., "2020")
    if occursin(r"^\d{4}$", time_str)
        year = parse(Int, time_str)
        return generate_year_dates(year)
    end

    # Check if it's a month and year (e.g., "June 2021" or "Jun 2021")
    month_names = Dict(
        "january" => 1, "jan" => 1,
        "february" => 2, "feb" => 2,
        "march" => 3, "mar" => 3,
        "april" => 4, "apr" => 4,
        "may" => 5,
        "june" => 6, "jun" => 6,
        "july" => 7, "jul" => 7,
        "august" => 8, "aug" => 8,
        "september" => 9, "sep" => 9, "sept" => 9,
        "october" => 10, "oct" => 10,
        "november" => 11, "nov" => 11,
        "december" => 12, "dec" => 12
    )

    parts = split(lowercase(time_str))
    if length(parts) == 2
        month_str = parts[1]
        year_str = parts[2]

        if haskey(month_names, month_str) && occursin(r"^\d{4}$", year_str)
            month = month_names[month_str]
            year = parse(Int, year_str)
            return generate_month_dates(year, month)
        end
    end

    error("Could not parse time string: '$time_str'. Expected format: '2020' or 'June 2021'")
end

"""
    generate_year_dates(year::Int) -> Vector{Tuple{Int,Int,Int}}

Generate all dates for a given year.
"""
function generate_year_dates(year::Int)
    dates = Tuple{Int,Int,Int}[]
    start_date = Date(year, 1, 1)
    end_date = Date(year, 12, 31)

    current = start_date
    while current <= end_date
        push!(dates, (Dates.year(current), Dates.month(current), Dates.day(current)))
        current += Dates.Day(1)
    end

    return dates
end

"""
    generate_month_dates(year::Int, month::Int) -> Vector{Tuple{Int,Int,Int}}

Generate all dates for a given month and year.
"""
function generate_month_dates(year::Int, month::Int)
    dates = Tuple{Int,Int,Int}[]
    start_date = Date(year, month, 1)
    end_date = Dates.lastdayofmonth(start_date)

    current = start_date
    while current <= end_date
        push!(dates, (Dates.year(current), Dates.month(current), Dates.day(current)))
        current += Dates.Day(1)
    end

    return dates
end

"""
    load_network(network_name::String) -> Dict

Load network data from data/networks/ directory.
Supports simplified names: "CATS", "RTS", "Texas7k", "Texas2k", "WECC10k", "WECC240"
"""
function load_network(network_name::String, data_dir::String="data")
    # Get the base path (parent of src/)
    base_path = dirname(@__DIR__)

    # Network name mapping (simplified name -> actual filename)
    network_mapping = Dict(
        "CATS" => "CaliforniaTestSystem.m",
        "CaliforniaTestSystem" => "CaliforniaTestSystem.m",
        "RTS" => "RTS_GMLC.m",
        "RTS_GMLC" => "RTS_GMLC.m",
        "Texas7k" => "Texas7k_20210804.m",
        "Texas2k" => "case_ACTIVSg2000.m",
        "ACTIVSg2000" => "case_ACTIVSg2000.m",
        "WECC10k" => "case_ACTIVSg10k.m",
        "ACTIVSg10k" => "case_ACTIVSg10k.m",
        "WECC240" => "pglib_opf_case240_pserc.m",
        "pserc240" => "pglib_opf_case240_pserc.m"
    )

    # Try to find the network file
    network_dir = joinpath(base_path, data_dir, "networks")

    # Check if it's a simplified name
    if haskey(network_mapping, network_name)
        network_file = joinpath(network_dir, network_mapping[network_name])
    else
        # Check for exact match
        network_file = joinpath(network_dir, network_name)
        if !isfile(network_file)
            # Try adding .m extension
            network_file = joinpath(network_dir, network_name * ".m")
        end
    end

    if !isfile(network_file)
        # List available networks
        available = filter(f -> endswith(f, ".m"), readdir(network_dir))
        available_simple = keys(network_mapping)
        error("Network file not found: $network_name\nAvailable simplified names: $(join(available_simple, ", "))\nAvailable files: $(join(available, ", "))")
    end

    return PowerModels.parse_file(network_file)
end

"""
    load_cats_data(data_dir="data") -> Dict

Load CATS-specific data (renewable generation, load scenarios, generator info).
"""
function load_cats_data(data_dir::String="data")
    base_path = dirname(@__DIR__)
    cats_dir = joinpath(base_path, data_dir, "CATS")

    # Load generator data
    gen_data = CSV.read(joinpath(cats_dir, "CATS_gens.csv"), DataFrame)

    # Load hourly production data (solar and wind)
    production_data = CSV.read(joinpath(cats_dir, "HourlyProduction2019.csv"), DataFrame)
    solar_generation = production_data[!, :Solar]
    wind_generation = production_data[!, :Wind]

    # Load hourly load scenarios
    load_scenarios = CSV.read(joinpath(cats_dir, "Load_Agg_Post_Assignment_v3_latest.csv"), DataFrame; header=false)
    load_scenarios = Matrix(load_scenarios)

    # Check for metadata (subset offset)
    hour_offset = 0
    metadata_path = joinpath(cats_dir, "cats_metadata.json")
    if isfile(metadata_path)
        meta_str = read(metadata_path, String)
        # Simple parse: extract hour_offset value
        m = match(r"\"hour_offset\"\s*:\s*(\d+)", meta_str)
        if m !== nothing
            hour_offset = parse(Int, m.captures[1])
        end
    end

    # Calculate total solar and wind capacity
    solar_cap = sum(gen_data[occursin.("solar", lowercase.(gen_data.FuelType)), :Pmax])
    wind_cap = sum(gen_data[occursin.("wind", lowercase.(gen_data.FuelType)), :Pmax])

    # Store original pmax values
    pmax_og = gen_data.Pmax

    return Dict(
        :gen_data => gen_data,
        :solar_generation => solar_generation,
        :wind_generation => wind_generation,
        :load_scenarios => load_scenarios,
        :solar_cap => solar_cap,
        :wind_cap => wind_cap,
        :pmax_og => pmax_og,
        :hour_offset => hour_offset
    )
end

"""
    map_buses_to_loads(network_data::Dict) -> Dict

Create mapping from bus IDs to load indices for CATS network.
"""
function map_buses_to_loads(network_data::Dict)
    load_mapping = Dict()
    for (i, l) in network_data["load"]
        load_bus = l["load_bus"]
        load_idx = l["index"]
        merge!(load_mapping, Dict(load_bus => load_idx))
    end
    return load_mapping
end

"""
    identify_bad_lines(ref::Dict) -> Vector

Identify transformer lines (zero reactance) that need special handling.
"""
function identify_bad_lines(ref::Dict)
    bad_lines = Int[]
    for (l, branch) in ref[:branch]
        if branch["br_x"] < 1e-4
            push!(bad_lines, l)
        end
    end
    return bad_lines
end

"""
    calculate_hour_of_year(year::Int, month::Int, day::Int, hour::Int) -> Int

Calculate the hour of the year (1-8760) for a given date and hour.
"""
function calculate_hour_of_year(year::Int, month::Int, day::Int, hour::Int)
    date = Date(year, month, day)
    day_of_year = Dates.dayofyear(date)
    return (day_of_year - 1) * 24 + hour
end

"""
    update_cats_network!(network_data::Dict, hour_of_year::Int, cats_data::Dict, load_mapping::Dict)

Update CATS network data for a specific hour (renewable generation and loads).
"""
function update_cats_network!(network_data::Dict, hour_of_year::Int, cats_data::Dict, load_mapping::Dict)
    # Apply hour offset for subsetted data
    adjusted_hour = hour_of_year - cats_data[:hour_offset]

    # Update renewable generation
    gen_data = cats_data[:gen_data]
    solar_gen = cats_data[:solar_generation][adjusted_hour]
    wind_gen = cats_data[:wind_generation][adjusted_hour]
    pmax_og = cats_data[:pmax_og]
    solar_cap = cats_data[:solar_cap]
    wind_cap = cats_data[:wind_cap]

    for j in 1:size(gen_data, 1)
        if occursin("solar", lowercase(gen_data[j, "FuelType"]))
            network_data["gen"][string(j)]["pmax"] = solar_gen / network_data["baseMVA"] * pmax_og[j] / solar_cap
        elseif occursin("wind", lowercase(gen_data[j, "FuelType"]))
            network_data["gen"][string(j)]["pmax"] = wind_gen / network_data["baseMVA"] * pmax_og[j] / wind_cap
        end
    end

    # Update loads
    load_scenarios = cats_data[:load_scenarios]
    for i in 1:size(load_scenarios, 1)
        load_split = split(load_scenarios[i, adjusted_hour], "+")
        P = parse(Float64, load_split[1])
        Q = parse(Float64, split(load_split[2], "i")[1])

        if haskey(load_mapping, i)
            if P / network_data["baseMVA"] <= 1e-4
                network_data["load"][string(load_mapping[i])]["pd"] = 0.0
            else
                network_data["load"][string(load_mapping[i])]["pd"] = P / network_data["baseMVA"]
            end
            network_data["load"][string(load_mapping[i])]["qd"] = Q / network_data["baseMVA"]
        end
    end
end

"""
    generate_loads(ref::Dict, year::Int, month::Int, day::Int) -> Dict

Generate synthetic hourly loads for non-CATS networks based on seasonal/daily patterns.
Returns Dict with "pd" and "qd" keys for active and reactive power loads.
"""
function generate_loads(ref::Dict, year::Int, month::Int, day::Int)
    # Table 1 - Hourly load factors (percentage of daily peak)
    hourly_loads = (1/100) .* [
        67  78  64  74  63  75;  # 12-1 am
        63  72  60  70  62  73;  # 1-2
        60  68  58  66  60  69;  # 2-3
        59  66  56  65  58  66;  # 3-4
        59  64  56  64  59  65;  # 4-5
        60  65  58  62  65  65;  # 5-6
        74  66  64  62  72  68;  # 6-7
        86  70  76  66  85  74;  # 7-8
        95  80  87  81  95  83;  # 8-9
        96  88  95  86  99  89;  # 9-10
        96  90  99  91 100  92;  # 10-11
        95  91 100  93  99  94;  # 11-noon
        95  90  99  93  93  91;  # Noon-1pm
        95  88 100  92  92  90;  # 1-2
        93  87 100  91  90  90;  # 2-3
        94  87  97  91  88  86;  # 3-4
        99  91  96  92  90  85;  # 4-5
       100 100  96  94  92  88;  # 5-6
       100  99  93  95  96  92;  # 6-7
        96  97  92  95  98 100;  # 7-8
        91  94  92 100  96  97;  # 8-9
        83  92  93  93  90  95;  # 9-10
        73  87  87  88  80  90;  # 10-11
        63  81  72  80  70  85   # 11-12
    ]

    # Table 2 - Weekly peak load (percentage of annual peak)
    weekly_loads = (1/100) .* [
        86.2, 90.0, 87.8, 83.4, 88.0, 84.1, 83.2, 80.6, 74.0, 73.7,
        71.5, 72.7, 70.4, 75.0, 72.1, 80.0, 75.4, 83.7, 87.0, 88.0,
        85.6, 81.1, 90.0, 88.7, 89.6, 86.1, 75.5, 81.6, 80.1, 88.0,
        72.2, 77.6, 80.0, 72.9, 72.6, 70.5, 78.0, 69.5, 72.4, 72.4,
        74.3, 74.4, 80.0, 88.1, 88.5, 90.9, 94.0, 89.0, 94.2, 97.0,
        100.0, 95.2
    ]

    # Table 3 - Daily load (percentage of weekly peak)
    daily_loads = (1/100) .* [93, 100, 98, 96, 94, 77, 75]  # Mon-Sun

    # Calculate load multiplication factors
    date = Date(year, month, day)
    dayofweek = Dates.dayofweek(date)
    weeknumber = Dates.week(date)
    if weeknumber > 52
        weeknumber = weeknumber % 52
    end

    # Determine season and weekday/weekend
    if weeknumber in vcat(collect(1:8), collect(44:52))  # Winter
        hourlycol = dayofweek in [6, 7] ? 2 : 1
    elseif weeknumber in collect(18:30)  # Summer
        hourlycol = dayofweek in [6, 7] ? 4 : 3
    else  # Spring/Fall
        hourlycol = dayofweek in [6, 7] ? 6 : 5
    end

    # Calculate total multiplication factor
    load_mult_factor = hourly_loads[:, hourlycol] .* daily_loads[dayofweek] .* weekly_loads[weeknumber]

    # Apply to each bus - generate both pd and qd
    bus_names = sort([bus for bus in keys(ref[:bus])])
    loads = Dict(
        "pd" => Dict(i => Array{Float64,1}() for i in bus_names),
        "qd" => Dict(i => Array{Float64,1}() for i in bus_names)
    )

    for i in bus_names
        # Active power loads
        sum_of_p_loads = reduce(+, ref[:load][j]["pd"] for j in ref[:bus_loads][i]; init=0.0)
        if sum_of_p_loads < 0.0
            sum_of_p_loads = 0.0
        end
        loads["pd"][i] = sum_of_p_loads .* load_mult_factor

        # Reactive power loads
        sum_of_q_loads = reduce(+, ref[:load][j]["qd"] for j in ref[:bus_loads][i]; init=0.0)
        if sum_of_q_loads < 0.0
            sum_of_q_loads = 0.0
        end
        loads["qd"][i] = sum_of_q_loads .* load_mult_factor
    end

    return loads
end

"""
    load_wildfire_data(network_name, times_array, ref, is_cats, risk_metric) -> Dict

Load wildfire risk data for the given network and time periods.
Returns a dictionary indexed by day: Dict{Int, Dict{Int, Float64}} where:
- Outer key: day index (1 to D)
- Inner dict: line_id => risk_value for that specific day
"""
function load_wildfire_data(network_name::String, times_array::Vector, ref::Dict, is_cats::Bool, risk_metric::String, data_dir::String="data")
    base_path = dirname(@__DIR__)
    wf_dir = joinpath(base_path, data_dir, "USGS_FPI")

    if is_cats
        return load_cats_wildfire_data(wf_dir, times_array, ref, risk_metric)
    else
        # Map network names to FPI directory names
        network_fpi_name = get_network_fpi_name(network_name)
        return load_standard_wildfire_data(wf_dir, network_fpi_name, times_array, ref, risk_metric)
    end
end

"""
    get_network_fpi_name(network_name::String) -> String

Map network name to the FPI directory name.
"""
function get_network_fpi_name(network_name::String)
    name_mapping = Dict(
        "RTS" => "RTS",
        "RTS_GMLC" => "RTS",
        "Texas7k" => "Texas7k",
        "Texas2k" => "texas2k",  # Lowercase in FPI directory
        "WECC10k" => "WECC10k",
        "ACTIVSg10k" => "WECC10k",
        "ACTIVSg2000" => "texas2k",
        "WECC240" => "WECC240",
        "pserc240" => "WECC240"
    )

    if haskey(name_mapping, network_name)
        return name_mapping[network_name]
    else
        # Default: use the network name as-is
        return network_name
    end
end

"""
    load_standard_wildfire_data(wf_dir, network_fpi_name, times_array, ref, risk_metric) -> Dict

Load wildfire data for standard networks. Checks for CSV files first (new format
from fetch_wfpi_data.jl), falls back to per-day JLD2 files (legacy format).
Returns per-day risk data: Dict{Int, Dict{Int, Float64}} indexed by day.
"""
function load_standard_wildfire_data(wf_dir::String, network_fpi_name::String, times_array::Vector, ref::Dict, risk_metric::String="cum_wfpi")
    # Try CSV loading first (new format)
    csv_result = _try_load_standard_csv(wf_dir, network_fpi_name, times_array, risk_metric)
    if csv_result !== nothing
        return csv_result
    end

    # Fall back to JLD2 per-day files (legacy format)
    return _load_standard_jld2(wf_dir, network_fpi_name, times_array)
end

"""
    _try_load_standard_csv(wf_dir, network_fpi_name, times_array, risk_metric) -> Union{Dict, Nothing}

Try to load wildfire data from CSV files (same format as CATS).
Returns nothing if no CSV files are found for any needed year.
"""
function _try_load_standard_csv(wf_dir::String, network_fpi_name::String, times_array::Vector, risk_metric::String)
    # Check if CSV files exist for all needed years
    years_needed = unique([t[1] for t in times_array])
    year_dfs = Dict{Int, DataFrame}()

    for year in years_needed
        csv_path = joinpath(wf_dir, network_fpi_name, "$(year)_risk.csv")
        if !isfile(csv_path)
            return nothing  # Fall back to JLD2
        end
        year_dfs[year] = CSV.read(csv_path, DataFrame)
    end

    # All CSVs found — load using same logic as CATS loader
    println("Loading $network_fpi_name wildfire data from CSV...")
    wildfire_data = Dict{Int, Dict{Int, Float64}}()

    for (d, (year, month, day)) in enumerate(times_array)
        if !haskey(year_dfs, year)
            @warn "No wildfire data for $network_fpi_name on $(year)-$(month)-$(day). Using empty risk."
            wildfire_data[d] = Dict{Int, Float64}()
            continue
        end

        risk_df = year_dfs[year]
        search_date = Date(year, month, day)
        day_df = filter(row -> Date(row.date_of_forecast) == search_date, risk_df)

        if nrow(day_df) == 0
            @warn "No wildfire data found for $network_fpi_name on $(year)-$(month)-$(day). Using empty risk."
            wildfire_data[d] = Dict{Int, Float64}()
            continue
        end

        risky_lines = Dict{Int, Float64}()
        for row in eachrow(day_df)
            branch_id = row.branch_id
            risk_val = getproperty(row, Symbol(risk_metric))
            if risk_val > 0.0
                risky_lines[branch_id] = risk_val
            end
        end
        wildfire_data[d] = risky_lines
    end

    total_risky = 0
    for (d, risk_dict) in wildfire_data
        total_risky = max(total_risky, length(risk_dict))
    end
    println("Loaded $network_fpi_name wildfire data from CSV for $(length(times_array)) days, max $total_risky risky lines per day")

    return wildfire_data
end

"""
    _load_standard_jld2(wf_dir, network_fpi_name, times_array) -> Dict

Legacy JLD2 per-day file loading for standard networks.
"""
function _load_standard_jld2(wf_dir::String, network_fpi_name::String, times_array::Vector)
    wildfire_data = Dict{Int,Dict{Int,Float64}}()

    for (d, (year, month, day)) in enumerate(times_array)
        day_risk = load_day_wildfire_data_standard(wf_dir, network_fpi_name, year, month, day)

        if day_risk !== nothing
            risky_lines = Dict{Int,Float64}()
            for (line_id, risk_val) in day_risk
                if risk_val > 0.0
                    risky_lines[line_id] = risk_val
                end
            end
            wildfire_data[d] = risky_lines
        else
            @warn "No wildfire data found for $(network_fpi_name) on $(year)-$(month)-$(day). Using empty risk."
            wildfire_data[d] = Dict{Int,Float64}()
        end
    end

    total_risky = 0
    for (d, risk_dict) in wildfire_data
        total_risky = max(total_risky, length(risk_dict))
    end
    println("Loaded wildfire data for $(length(times_array)) days, max $(total_risky) risky lines per day")

    return wildfire_data
end

"""
    load_day_wildfire_data_standard(wf_dir, network_fpi_name, year, month, day) -> Union{Dict, Nothing}

Load wildfire data for a single day from JLD2 file.
Handles both formats:
- Direct Dict{Int, Float64} (RTS format)
- Dict{String, Dict{Int, Float64}} with metric names (Texas7k format)
"""
function load_day_wildfire_data_standard(wf_dir::String, network_fpi_name::String, year::Int, month::Int, day::Int)
    # Construct file path
    file_dir = joinpath(wf_dir, network_fpi_name, string(year), "forecast_day_1")
    file_name = "FPI_$(network_fpi_name)_fday1_year$(year)_month$(month)_day$(day).jld2"
    file_path = joinpath(file_dir, file_name)

    if !isfile(file_path)
        return nothing
    end

    # Load the JLD2 file
    # The key inside the file matches the filename (without extension)
    key_name = "FPI_$(network_fpi_name)_fday1_year$(year)_month$(month)_day$(day)"
    data = JLD2.load(file_path)

    local raw_data
    if haskey(data, key_name)
        raw_data = data[key_name]
    else
        # Try to get the first key if the expected key doesn't exist
        first_key = first(keys(data))
        raw_data = data[first_key]
    end

    # Check if the data is in multi-metric format (Texas7k style)
    # In this case, raw_data is Dict{String, Dict{Int, Float64}} with metric names as keys
    if raw_data isa Dict && !isempty(raw_data)
        first_key = first(keys(raw_data))
        if first_key isa String && raw_data[first_key] isa Dict
            # Multi-metric format: extract the appropriate risk metric
            # Prefer "line_integral_FPI" (total exposure) or "max_FPI_value"
            if haskey(raw_data, "line_integral_FPI")
                return raw_data["line_integral_FPI"]
            elseif haskey(raw_data, "max_FPI_value")
                return raw_data["max_FPI_value"]
            elseif haskey(raw_data, "avg_FPI_value")
                return raw_data["avg_FPI_value"]
            else
                # Use the first available metric
                return raw_data[first_key]
            end
        end
    end

    # Direct Dict{Int, Float64} format (RTS style)
    return raw_data
end

"""
    load_cats_wildfire_data(wf_dir, times_array, ref, risk_metric) -> Dict

Load wildfire data for CATS network from CSV files.
Returns per-day risk data: Dict{Int, Dict{Int, Float64}} indexed by day.
"""
function load_cats_wildfire_data(wf_dir::String, times_array::Vector, ref::Dict, risk_metric::String)
    # Initialize per-day risk dictionary
    wildfire_data = Dict{Int,Dict{Int,Float64}}()

    # Group times by year for efficient loading
    years_needed = unique([t[1] for t in times_array])

    # Cache loaded CSVs by year
    year_dfs = Dict{Int,DataFrame}()

    for year in years_needed
        # Load the year's risk CSV (CATS data is in CATS subdirectory)
        csv_path = joinpath(wf_dir, "CATS", "$(year)_risk.csv")
        if !isfile(csv_path)
            @warn "No wildfire data file found for year $year: $csv_path"
            continue
        end

        println("Loading CATS wildfire data for year $year...")
        year_dfs[year] = CSV.read(csv_path, DataFrame)
    end

    # Process each day
    for (d, (year, month, day)) in enumerate(times_array)
        if !haskey(year_dfs, year)
            @warn "No wildfire data for CATS on $(year)-$(month)-$(day). Using empty risk."
            wildfire_data[d] = Dict{Int,Float64}()
            continue
        end

        risk_df = year_dfs[year]
        search_date = Date(year, month, day)

        # Filter to the specific date
        day_df = filter(row -> Date(row.date_of_forecast) == search_date, risk_df)

        if nrow(day_df) == 0
            @warn "No wildfire data found for CATS on $(year)-$(month)-$(day). Using empty risk."
            wildfire_data[d] = Dict{Int,Float64}()
            continue
        end

        # Extract risk values for each branch (only non-zero risk)
        risky_lines = Dict{Int,Float64}()
        for row in eachrow(day_df)
            branch_id = row.branch_id
            risk_val = getproperty(row, Symbol(risk_metric))

            if risk_val > 0.0
                risky_lines[branch_id] = risk_val
            end
        end
        wildfire_data[d] = risky_lines
    end

    # Report statistics
    total_risky = 0
    for (d, risk_dict) in wildfire_data
        total_risky = max(total_risky, length(risk_dict))
    end
    println("Loaded CATS wildfire data for $(length(times_array)) days, max $(total_risky) risky lines per day")

    return wildfire_data
end

"""
    compute_thresholded_line_statuses(wildfire_data::Dict, threshold::Float64, D::Int) -> Dict

Compute fixed line statuses for thresholded method.
De-energizes the N riskiest lines per day to meet the risk threshold.

# Arguments
- `wildfire_data`: Dict{Int, Dict{Int, Float64}} - per-day risk data
- `threshold`: Float64 - maximum allowed active risk per day
- `D`: Int - number of days

# Returns
Dict{Tuple{Int,Int}, Float64} mapping (day, line_id) to status (0=de-energized, 1=energized)
"""
function compute_thresholded_line_statuses(wildfire_data::Dict, threshold::Float64, D::Int)
    z_fixed = Dict{Tuple{Int,Int}, Float64}()

    println("\n=== Computing Thresholded Line Statuses ===")
    println("Target threshold: $(round(threshold, digits=2))")

    for d in 1:D
        day_risk_data = wildfire_data[d]

        if isempty(day_risk_data)
            println("Day $d: No risky lines")
            continue
        end

        # Calculate total risk for this day
        total_day_risk = sum(values(day_risk_data))

        # If total risk already meets threshold, keep all lines energized
        if total_day_risk <= threshold
            println("Day $d: Total risk $(round(total_day_risk, digits=2)) ≤ threshold. All lines energized.")
            for line_id in keys(day_risk_data)
                z_fixed[(d, line_id)] = 1.0
            end
            continue
        end

        # Sort lines by risk (descending) - de-energize highest risk first
        sorted_lines = sort(collect(day_risk_data), by=x->x[2], rev=true)

        # Greedily de-energize lines until active risk <= threshold
        active_risk = total_day_risk
        num_de_energized = 0

        for (line_id, risk_val) in sorted_lines
            if active_risk <= threshold
                # Threshold met, keep remaining lines energized
                z_fixed[(d, line_id)] = 1.0
            else
                # De-energize this line to reduce risk
                z_fixed[(d, line_id)] = 0.0
                active_risk -= risk_val
                num_de_energized += 1
            end
        end

        # Report for this day
        risk_removed = total_day_risk - active_risk
        pct_removed = (risk_removed / total_day_risk) * 100
        println("Day $d: De-energized $num_de_energized/$(length(day_risk_data)) risky lines")
        println("  Total risk: $(round(total_day_risk, digits=2))")
        println("  Active risk: $(round(active_risk, digits=2))")
        println("  Removed risk: $(round(risk_removed, digits=2)) ($(round(pct_removed, digits=1))%)")
    end

    println("===========================================\n")

    return z_fixed
end

"""
    compute_thresholded_hardening_and_switching(wildfire_data, threshold, D, opt_parameters, preprocessed) -> (Dict, Dict)

Compute fixed hardening (y) and switching (z) decisions for thresholded method with hardening.

Strategy:
1. Calculate cost-effectiveness for each hardenable line (cost per unit risk removed)
2. Sort by cost-effectiveness (best value first)
3. Harden lines greedily until budget exhausted
4. Apply thresholded switching to remaining non-hardened risky lines

# Returns
Tuple of (y_fixed, z_fixed) dictionaries
"""
function compute_thresholded_hardening_and_switching(wildfire_data::Dict, threshold::Float64,
                                                      D::Int, opt_parameters::Dict, preprocessed::Dict)
    println("\n=== Computing Thresholded Hardening + Switching ===")

    hardenable_lines = opt_parameters[:hardenable_lines]
    line_lengths = preprocessed[:line_lengths]
    cost_per_mile = opt_parameters[:hardening_cost_per_mile]
    effectiveness = opt_parameters[:hardening_effectiveness]
    budget = opt_parameters[:hardening_budget]

    # Calculate total risk for each hardenable line across all days
    line_total_risk = Dict{Int, Float64}()
    for l in hardenable_lines
        total_risk = 0.0
        for d in 1:D
            if haskey(wildfire_data[d], l)
                total_risk += wildfire_data[d][l]
            end
        end
        line_total_risk[l] = total_risk
    end

    # Calculate cost-effectiveness for each line (cost per unit risk removed)
    # Smaller = better value
    line_cost_effectiveness = Dict{Int, Float64}()
    for l in hardenable_lines
        risk = line_total_risk[l]
        if risk > 0
            # Cost per unit of risk mitigated
            cost = cost_per_mile * line_lengths[l]
            risk_mitigated = effectiveness * risk
            line_cost_effectiveness[l] = cost / risk_mitigated
        else
            # No risk to mitigate - infinite cost-effectiveness (will not be selected)
            line_cost_effectiveness[l] = Inf
        end
    end

    # Sort lines by cost-effectiveness (ascending - best value first)
    sorted_hardenable = sort(collect(line_cost_effectiveness), by=x->x[2])

    # Greedily harden lines until budget exhausted
    y_fixed = Dict{Int, Float64}()
    remaining_budget = budget
    num_hardened = 0
    total_hardening_cost = 0.0

    println("Hardening Phase:")
    println("  Budget: \$$(round(budget/1e6, digits=2))M")

    for (line_id, cost_eff) in sorted_hardenable
        line_cost = cost_per_mile * line_lengths[line_id]

        if line_cost <= remaining_budget && cost_eff < Inf
            # Harden this line
            y_fixed[line_id] = 1.0
            remaining_budget -= line_cost
            total_hardening_cost += line_cost
            num_hardened += 1
        else
            # Cannot afford or not cost-effective
            y_fixed[line_id] = 0.0
        end
    end

    println("  Lines hardened: $num_hardened/$(length(hardenable_lines))")
    println("  Total cost: \$$(round(total_hardening_cost/1e6, digits=2))M")
    println("  Remaining budget: \$$(round(remaining_budget/1e6, digits=2))M")

    # Calculate hardened set for quick lookup
    hardened_set = Set([l for (l, val) in y_fixed if val >= 0.5])

    # Now apply thresholded switching considering hardening
    # Risk from hardened energized lines is reduced by effectiveness
    z_fixed = Dict{Tuple{Int,Int}, Float64}()

    println("\nSwitching Phase:")
    println("  Target threshold: $(round(threshold, digits=2))")

    for d in 1:D
        day_risk_data = wildfire_data[d]

        if isempty(day_risk_data)
            println("  Day $d: No risky lines")
            continue
        end

        # Calculate total risk for this day (accounting for hardening)
        total_day_risk = 0.0
        for (line_id, risk_val) in day_risk_data
            if line_id in hardened_set
                # Risk reduced by hardening
                total_day_risk += risk_val * (1 - effectiveness)
            else
                total_day_risk += risk_val
            end
        end

        # If total risk already meets threshold, keep all lines energized
        if total_day_risk <= threshold
            println("  Day $d: Total risk $(round(total_day_risk, digits=2)) ≤ threshold. All lines energized.")
            for line_id in keys(day_risk_data)
                z_fixed[(d, line_id)] = 1.0
            end
            continue
        end

        # Sort non-hardened lines by risk (descending) - de-energize highest risk first
        # Hardened lines should stay energized (they're already mitigating risk)
        switchable_lines = [(l, r) for (l, r) in day_risk_data if l ∉ hardened_set]
        sorted_lines = sort(switchable_lines, by=x->x[2], rev=true)

        # Start with all lines energized
        active_risk = total_day_risk
        num_de_energized = 0

        # Keep all hardened lines energized
        for l in keys(day_risk_data)
            if l in hardened_set
                z_fixed[(d, l)] = 1.0
            end
        end

        # Greedily de-energize non-hardened lines until active risk <= threshold
        for (line_id, risk_val) in sorted_lines
            if active_risk <= threshold
                # Threshold met, keep remaining lines energized
                z_fixed[(d, line_id)] = 1.0
            else
                # De-energize this line to reduce risk
                z_fixed[(d, line_id)] = 0.0
                active_risk -= risk_val
                num_de_energized += 1
            end
        end

        # Report for this day
        risk_removed = total_day_risk - active_risk
        pct_removed = (risk_removed / total_day_risk) * 100
        println("  Day $d: De-energized $num_de_energized/$(length(switchable_lines)) switchable lines")
        println("    Active risk: $(round(active_risk, digits=2)) ($(round(pct_removed, digits=1))% removed)")
    end

    println("===================================================\n")

    return (y_fixed, z_fixed)
end

"""
    validate_hardening_parameters(opt_parameters::Dict)

Validate hardening-related parameters in opt_parameters dictionary.
Modifies opt_parameters in place to set defaults where needed.
"""
function validate_hardening_parameters(opt_parameters::Dict)
    if !get(opt_parameters, :hardening_enabled, false)
        return  # Nothing to validate if hardening disabled
    end

    println("\n--- Validating Hardening Parameters ---")

    # Validate effectiveness
    eff = get(opt_parameters, :hardening_effectiveness, 1.0)
    if !(0.0 <= eff <= 1.0)
        error("hardening_effectiveness must be between 0 and 1, got $eff")
    end
    opt_parameters[:hardening_effectiveness] = eff

    # Validate cost per mile
    cpm = get(opt_parameters, :hardening_cost_per_mile, 7e6)
    if cpm < 0
        error("hardening_cost_per_mile must be non-negative, got $cpm")
    end
    opt_parameters[:hardening_cost_per_mile] = cpm

    # Validate energization enforcement
    enforce_energization = get(opt_parameters, :hardening_enforce_energization, true)
    opt_parameters[:hardening_enforce_energization] = enforce_energization

    # Validate budget — hardening shares :infrastructure_budget with batteries and solar
    objective = get(opt_parameters, :objective, "loadshed")
    budget = get(opt_parameters, :infrastructure_budget, nothing)

    if objective != "cost"
        # Budget is required for non-cost objectives
        if budget === nothing
            budget = 1e9  # Default $1B
            opt_parameters[:infrastructure_budget] = budget
            @warn "infrastructure_budget not specified for objective '$objective', using default: \$1B"
        elseif budget < 0
            error("infrastructure_budget must be non-negative, got $budget")
        end
    else
        # For cost objective, budget is optional
        if budget === nothing
            budget = Inf
            opt_parameters[:infrastructure_budget] = budget
        elseif budget < 0
            error("infrastructure_budget must be non-negative, got $budget")
        end
    end
    # Store as :hardening_budget for internal constraint-building use
    opt_parameters[:hardening_budget] = budget

    # Validate candidate lines if provided
    if haskey(opt_parameters, :hardening_candidate_lines)
        lines = opt_parameters[:hardening_candidate_lines]
        if lines !== nothing && !isa(lines, Vector)
            error("hardening_candidate_lines must be a Vector of line IDs or nothing")
        end
    end

    # Print validation summary
    println("✓ Hardening parameters validated:")
    println("  Effectiveness: $(eff*100)% risk mitigation")
    println("  Cost per mile: \$$(round(cpm/1e6, digits=2))M")
    if budget < Inf
        println("  Infrastructure budget: \$$(round(budget/1e9, digits=2))B (shared)")
    else
        println("  Budget: No limit (cost in objective)")
    end
    println("  Enforce energization: $enforce_energization")
end

"""
    determine_hardenable_lines(opt_parameters::Dict, wildfire_data::Dict) -> Vector{Int}

Determine which lines are candidates for hardening.

# Arguments
- `opt_parameters`: Dictionary containing optimization parameters
- `wildfire_data`: Dict{Int => Dict{Int => Float64}} mapping day => (line_id => risk)

# Returns
- Vector of line IDs that can be hardened (sorted)
"""
function determine_hardenable_lines(opt_parameters::Dict, wildfire_data::Dict)
    # User-specified candidate lines
    if haskey(opt_parameters, :hardening_candidate_lines)
        candidates = opt_parameters[:hardening_candidate_lines]
        if candidates !== nothing
            println("  Using user-specified hardenable lines: $(length(candidates)) lines")
            return sort(candidates)
        end
    end

    # Default: all lines that have wildfire risk on any day
    D = length(wildfire_data)
    risky_lines = Set{Int}()

    for d in 1:D
        for (line_id, risk) in wildfire_data[d]
            if risk > 0
                push!(risky_lines, line_id)
            end
        end
    end

    risky_lines_vec = sort(collect(risky_lines))
    println("  Determined hardenable lines: $(length(risky_lines_vec)) lines with wildfire risk")

    return risky_lines_vec
end

"""
    load_bus_coordinates(network_name::String) -> DataFrame

Load bus latitude/longitude coordinates for a network.

# Arguments
- `network_name`: Network identifier (e.g., "RTS", "CATS", "Texas7k")

# Returns
- DataFrame with columns [:Bus_ID, :lat, :lng]
"""
function load_bus_coordinates(network_name::String, data_dir::String="data")
    base_path = dirname(@__DIR__)
    # Normalize network name
    normalized_name = uppercase(network_name)

    # Map network names to coordinate filenames
    coord_filenames = Dict(
        "RTS"                  => "RTS_GMLC_bus.csv",
        "RTS_GMLC"             => "RTS_GMLC_bus.csv",
        "CATS"                 => "CATS_bus.csv",
        "CALIFORNIATESTS"      => "CATS_bus.csv",
        "CALIFORNIATESTSYSTEM" => "CATS_bus.csv",
        "TEXAS7K"              => "Texas7k_lat_long.csv",
        "TEXAS2K"              => "Texas2k_lat_long.csv",
        "ACTIVSG2000"          => "Texas2k_lat_long.csv",
        "WECC10K"              => "WECC10k_lat_long.csv",
        "ACTIVSG10K"           => "WECC10k_lat_long.csv",
        "WECC240"              => "wecc_lat_lon_good.csv",
        "PSERC240"             => "wecc_lat_lon_good.csv",
    )

    if !haskey(coord_filenames, normalized_name)
        @warn "No bus coordinate file mapping for network: $network_name. Line lengths will be unavailable."
        return DataFrame(Bus_ID=Int[], lat=Float64[], lng=Float64[])
    end

    file_path = joinpath(base_path, data_dir, "bus_lat_lons", coord_filenames[normalized_name])

    if !isfile(file_path)
        @warn "Bus coordinate file not found: $file_path. Line lengths will be set to 0."
        return DataFrame(Bus_ID=Int[], lat=Float64[], lng=Float64[])
    end

    return CSV.read(file_path, DataFrame)
end

"""
    load_census_data(network_name; acs_year=2022, data_dir="data", file_path="") -> DataFrame

Load the unified per-bus Census ACS demographics for a network.

Expects a CSV at `<data_dir>/census_data/<network_name>_census_<acs_year>.csv`
produced by `get_network_census`. Returns an empty typed DataFrame (with
`@warn`) if the file is missing — plotting and downstream use should
degrade gracefully rather than crash.

# Returns
DataFrame with columns: Bus_ID, total_pop, num_households, num_white,
num_black, num_native, num_asian, num_hispanic, num_below_poverty,
num_above_poverty, num_low_income, num_middle_income, num_high_income,
median_income.
"""
function load_census_data(network_name::String; acs_year::Int=2022,
                          data_dir::String="data", file_path::String="")
    if isempty(file_path)
        base_path = dirname(@__DIR__)
        file_path = joinpath(base_path, data_dir, "census_data",
                             "$(network_name)_census_$(acs_year).csv")
    end
    if !isfile(file_path)
        @warn "Census data file not found: $file_path"
        return DataFrame(Bus_ID=Int[],
                         total_pop=Float64[], num_households=Float64[],
                         num_white=Float64[], num_black=Float64[], num_native=Float64[],
                         num_asian=Float64[], num_hispanic=Float64[],
                         num_below_poverty=Float64[], num_above_poverty=Float64[],
                         num_low_income=Float64[], num_middle_income=Float64[],
                         num_high_income=Float64[],
                         median_income=Union{Missing,Float64}[])
    end
    return CSV.read(file_path, DataFrame; types=Dict(:Bus_ID=>Int))
end

"""
    calculate_line_lengths(ref::Dict, bus_data::DataFrame) -> Dict{Int, Float64}

Calculate transmission line lengths using haversine formula.

# Arguments
- `ref`: PowerModels network reference dictionary
- `bus_data`: DataFrame with columns [:Bus_ID, :lat, :lng]

# Returns
- Dictionary mapping line_id => length_in_miles
"""
function calculate_line_lengths(ref::Dict, bus_data::DataFrame)
    # Earth radius in meters
    R = 6371000.0

    line_lengths = Dict{Int, Float64}()

    # Handle empty bus data
    if isempty(bus_data)
        for l in keys(ref[:branch])
            line_lengths[l] = 0.0
        end
        return line_lengths
    end

    for (l, branch) in ref[:branch]
        f_bus = branch["f_bus"]
        t_bus = branch["t_bus"]

        # Find bus coordinates
        f_idx = findfirst(isequal(f_bus), bus_data.Bus_ID)
        t_idx = findfirst(isequal(t_bus), bus_data.Bus_ID)

        if f_idx === nothing || t_idx === nothing
            # If coordinates not found, use 0.0
            @warn "Coordinates not found for line $l (buses $f_bus -> $t_bus). Setting length to 0."
            line_lengths[l] = 0.0
            continue
        end

        lon_1 = bus_data.lng[f_idx]
        lat_1 = bus_data.lat[f_idx]
        lon_2 = bus_data.lng[t_idx]
        lat_2 = bus_data.lat[t_idx]

        # Convert to radians
        lat_1_rad = lat_1 * π / 180.0
        lat_2_rad = lat_2 * π / 180.0
        Δlat = (lat_2 - lat_1) * π / 180.0
        Δlon = (lon_2 - lon_1) * π / 180.0

        # Haversine formula
        a = sin(Δlat/2)^2 + cos(lat_1_rad) * cos(lat_2_rad) * sin(Δlon/2)^2
        c = 2 * atan(sqrt(a), sqrt(1-a))
        dist_meters = R * c
        dist_miles = dist_meters * 0.0006213712  # meters to miles

        line_lengths[l] = dist_miles
    end

    return line_lengths
end

"""
    validate_risk_per_line(risk_data::Dict, D::Int)

Validate that user-provided risk data has the correct structure.
Expected format: Dict{Int, Dict{Int, Float64}} where:
- Outer keys: day indices from 1 to D
- Inner dict: line_id => risk_value (only lines with risk > 0)

# Arguments
- `risk_data`: The risk data dictionary to validate
- `D`: Expected number of days

# Throws
- Error if structure is invalid
"""
function validate_risk_per_line(risk_data::Dict, D::Int)
    # Check if it's a Dict
    if !(risk_data isa Dict)
        error("risk_per_line must be a Dict, got $(typeof(risk_data))")
    end

    # Check that we have data for all days (1 to D)
    for d in 1:D
        if !haskey(risk_data, d)
            error("risk_per_line is missing data for day $d. Expected keys 1 to $D")
        end

        day_data = risk_data[d]

        # Check inner structure
        if !(day_data isa Dict)
            error("risk_per_line[$d] must be a Dict, got $(typeof(day_data))")
        end

        # Validate that all line IDs and risk values are correct types
        for (line_id, risk_val) in day_data
            if !(line_id isa Integer)
                error("risk_per_line[$d] keys (line IDs) must be Integers, got $(typeof(line_id))")
            end

            if !(risk_val isa Real && risk_val >= 0)
                error("risk_per_line[$d][$line_id] must be a non-negative number, got $risk_val")
            end
        end
    end

    # Calculate and report statistics
    total_entries = sum(length(risk_data[d]) for d in 1:D)
    max_risky = maximum(length(risk_data[d]) for d in 1:D)
    min_risky = minimum(length(risk_data[d]) for d in 1:D)

    println("✓ risk_per_line validation passed:")
    println("  - $D days of data")
    println("  - $total_entries total line-day risk entries")
    println("  - Min/Max risky lines per day: $min_risky/$max_risky")
end

"""
    validate_battery_parameters(opt_parameters::Dict)

Validate battery-related parameters in opt_parameters dictionary.
Modifies opt_parameters in place to set defaults where needed.
"""
function validate_battery_parameters(opt_parameters::Dict)
    if !get(opt_parameters, :battery_enabled, false)
        return  # Nothing to validate if battery planning disabled
    end

    println("\n--- Validating Battery Parameters ---")

    # Validate cost per p.u.
    cost_per_pu = get(opt_parameters, :battery_cost_per_pu, 1e8)
    if cost_per_pu < 0
        error("battery_cost_per_pu must be non-negative, got $cost_per_pu")
    end
    opt_parameters[:battery_cost_per_pu] = cost_per_pu

    # Validate charge efficiency
    η_c = get(opt_parameters, :battery_charge_efficiency, 0.95)
    if !(0.0 < η_c <= 1.0)
        error("battery_charge_efficiency must be in (0, 1], got $η_c")
    end
    opt_parameters[:battery_charge_efficiency] = η_c

    # Validate discharge efficiency
    η_d = get(opt_parameters, :battery_discharge_efficiency, 0.95)
    if !(0.0 < η_d <= 1.0)
        error("battery_discharge_efficiency must be in (0, 1], got $η_d")
    end
    opt_parameters[:battery_discharge_efficiency] = η_d

    # Validate SOC carryover (decay factor)
    decay = get(opt_parameters, :battery_soc_carryover, 0.999958)
    if !(0.0 < decay <= 1.0)
        error("battery_soc_carryover must be in (0, 1], got $decay")
    end
    opt_parameters[:battery_soc_carryover] = decay

    # Validate charge rate
    c_rate = get(opt_parameters, :battery_charge_rate, 1.0)
    if c_rate <= 0
        error("battery_charge_rate must be positive, got $c_rate")
    end
    opt_parameters[:battery_charge_rate] = c_rate

    # Validate discharge rate
    d_rate = get(opt_parameters, :battery_discharge_rate, 1.0)
    if d_rate <= 0
        error("battery_discharge_rate must be positive, got $d_rate")
    end
    opt_parameters[:battery_discharge_rate] = d_rate

    # Validate network-wide limit
    max_network = get(opt_parameters, :battery_max_network, nothing)
    if max_network !== nothing && max_network < 0
        error("battery_max_network must be non-negative, got $max_network")
    end
    opt_parameters[:battery_max_network] = max_network

    # Validate per-node limit
    max_per_node = get(opt_parameters, :battery_max_per_node, nothing)
    if max_per_node !== nothing && max_per_node < 0
        error("battery_max_per_node must be non-negative, got $max_per_node")
    end
    opt_parameters[:battery_max_per_node] = max_per_node

    # Validate exclusive operation flag
    exclusive = get(opt_parameters, :battery_exclusive_operation, false)
    opt_parameters[:battery_exclusive_operation] = exclusive

    # Validate linearized battery power flag (for LACOTS reactive power)
    linearized = get(opt_parameters, :linearized_battery_power, true)
    opt_parameters[:linearized_battery_power] = linearized

    # Validate candidate buses if provided
    if haskey(opt_parameters, :battery_candidate_buses)
        buses = opt_parameters[:battery_candidate_buses]
        # Allow Vector, "load buses" string, or nothing
        if buses !== nothing && !isa(buses, Vector) &&
           !(isa(buses, String) && lowercase(buses) == "load buses")
            error("battery_candidate_buses must be either a Vector{Int}, the string \"load buses\", or nothing")
        end
    end

    # Validate infrastructure budget (shared with hardening/solar)
    objective = get(opt_parameters, :objective, "loadshed")
    budget = get(opt_parameters, :infrastructure_budget, nothing)

    if objective != "cost"
        # Budget is required for non-cost objectives
        if budget === nothing
            opt_parameters[:infrastructure_budget] = 1e9  # Set default $1B
            @warn "infrastructure_budget not specified for objective '$objective', using default: \$1B"
            budget = 1e9
        elseif budget < 0
            error("infrastructure_budget must be non-negative, got $budget")
        end
    else
        # For cost objective, budget is optional
        if budget === nothing
            opt_parameters[:infrastructure_budget] = Inf  # No budget constraint
            budget = Inf
        elseif budget < 0
            error("infrastructure_budget must be non-negative, got $budget")
        end
    end

    # Print validation summary
    println("✓ Battery parameters validated:")
    println("  Cost per p.u. (100MWh): \$$(round(cost_per_pu/1e6, digits=2))M")
    println("  Charge efficiency: $(η_c*100)%")
    println("  Discharge efficiency: $(η_d*100)%")
    println("  SOC carryover: $(decay*100)%")
    println("  Charge rate: $(c_rate) p.u./hour")
    println("  Discharge rate: $(d_rate) p.u./hour")
    println("  Exclusive operation: $exclusive")

    if max_network !== nothing
        println("  Network-wide limit: $(max_network) p.u.")
    end
    if max_per_node !== nothing
        println("  Per-node limit: $(max_per_node) p.u.")
    end

    if budget < Inf
        println("  Infrastructure budget: \$$(round(budget/1e9, digits=2))B (shared)")
    else
        println("  Infrastructure budget: No limit (cost in objective)")
    end
end

"""
    determine_battery_candidate_buses(opt_parameters::Dict, ref::Dict) -> Vector{Int}

Determine which buses are candidates for battery installation.

# Arguments
- `opt_parameters`: Dictionary containing optimization parameters
- `ref`: PowerModels network reference dictionary

# Returns
- Vector of bus IDs that can have batteries (sorted)
"""
function determine_battery_candidate_buses(opt_parameters::Dict, ref::Dict)
    bus_names = sort([bus for bus in keys(ref[:bus])])

    # User-specified candidate buses
    if haskey(opt_parameters, :battery_candidate_buses)
        candidates = opt_parameters[:battery_candidate_buses]

        # Handle string "load buses"
        if candidates isa String && lowercase(candidates) == "load buses"
            load_buses = Int[]
            for bus_id in bus_names
                if haskey(ref[:bus_loads], bus_id) && !isempty(ref[:bus_loads][bus_id])
                    push!(load_buses, bus_id)
                end
            end

            if isempty(load_buses)
                @warn "No load buses found. Using all buses as battery candidates."
                return bus_names
            end

            println("  Battery candidates: $(length(load_buses)) load buses")
            return sort(load_buses)

        # Handle array of bus IDs
        elseif candidates isa Vector
            println("  Battery candidates: $(length(candidates)) user-specified buses")
            return sort(candidates)

        # Handle nothing - fall through to default
        elseif candidates === nothing
            # Fall through to default
        else
            error("battery_candidate_buses must be either a Vector{Int}, the string \"load buses\", or nothing")
        end
    end

    # Default: all buses are candidates for battery installation
    println("  Battery candidates: $(length(bus_names)) buses (all)")
    return bus_names
end

"""
    validate_solar_parameters(opt_parameters::Dict)

Validate solar-related parameters in opt_parameters dictionary.
Modifies opt_parameters in place to set defaults where needed.
"""
function validate_solar_parameters(opt_parameters::Dict)
    if !get(opt_parameters, :solar_enabled, false)
        return  # Nothing to validate if solar planning disabled
    end

    println("\n--- Validating Solar Parameters ---")

    cost_per_pu = get(opt_parameters, :solar_cost_per_pu, 1e8)
    if cost_per_pu < 0
        error("solar_cost_per_pu must be non-negative, got $cost_per_pu")
    end
    opt_parameters[:solar_cost_per_pu] = cost_per_pu

    max_network = get(opt_parameters, :solar_max_network, nothing)
    if max_network !== nothing && max_network < 0
        error("solar_max_network must be non-negative, got $max_network")
    end
    opt_parameters[:solar_max_network] = max_network

    max_per_node = get(opt_parameters, :solar_max_per_node, nothing)
    if max_per_node !== nothing && max_per_node < 0
        error("solar_max_per_node must be non-negative, got $max_per_node")
    end
    opt_parameters[:solar_max_per_node] = max_per_node

    cf_default = get(opt_parameters, :solar_capacity_factor_default, 0.3)
    if !(0.0 <= cf_default <= 1.0)
        error("solar_capacity_factor_default must be in [0, 1], got $cf_default")
    end
    opt_parameters[:solar_capacity_factor_default] = cf_default

    # Validate candidate buses if provided
    if haskey(opt_parameters, :solar_candidate_buses)
        buses = opt_parameters[:solar_candidate_buses]
        if buses !== nothing && !isa(buses, Vector)
            error("solar_candidate_buses must be a Vector of bus IDs or nothing")
        end
    end

    # Validate linearized solar power flag (for LACOTS reactive power)
    linearized = get(opt_parameters, :linearized_solar_power, true)
    opt_parameters[:linearized_solar_power] = linearized

    # Validate data path if provided
    data_path = get(opt_parameters, :solar_data_path, nothing)
    if data_path !== nothing && !isfile(data_path) && !isdir(data_path)
        error("solar_data_path does not exist: $data_path")
    end
    opt_parameters[:solar_data_path] = data_path

    # Infrastructure budget is shared with battery/hardening; already set by validate_battery_parameters
    # If battery is not enabled, we need to set the budget here
    if !get(opt_parameters, :battery_enabled, false)
        objective = get(opt_parameters, :objective, "loadshed")
        budget = get(opt_parameters, :infrastructure_budget, nothing)
        if objective != "cost"
            if budget === nothing
                opt_parameters[:infrastructure_budget] = 1e9
                @warn "infrastructure_budget not specified for objective '$objective', using default: \$1B"
            elseif budget < 0
                error("infrastructure_budget must be non-negative, got $budget")
            end
        else
            if budget === nothing
                opt_parameters[:infrastructure_budget] = Inf
            elseif budget < 0
                error("infrastructure_budget must be non-negative, got $budget")
            end
        end
    end

    println("✓ Solar parameters validated:")
    println("  Cost per p.u. (100MW): \$$(round(cost_per_pu/1e6, digits=2))M")
    println("  Default capacity factor: $cf_default")
    if data_path !== nothing
        println("  Data path: $data_path")
    else
        println("  Data path: none (using flat default capacity factor)")
    end
end

"""
    determine_solar_candidate_buses(opt_parameters::Dict, ref::Dict) -> Vector{Int}

Determine which buses are candidates for solar installation.
"""
function determine_solar_candidate_buses(opt_parameters::Dict, ref::Dict)
    bus_names = sort([bus for bus in keys(ref[:bus])])

    if haskey(opt_parameters, :solar_candidate_buses)
        candidates = opt_parameters[:solar_candidate_buses]

        if candidates isa Vector
            valid = sort(filter(b -> b in keys(ref[:bus]), candidates))
            if length(valid) < length(candidates)
                @warn "$(length(candidates) - length(valid)) solar candidate buses not found in network"
            end
            println("  Solar candidates: $(length(valid)) buses (user-specified)")
            return valid
        elseif candidates === nothing
            # Fall through to default
        else
            error("solar_candidate_buses must be a Vector{Int} or nothing")
        end
    end

    println("  Solar candidates: $(length(bus_names)) buses (all)")
    return bus_names
end

"""
    load_solar_capacity_factors(opt_parameters::Dict, solar_locs::Vector{Int}, times_array, T::Int) -> Dict

Load solar capacity factors from file or apply flat default.
Returns Dict{Tuple{Int,Int,Int},Float64} indexed by (day, hour, bus_id).
"""
function load_solar_capacity_factors(opt_parameters::Dict, solar_locs::Vector{Int}, times_array, T::Int)
    D = length(times_array)
    solar_cf = Dict{Tuple{Int,Int,Int},Float64}()
    data_path = get(opt_parameters, :solar_data_path, nothing)
    cf_default = opt_parameters[:solar_capacity_factor_default]

    if data_path === nothing
        println("  Solar: using flat capacity factor = $cf_default (no data path provided)")
        for d in 1:D, t in 1:T, n in solar_locs
            solar_cf[(d, t, n)] = cf_default
        end
        return solar_cf
    end

    if isfile(data_path)
        df = CSV.read(data_path, DataFrame)
        col_names = names(df)

        if "Date" in col_names || "date" in col_names
            # Yearly format: Bus_ID, Date, Hour, AC_Output_pu, DC_Output_pu
            date_col = "Date" in col_names ? :Date : :date
            for (d, (yr, mo, day)) in enumerate(times_array)
                target_date = Dates.Date(yr, mo, day)
                day_df = filter(r -> r[date_col] == target_date || string(r[date_col]) == string(target_date), df)

                if nrow(day_df) == 0
                    # TMY data uses a reference year (2019) but users request any year.
                    # Fall back to matching by month+day only.
                    mo_req, da_req = Dates.month(target_date), Dates.day(target_date)
                    day_df = filter(r -> Dates.month(r[date_col]) == mo_req &&
                                        Dates.day(r[date_col]) == da_req, df)
                end
                if nrow(day_df) == 0
                    @warn "No solar data found for $target_date (or matching month/day) in $data_path, using default cf=$cf_default"
                    for t in 1:T, n in solar_locs
                        solar_cf[(d, t, n)] = cf_default
                    end
                else
                    bus_hour_cf = Dict{Tuple{Int,Int},Float64}()
                    for row in eachrow(day_df)
                        bus_id = Int(row.Bus_ID)
                        hour = Int(row.Hour)
                        if 1 <= hour <= T
                            bus_hour_cf[(bus_id, hour)] = Float64(row.AC_Output_pu)
                        end
                    end
                    for t in 1:T, n in solar_locs
                        solar_cf[(d, t, n)] = get(bus_hour_cf, (n, t), cf_default)
                    end
                end
            end
        else
            # Daily format: Bus_ID, Hour, AC_Output_pu, DC_Output_pu — applied to all days
            bus_hour_cf = Dict{Tuple{Int,Int},Float64}()
            for row in eachrow(df)
                bus_id = Int(row.Bus_ID)
                hour = Int(row.Hour)
                if 1 <= hour <= T
                    bus_hour_cf[(bus_id, hour)] = Float64(row.AC_Output_pu)
                end
            end
            for d in 1:D, t in 1:T, n in solar_locs
                solar_cf[(d, t, n)] = get(bus_hour_cf, (n, t), cf_default)
            end
            println("  Solar: loaded daily capacity factor profile from $data_path (applied to all days)")
        end

    elseif isdir(data_path)
        # Directory: look for per-day files named solar_data_YYYY-MM-DD.csv
        for (d, (yr, mo, day)) in enumerate(times_array)
            date_str = @sprintf("%04d-%02d-%02d", yr, mo, day)
            fpath = joinpath(data_path, "solar_data_$(date_str).csv")

            if isfile(fpath)
                df = CSV.read(fpath, DataFrame)
                bus_hour_cf = Dict{Tuple{Int,Int},Float64}()
                for row in eachrow(df)
                    bus_id = Int(row.Bus_ID)
                    hour = Int(row.Hour)
                    if 1 <= hour <= T
                        bus_hour_cf[(bus_id, hour)] = Float64(row.AC_Output_pu)
                    end
                end
                for t in 1:T, n in solar_locs
                    solar_cf[(d, t, n)] = get(bus_hour_cf, (n, t), cf_default)
                end
            else
                @warn "No solar file found for $date_str in $data_path, using default cf=$cf_default"
                for t in 1:T, n in solar_locs
                    solar_cf[(d, t, n)] = cf_default
                end
            end
        end
    end

    return solar_cf
end
