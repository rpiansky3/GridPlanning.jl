#!/usr/bin/env julia
"""
    generate_census_data.jl

Build a per-bus Census ACS demographics CSV for each supported network.
Each run pulls tract-level demographics within a per-bus radius of the
network, runs the 3-pass population-assignment algorithm, aggregates to
per-bus totals, and writes a single CSV per (network, year) to
`data/census_data/{network}_census_{year}.csv`.

Usage (run from project root):
    julia --project=. scripts/generate_census_data.jl
    julia --project=. scripts/generate_census_data.jl --network RTS
    julia --project=. scripts/generate_census_data.jl --api-key YOUR_KEY
    julia --project=. scripts/generate_census_data.jl --acs-year 2022
    julia --project=. scripts/generate_census_data.jl --radius-km 25
    julia --project=. scripts/generate_census_data.jl --weighting proportional

Requires the tract shapefile at `data/US_Shapefiles/cb_2023_us_tract_500k.*`:
    mkdir -p data/US_Shapefiles
    curl -L -o data/US_Shapefiles/cb_2023_us_tract_500k.zip \\
      https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_tract_500k.zip
    unzip -o data/US_Shapefiles/cb_2023_us_tract_500k.zip -d data/US_Shapefiles/

Census API key is optional (anonymous access is rate-limited to ~500
req/day). Get one at https://api.census.gov/data/key_signup.html and set
`CENSUS_API_KEY` in the environment or pass `--api-key`.
"""

using ArgParse

const BASE_DIR = dirname(@__DIR__)

import Pkg
Pkg.activate(BASE_DIR)
using GridPlanning

const ALL_NETWORKS = ["RTS", "WECC240", "texas2k", "Texas7k", "WECC10k", "CATS"]

function parse_commandline()
    s = ArgParseSettings(description="Generate per-bus Census ACS demographic CSVs")
    @add_arg_table! s begin
        "--api-key"
            help = "Census API key (default: CENSUS_API_KEY env var; anonymous fallback)"
            default = ""
        "--network"
            help = "Process only this network (default: all networks)"
            default = ""
        "--acs-year"
            help = "ACS 5-year vintage year (default: 2022)"
            arg_type = Int
            default = 2022
        "--radius-km"
            help = "Per-bus tract-inclusion radius, in km (default: 25)"
            arg_type = Float64
            default = 25.0
        "--weighting"
            help = "Weighting for multi-bus tracts: inverse (default) or proportional"
            default = "inverse"
    end
    return parse_args(s)
end

function main()
    args = parse_commandline()
    api_key = isempty(args["api-key"]) ? get(ENV, "CENSUS_API_KEY", "") : args["api-key"]
    acs_year = args["acs-year"]
    radius_m = args["radius-km"] * 1_000.0

    weighting_str = args["weighting"]
    weighting_str in ("inverse", "proportional") ||
        error("Invalid --weighting '$weighting_str'. Use 'inverse' or 'proportional'.")
    weighting = Symbol(weighting_str)

    networks = isempty(args["network"]) ? ALL_NETWORKS : [args["network"]]

    println("Census ACS Demographic Data Generator")
    println("Networks:  $(join(networks, ", "))")
    println("ACS year:  $acs_year")
    println("Radius:    $(args["radius-km"]) km per bus")
    println("Weighting: $weighting_str")
    println("API key:   $(isempty(api_key) ? "anonymous (~500 req/day)" : "provided")")
    println()

    for net in networks
        println("=" ^ 60)
        println("Network: $net")
        try
            get_network_census(net; api_key=api_key, acs_year=acs_year,
                               radius_m=radius_m, weighting=weighting)
        catch e
            @warn "Failed to process $net: $e"
        end
    end

    println("\nDone.")
end

main()
