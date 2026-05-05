#!/usr/bin/env julia
"""
    generate_solar_data.jl

Fetches TMY hourly solar capacity factor data from NREL PVWatts API for all
buses in each supported network. Outputs CSV files to data/solar_data/{net}/solar_data.csv.

Usage (run from project root):
    julia --project=scripts scripts/generate_solar_data.jl
    julia --project=scripts scripts/generate_solar_data.jl --network RTS
    julia --project=scripts scripts/generate_solar_data.jl --api-key YOUR_KEY

PVWatts returns TMY (Typical Meteorological Year) data — the same 8760-hour
profile regardless of the year requested. Dates are mapped to reference year
2019 (non-leap, consistent with CATS HourlyProduction2019.csv).
"""

using ArgParse, CSV, DataFrames, Dates, HTTP, JSON, Printf

const BASE_DIR = dirname(@__DIR__)
const DATA_DIR = joinpath(BASE_DIR, "data")
const SOLAR_DIR = joinpath(DATA_DIR, "solar_data")

# Networks ordered smallest to largest (easier to catch issues early)
const ALL_NETWORKS = ["RTS", "WECC240", "texas2k", "Texas7k", "CATS", "WECC10k"]

# Map network name -> bus coordinate file path
const NETWORK_BUS_FILES = Dict(
    "RTS"     => joinpath(DATA_DIR, "bus_lat_lons", "RTS_GMLC_bus.csv"),
    "CATS"    => joinpath(DATA_DIR, "bus_lat_lons", "CATS_bus.csv"),
    "Texas7k" => joinpath(DATA_DIR, "bus_lat_lons", "Texas7k_lat_long.csv"),
    "texas2k" => joinpath(DATA_DIR, "bus_lat_lons", "Texas2k_lat_long.csv"),
    "WECC10k" => joinpath(DATA_DIR, "bus_lat_lons", "WECC10k_lat_long.csv"),
    "WECC240" => joinpath(DATA_DIR, "bus_lat_lons", "wecc_lat_lon_good.csv"),
)

# PVWatts returns TMY data mapped to this non-leap reference year
const REFERENCE_YEAR = 2019

function parse_commandline()
    s = ArgParseSettings(description="Fetch NREL PVWatts solar data for all network buses")
    @add_arg_table! s begin
        "--api-key"
            help = "NREL API key (default: NREL_API_KEY env var)"
            default = ""
        "--network"
            help = "Process only this network (default: all networks)"
            default = ""
    end
    return parse_args(s)
end

"""
    fetch_pvwatts_all_year(lat, lon, api_key) -> (ac::Vector{Float64}, dc::Vector{Float64})

Call NREL PVWatts v8 API for a 1 kW system at (lat, lon). Returns 8760-element
vectors of hourly AC and DC output in per-unit (kW output / 1 kW system capacity).
"""
function fetch_pvwatts_all_year(lat::Float64, lon::Float64, api_key::String)
    response = HTTP.get(
        "https://developer.nlr.gov/api/pvwatts/v8.json";
        query = Dict(
            "api_key"         => api_key,
            "lat"             => string(lat),
            "lon"             => string(lon),
            "system_capacity" => "1",
            "module_type"     => "0",
            "losses"          => "14",
            "array_type"      => "0",
            "tilt"            => "20",
            "azimuth"         => "180",
            "timeframe"       => "hourly",
        )
    )
    response.status == 200 || error("PVWatts returned status $(response.status)")
    data = JSON.parse(String(response.body))
    if haskey(data, "errors") && !isempty(data["errors"])
        error("PVWatts API errors: $(data["errors"])")
    end
    ac = Float64.(data["outputs"]["ac"]) ./ 1000.0
    dc = Float64.(data["outputs"]["dc"]) ./ 1000.0
    length(ac) == 8760 || error("Expected 8760 hours, got $(length(ac))")
    return ac, dc
end

"""
    append_buses_to_csv(file_path, bus_profiles)

Append new bus profiles to an existing solar CSV (or create it with header if new).
bus_profiles: Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}} of only the new buses to write.
Date uses REFERENCE_YEAR (2019). Hour is 1..24 (hour of day, not absolute hour of year).
"""
function append_buses_to_csv(file_path::String, bus_profiles::Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}})
    mkpath(dirname(file_path))
    base_date = Date(REFERENCE_YEAR, 1, 1)
    write_header = !isfile(file_path)

    open(file_path, "a") do io
        if write_header
            println(io, "Bus_ID,Date,Hour,AC_Output_pu,DC_Output_pu")
        end
        for bus_id in sort(collect(keys(bus_profiles)))
            ac, dc = bus_profiles[bus_id]
            for h in 1:8760
                d = base_date + Day(div(h - 1, 24))
                hour_of_day = (h - 1) % 24 + 1
                @printf(io, "%d,%s,%d,%.6f,%.6f\n", bus_id, d, hour_of_day, ac[h], dc[h])
            end
        end
    end
end

"""
    load_bus_coords(network::String) -> DataFrame with columns Bus_ID, lat, lng
"""
function load_bus_coords(network::String)
    path = NETWORK_BUS_FILES[network]
    isfile(path) || error("Bus coordinate file not found: $path")
    df = CSV.read(path, DataFrame)
    return select(df, :Bus_ID, :lat, :lng)
end

"""
    load_existing_buses(file_path::String) -> Set{Int}

Return the set of Bus_IDs already present in an existing solar_data.csv.
Returns empty set if file doesn't exist.
"""
function load_existing_buses(file_path::String)
    isfile(file_path) || return Set{Int}()
    df = CSV.read(file_path, DataFrame; select=[:Bus_ID])
    return Set{Int}(df.Bus_ID)
end

"""
    process_network(network::String, api_key::String)

Fetch PVWatts TMY data for all buses in `network` and save to
data/solar_data/{network}/solar_data.csv. Resumes from existing file if present.
Deduplicates API calls by (lat, lon).
"""
function process_network(network::String, api_key::String)
    out_file = joinpath(SOLAR_DIR, network, "solar_data.csv")

    println("=" ^ 60)
    println("Network: $network")

    buses = load_bus_coords(network)
    # Filter buses with valid coordinates (skip missing or zero coords)
    buses = filter(r -> !ismissing(r.lat) && !ismissing(r.lng) && !(r.lat == 0.0 && r.lng == 0.0), buses)
    total_buses = nrow(buses)
    println("  Buses with coordinates: $total_buses")

    existing = load_existing_buses(out_file)
    missing_buses = filter(r -> r.Bus_ID ∉ existing, buses)
    println("  Already fetched: $(length(existing)), remaining: $(nrow(missing_buses))")

    if nrow(missing_buses) == 0
        println("  Complete — skipping.")
        return
    end

    # Location cache — avoid re-fetching buses at identical (lat, lon)
    # Only new buses are held in memory; existing data stays on disk (append-only)
    loc_cache = Dict{Tuple{Float64,Float64}, Tuple{Vector{Float64}, Vector{Float64}}}()
    pending = Dict{Int, Tuple{Vector{Float64}, Vector{Float64}}}()

    n_fetched = 0
    n_errors = 0
    for row in eachrow(missing_buses)
        bus_id = row.Bus_ID
        lat, lng = row.lat, row.lng
        loc_key = (lat, lng)

        if haskey(loc_cache, loc_key)
            pending[bus_id] = loc_cache[loc_key]
            n_fetched += 1
        else
            try
                ac, dc = fetch_pvwatts_all_year(lat, lng, api_key)
                profile = (ac, dc)
                loc_cache[loc_key] = profile
                pending[bus_id] = profile
                n_fetched += 1
                sleep(0.5)  # respect API rate limits
            catch e
                @warn "  Bus $bus_id at ($lat, $lng): $e"
                n_errors += 1
                continue
            end
        end

        if n_fetched % 10 == 0
            @printf("  Progress: %d / %d buses fetched\n", n_fetched + length(existing), total_buses)
        end
        # Flush to disk every 50 new buses to bound memory usage
        if n_fetched % 50 == 0
            println("  Incremental save...")
            append_buses_to_csv(out_file, pending)
            empty!(pending)
        end
    end

    # Flush any remaining pending buses
    if !isempty(pending)
        append_buses_to_csv(out_file, pending)
    end
    println("  Saved: $out_file")
    println("  Fetched: $n_fetched new, $n_errors errors")
end

function main()
    args = parse_commandline()
    api_key = isempty(args["api-key"]) ? get(ENV, "NREL_API_KEY", "DEMO_KEY") : args["api-key"]

    networks = isempty(args["network"]) ? ALL_NETWORKS : [args["network"]]
    for net in networks
        if !haskey(NETWORK_BUS_FILES, net)
            error("Unknown network: $net. Valid options: $(join(ALL_NETWORKS, ", "))")
        end
    end

    println("NREL PVWatts Solar Data Generator")
    println("Networks: $(join(networks, ", "))")
    println("API key: $(api_key == "DEMO_KEY" ? "DEMO_KEY (rate-limited to ~50 req/hr)" : "provided")")
    println()

    for net in networks
        process_network(net, api_key)
    end

    println("\nDone.")
end

main()
