"""
    generate_reference_data.jl

Generates a compact reference dataset (June 2020, June 2021 for RTS) from the
data/ archive. Run from the project root:

    julia scripts/generate_reference_data.jl

Requires: CSV, DataFrames (from the project environment).
Reads from: data/
Writes to:  test_data/
"""

using CSV, DataFrames, Dates

const PROJECT_ROOT = dirname(@__DIR__)
const SRC = joinpath(PROJECT_ROOT, "data")
const DST = joinpath(PROJECT_ROOT, "test_data")

function main()
    isdir(SRC) || error("data/ not found — ensure the full dataset is present in data/")

    # Clean destination
    isdir(DST) && rm(DST; recursive=true)

    # --- Directory structure ---
    networks_to_copy = [
        ("Texas7k", 2020), ("WECC10k", 2020), ("WECC240", 2020), ("texas2k", 2020)
    ]
    for (net, yr) in networks_to_copy
        mkpath(joinpath(DST, "USGS_FPI", net, string(yr), "forecast_day_1"))
    end
    mkpath(joinpath(DST, "USGS_FPI", "RTS"))
    for d in ["networks", "CATS", "bus_lat_lons", "US_Shapefiles", "solar_data"]
        mkpath(joinpath(DST, d))
    end

    # --- Static copies ---
    println("Copying static files...")
    for f in readdir(joinpath(SRC, "networks"))
        endswith(f, ".m") && cp(joinpath(SRC, "networks", f), joinpath(DST, "networks", f))
    end
    for f in readdir(joinpath(SRC, "bus_lat_lons"))
        endswith(f, ".csv") && cp(joinpath(SRC, "bus_lat_lons", f), joinpath(DST, "bus_lat_lons", f))
    end
    for f in readdir(joinpath(SRC, "US_Shapefiles"))
        cp(joinpath(SRC, "US_Shapefiles", f), joinpath(DST, "US_Shapefiles", f))
    end
    for f in ["CATS_buses.csv", "CATS_gens.csv"]
        cp(joinpath(SRC, "CATS", f), joinpath(DST, "CATS", f))
    end

    # --- Wildfire JLD2 files (June only) ---
    println("Copying June wildfire JLD2 files...")
    fpi_name_map = Dict("Texas7k" => "Texas7k", "WECC10k" => "WECC10k",
                        "WECC240" => "WECC240", "texas2k" => "Texas2k", "RTS" => "RTS")
    for (net_dir, yr) in networks_to_copy
        fpi_name = fpi_name_map[net_dir]
        src_dir = joinpath(SRC, "USGS_FPI", net_dir, string(yr), "forecast_day_1")
        dst_dir = joinpath(DST, "USGS_FPI", net_dir, string(yr), "forecast_day_1")
        for d in 1:30
            fname = "FPI_$(fpi_name)_fday1_year$(yr)_month6_day$(d).jld2"
            src_f = joinpath(src_dir, fname)
            if isfile(src_f)
                cp(src_f, joinpath(dst_dir, fname))
            else
                @warn "Missing: $fname"
            end
        end
    end

    # --- CATS wildfire risk CSV (June 2020 only) ---
    println("Filtering CATS wildfire risk CSV to June 2020...")
    risk = CSV.read(joinpath(SRC, "USGS_FPI", "CATS", "2020_risk.csv"), DataFrame)
    june_risk = filter(row -> begin
        d = Date(row.date_of_forecast)
        month(d) == 6 && year(d) == 2020
    end, risk)
    mkpath(joinpath(DST, "USGS_FPI", "CATS"))
    CSV.write(joinpath(DST, "USGS_FPI", "CATS", "2020_risk.csv"), june_risk)
    println("  $(nrow(risk)) → $(nrow(june_risk)) rows")

    # --- RTS wildfire risk CSV (June 2020 only) ---
    println("Filtering RTS wildfire risk CSV to June 2020...")
    rts_risk = CSV.read(joinpath(SRC, "USGS_FPI", "RTS", "2020_risk.csv"), DataFrame)
    rts_june_risk = filter(row -> begin
        d = Date(row.date_of_forecast)
        month(d) == 6 && year(d) == 2020
    end, rts_risk)
    CSV.write(joinpath(DST, "USGS_FPI", "RTS", "2020_risk.csv"), rts_june_risk)
    println("  $(nrow(rts_risk)) → $(nrow(rts_june_risk)) rows")

    # --- CATS HourlyProduction (June hours of 2019) ---
    println("Subsetting HourlyProduction2019.csv to June...")
    prod = CSV.read(joinpath(SRC, "CATS", "HourlyProduction2019.csv"), DataFrame)
    # 2019 non-leap: Jan(744)+Feb(672)+Mar(744)+Apr(720)+May(744) = 3624
    june_prod = prod[3625:4344, :]
    CSV.write(joinpath(DST, "CATS", "HourlyProduction2019.csv"), june_prod)
    println("  $(nrow(prod)) → $(nrow(june_prod)) rows")

    # --- CATS Load scenarios (June columns) ---
    println("Subsetting Load_Agg_Post_Assignment_v3_latest.csv to June columns...")
    load_data = CSV.read(joinpath(SRC, "CATS", "Load_Agg_Post_Assignment_v3_latest.csv"),
                         DataFrame; header=false)
    june_load = load_data[:, 3625:4344]
    CSV.write(joinpath(DST, "CATS", "Load_Agg_Post_Assignment_v3_latest.csv"),
              june_load; header=false)
    println("  $(size(load_data)) → $(size(june_load))")

    # --- Metadata ---
    open(joinpath(DST, "CATS", "cats_metadata.json"), "w") do f
        write(f, """{"hour_offset": 3624, "num_hours": 720, "description": "June reference subset (hours indexed from 2019 non-leap year production data)"}""")
    end

    # --- Solar data (June rows only) ---
    println("Subsetting solar data to June...")
    solar_networks = ["RTS", "CATS", "Texas7k", "texas2k", "WECC10k", "WECC240"]
    for net in solar_networks
        src_solar = joinpath(SRC, "solar_data", net, "solar_data.csv")
        dst_solar = joinpath(DST, "solar_data", net, "solar_data.csv")
        if !isfile(src_solar)
            @warn "Solar data not found for $net at $src_solar — skipping"
            continue
        end
        mkpath(dirname(dst_solar))
        solar_df = CSV.read(src_solar, DataFrame)
        june_solar = filter(row -> month(Date(row.Date)) == 6, solar_df)
        CSV.write(dst_solar, june_solar)
        println("  $net: $(nrow(solar_df)) → $(nrow(june_solar)) rows")
    end

    println("\nDone! Reference dataset written to data/")
    println("Total size: ")
    run(`du -sh $DST`)
end

main()
