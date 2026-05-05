"""
Functions for fetching and processing solar data from NREL PVWatts API.
"""

using Printf

"""
    get_network_solar_data(network_name::String, date; api_key::String="", save_to_file::Bool=false, output_dir::String="")

Fetch solar generation profiles for all buses in a network.

# Arguments
- `network_name`: Name of the network (e.g., "RTS", "Texas7k")
- `date`: Date input. Can be:
    - Date object
    - Tuple (year, month, day)
    - String "all" for the full year (8760 hours)
- `api_key`: NREL API key. If not provided, checks ENV["NREL_API_KEY"] or uses "DEMO_KEY"
- `save_to_file`: If true, saves data to CSV instead of returning it.
- `output_dir`: Optional override for output directory. If empty, defaults to "data/solar_curves/<network_mapped_name>"

# Returns
- If `save_to_file` is false: Dict{Int, Dict{String, Vector{Float64}}}
- If `save_to_file` is true: Nothing
"""
function get_network_solar_data(network_name::String, date; api_key::String="", save_to_file::Bool=false, output_dir::String="")
    # Handle API key
    if isempty(api_key)
        api_key = get(ENV, "NREL_API_KEY", "DEMO_KEY")
    end

    # Handle Date
    fetch_all_year = false
    date_obj = nothing
    
    if date isa String && lowercase(date) == "all"
        fetch_all_year = true
        # Use a default non-leap year for date mapping of TMY data
        date_obj = Date(2023, 1, 1) 
        println("Fetching FULL YEAR solar data for $network_name...")
    elseif date isa Tuple
        date_obj = Date(date[1], date[2], date[3])
        println("Fetching solar data for $network_name on $date_obj...")
    else
        date_obj = date
        println("Fetching solar data for $network_name on $date_obj...")
    end

    # Determine paths and handle existing data
    existing_data = Dict{Int, Dict{String, Vector{Float64}}}()
    file_path = ""
    
    if save_to_file
        # Determine Output Directory
        if isempty(output_dir)
            base_path = dirname(@__DIR__) # Assumes we are in src/ so parent is root
            folder_name = get_solar_network_name(network_name)
            output_dir = joinpath(base_path, "data", "solar_curves", folder_name)
        end
        
        if !isdir(output_dir)
            mkpath(output_dir)
        end
        
        # Determine Filename
        if fetch_all_year
            file_name = "solar_data_$(network_name)_all.csv"
        else
            file_name = "solar_data_$(network_name)_$(date_obj).csv"
        end
        
        file_path = joinpath(output_dir, file_name)
        
        # Load existing data if file exists
        if isfile(file_path)
            println("Found existing file: $file_path")
            println("Loading existing data to determine missing buses...")
            existing_data = load_existing_solar_data(file_path, fetch_all_year)
            println("Loaded data for $(length(existing_data)) buses.")
        end
    end

    # Load bus coordinates
    bus_coords = load_bus_coordinates(network_name)

    if isempty(bus_coords)
        error("No coordinate data found for network: $network_name")
    end

    # Initialize results with existing data
    solar_profiles = copy(existing_data)
    
    # Cache results by location
    location_cache = Dict{Tuple{Float64, Float64}, Dict{String, Vector{Float64}}}()

    total_buses = nrow(bus_coords)
    missing_buses = 0
    for row in eachrow(bus_coords)
        if !haskey(solar_profiles, row.Bus_ID)
            missing_buses += 1
        end
    end
    
    println("Total buses: $total_buses")
    println("Buses to fetch: $missing_buses")

    if missing_buses == 0
        println("All buses already have data. Skipping API calls.")
        if !save_to_file
            return solar_profiles
        else
            println("Data file is already complete.")
            return nothing
        end
    end

    # Parameters for PVWatts
    pv_params = Dict(
        "system_capacity" => 1,     # 1 kW to get per-unit output
        "module_type" => 0,         # Standard
        "losses" => 14,             # Standard losses
        "array_type" => 0,          # Fixed (open rack)
        "tilt" => 20,               # Default tilt
        "azimuth" => 180            # South facing
    )

    count_fetched = 0
    
    for row in eachrow(bus_coords)
        bus_id = row.Bus_ID
        lat = row.lat
        lon = row.lng

        if lat == 0.0 && lon == 0.0
            continue
        end

        # Skip if we already have data
        if haskey(solar_profiles, bus_id)
            continue
        end

        # Check cache
        loc_key = (lat, lon)
        if haskey(location_cache, loc_key)
            solar_profiles[bus_id] = location_cache[loc_key]
            continue
        end

        # Fetch data
        try
            count_fetched += 1
            if count_fetched % 10 == 0
                println("Fetching bus $count_fetched / $missing_buses...")
            end
            
            profile = fetch_pvwatts_data(lat, lon, date_obj, api_key; params=pv_params, all_year=fetch_all_year)
            
            # Cache and store
            location_cache[loc_key] = profile
            solar_profiles[bus_id] = profile
            
            # Respect rate limits
            sleep(0.5) 
            
            # Incremental save every 50 buses if saving to file (safety against crashes)
            if save_to_file && count_fetched % 50 == 0
                 println("  Performing incremental save...")
                 save_solar_data_csv(file_path, solar_profiles, fetch_all_year, date_obj)
            end
            
        catch e
            @warn "Failed to fetch solar data for bus $bus_id at ($lat, $lon): $e"
        end
    end

    println("Successfully fetched data for $count_fetched new buses.")
    println("Total buses with data: $(length(solar_profiles))")

    if save_to_file
        println("Saving final data to $file_path...")
        save_solar_data_csv(file_path, solar_profiles, fetch_all_year, date_obj)
        println("Done.")
        return nothing
    else
        return solar_profiles
    end
end

"""
    load_existing_solar_data(file_path::String, all_year::Bool) -> Dict

Load existing solar data from a CSV file.
Returns Dict{Int, Dict{String, Vector{Float64}}}
"""
function load_existing_solar_data(file_path::String, all_year::Bool)
    data = Dict{Int, Dict{String, Vector{Float64}}}()
    
    try
        df = CSV.read(file_path, DataFrame)
        
        # Group by Bus_ID
        grouped = groupby(df, :Bus_ID)
        
        for sdf in grouped
            bus_id = first(sdf.Bus_ID)
            
            # Sort by Hour (or Date/Hour) to ensure correct order
            sort!(sdf, :Hour)
            
            # Extract AC and DC columns
            ac = Vector{Float64}(sdf.AC_Output_pu)
            dc = Vector{Float64}(sdf.DC_Output_pu)
            
            data[bus_id] = Dict("ac" => ac, "dc" => dc)
        end
    catch e
        @warn "Failed to load existing file: $e. Starting fresh."
    end
    
    return data
end

"""
    save_solar_data_csv(file_path, solar_profiles, fetch_all_year, date_obj)

Helper function to write solar profiles to CSV.
"""
function save_solar_data_csv(file_path, solar_profiles, fetch_all_year, date_obj)
    # Write to temp file first then move? Or just overwrite.
    # Overwriting is simpler for now, though risky if interrupted during write.
    # Given the incremental nature, we want to make sure we don't lose data.
    
    open(file_path, "w") do io
        # Write header
        if fetch_all_year
            println(io, "Bus_ID,Date,Hour,AC_Output_pu,DC_Output_pu")
        else
            println(io, "Bus_ID,Hour,AC_Output_pu,DC_Output_pu")
        end
        
        # Sort bus IDs for consistent output
        sorted_buses = sort(collect(keys(solar_profiles)))
        
        # Write data
        for bus_id in sorted_buses
            profiles = solar_profiles[bus_id]
            ac = profiles["ac"]
            dc = profiles["dc"]
            
            # Determine dates if all year
            if fetch_all_year
                # Use the reference year set in date_obj
                year_val = Dates.year(date_obj)
                current_dt = DateTime(year_val, 1, 1, 0)
                
                for h in 1:length(ac)
                    dt = current_dt + Dates.Hour(h - 1)
                    date_str = Dates.format(dt, "yyyy-mm-dd HH:MM:SS")
                    
                    @printf(io, "%d,%s,%d,%.6f,%.6f\n", bus_id, date_str, h, ac[h], dc[h])
                end
            else
                # Single day
                for h in 1:length(ac)
                    @printf(io, "%d,%d,%.6f,%.6f\n", bus_id, h, ac[h], dc[h])
                end
            end
        end
    end
end


"""
    fetch_pvwatts_data(lat, lon, date, api_key; params, all_year) -> Dict{String, Vector{Float64}}

Call NREL PVWatts API.
If `all_year` is true, returns full 8760 profile.
If `all_year` is false, extracts specific day based on `date`.
"""
function fetch_pvwatts_data(lat::Float64, lon::Float64, date::Date, api_key::String; params::Dict=Dict(), all_year::Bool=false)
    base_url = "https://developer.nlr.gov/api/pvwatts/v8.json"
    
    # Combine parameters
    query_params = Dict{String, Any}(params)
    query_params["api_key"] = api_key
    query_params["lat"] = lat
    query_params["lon"] = lon
    query_params["timeframe"] = "hourly"
    
    try
        response = HTTP.get(base_url; query=query_params)
        
        if response.status != 200
            error("API request failed with status $(response.status)")
        end
        
        data = JSON.parse(String(response.body))
        
        if haskey(data, "errors") && !isempty(data["errors"])
            error("API returned errors: $(data["errors"])")
        end
        
        ac_output = data["outputs"]["ac"] ./ 1000.0
        dc_output = data["outputs"]["dc"] ./ 1000.0
        
        if all_year
            # Return full arrays
            return Dict("ac" => ac_output, "dc" => dc_output)
        else
            # Extract specific day
            if Dates.month(date) == 2 && Dates.day(date) == 29
                error("Solar data not available for Feb 29 (leap day). PVWatts data is non-leap year only.")
            end

            doy = Dates.dayofyear(date)
            
            # If it's a leap year and after Feb 29, shift back by one day to match 365-day TMY
            if Dates.isleapyear(date) && doy > 60
                doy -= 1
            end
            
            start_hour = (doy - 1) * 24 + 1
            end_hour = start_hour + 23
            
            # Ensure bounds
            start_hour = max(1, start_hour)
            end_hour = min(length(ac_output), end_hour)
            
            ac_slice = ac_output[start_hour:end_hour]
            dc_slice = dc_output[start_hour:end_hour]
            
            return Dict("ac" => ac_slice, "dc" => dc_slice)
        end
        
    catch e
        rethrow(e)
    end
end

"""
    get_solar_network_name(network_name::String) -> String

Map network name to the standard directory name structure (matching USGS_FPI).
"""
function get_solar_network_name(network_name::String)
    name_mapping = Dict(
        "RTS" => "RTS",
        "RTS_GMLC" => "RTS",
        "Texas7k" => "Texas7k",
        "Texas2k" => "texas2k",
        "ACTIVSg2000" => "texas2k",
        "WECC10k" => "WECC10k",
        "ACTIVSg10k" => "WECC10k",
        "WECC240" => "WECC240",
        "pserc240" => "WECC240"
    )

    if haskey(name_mapping, network_name)
        return name_mapping[network_name]
    else
        return network_name
    end
end