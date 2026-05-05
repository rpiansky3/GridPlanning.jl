using Pkg
Pkg.activate(".")

using HTTP
using JSON
using CSV
using DataFrames
using Dates
using PowerModels
using JLD2

# Include the files
include("../src/preprocessing.jl")
include("../src/solar_data.jl")

println("Files included.")


# Test
network = "WECC240"
date = "all"

println("Testing get_network_solar_data for $network (all buses, full year)...")

try
    # Test 1: Return data - Commented out for full year fetch
    # println("\n--- Test 1: Returning data ---")
    # solar_data = get_network_solar_data(network, date)

    # println("Success! Got data for $(length(solar_data)) buses.")
    # for (bus, profiles) in solar_data
    #     ac = profiles["ac"]
    #     dc = profiles["dc"]
    #     println("Bus $bus: $(length(ac)) hours")
    #     println("  Max AC: $(round(maximum(ac), digits=3))")
    #     println("  Max DC: $(round(maximum(dc), digits=3))")
    # end

    # Test 2: Save to file
    println("\n--- Test 2: Saving to file ---")
    output_dir = "data/solar_data"
    if !isdir(output_dir)
        mkpath(output_dir)
    end
    get_network_solar_data(network, date; save_to_file=true, output_dir=output_dir)
    println("Check $(output_dir) directory for CSV.")

catch e
    println("Error: $e")
    rethrow(e)
end
