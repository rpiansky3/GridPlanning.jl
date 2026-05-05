#!/usr/bin/env julia
"""
    fetch_wfpi_data.jl

Downloads USGS WFPI GeoTIFF rasters, computes per-transmission-line wildfire
risk metrics, and outputs CSVs to data/USGS_FPI/<network>/<year>_risk.csv.

Usage:
    julia --project=scripts scripts/fetch_wfpi_data.jl --network RTS --start 2021-06-01 --end 2021-06-30

Run from the project root directory.
"""

using ArgParse, ArchGDAL, CSV, DataFrames, Dates, Distributed, Downloads
using Extents, GeoInterface, GeoJSON, Hwloc, JSON, PowerModels
using Printf, ProgressMeter, Rasters, Statistics, ZipFile

PowerModels.silence()
# macOS Sys.free_memory() returns only truly-free pages (not inactive), causing
# Rasters to incorrectly reject operations that fit comfortably in actual available RAM.
Rasters.checkmem!(false)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

const BASE_DIR = dirname(@__DIR__)
const DATA_DIR = joinpath(BASE_DIR, "data")
const USGS_FPI_DIR = joinpath(DATA_DIR, "USGS_FPI")
const CACHE_DIR = joinpath(USGS_FPI_DIR, "cache")
const TIFF_CACHE_DIR = joinpath(CACHE_DIR, "tiffs")
const THRESHOLD_CACHE_FILE = joinpath(CACHE_DIR, "thresholds.json")

const USGS_URL_TEMPLATE = "https://edcintl.cr.usgs.gov/downloads/sciweb1/shared/firedanger/download-tool/bulk_download/yearly_bundle/{YEAR}/{YEAR}_Wind-enhanced_Fire_Potential_Index_Forecast_1_DATA.zip"

# Map user-facing network name -> FPI output directory name
const NETWORK_FPI_NAMES = Dict(
    "RTS"          => "RTS",
    "RTS_GMLC"     => "RTS",
    "CATS"         => "CATS",
    "Texas7k"      => "Texas7k",
    "Texas2k"      => "texas2k",
    "ACTIVSg2000"  => "texas2k",
    "WECC10k"      => "WECC10k",
    "ACTIVSg10k"   => "WECC10k",
    "WECC240"      => "WECC240",
    "pserc240"     => "WECC240",
)

# Map user-facing network name -> .m file name in data/networks/
const NETWORK_FILE_NAMES = Dict(
    "RTS"          => "RTS_GMLC.m",
    "RTS_GMLC"     => "RTS_GMLC.m",
    "CATS"         => "CaliforniaTestSystem.m",
    "Texas7k"      => "Texas7k_20210804.m",
    "Texas2k"      => "case_ACTIVSg2000.m",
    "ACTIVSg2000"  => "case_ACTIVSg2000.m",
    "WECC10k"      => "case_ACTIVSg10k.m",
    "ACTIVSg10k"   => "case_ACTIVSg10k.m",
    "WECC240"      => "pglib_opf_case240_pserc.m",
    "pserc240"     => "pglib_opf_case240_pserc.m",
)

# Map user-facing network name -> bus coordinate CSV in data/bus_lat_lons/
const BUS_COORD_FILES = Dict(
    "RTS"          => "RTS_GMLC_bus.csv",
    "RTS_GMLC"     => "RTS_GMLC_bus.csv",
    "CATS"         => "CATS_bus.csv",
    "Texas7k"      => "Texas7k_lat_long.csv",
    "Texas2k"      => "Texas2k_lat_long.csv",
    "ACTIVSg2000"  => "Texas2k_lat_long.csv",
    "WECC10k"      => "WECC10k_lat_long.csv",
    "ACTIVSg10k"   => "WECC10k_lat_long.csv",
    "WECC240"      => "wecc_lat_lon_good.csv",
    "pserc240"     => "wecc_lat_lon_good.csv",
)

# ---------------------------------------------------------------------------
# Stage 1 — Download
# ---------------------------------------------------------------------------

"""
    ensure_tiffs_cached(year::Int) -> String

Ensures WFPI GeoTIFFs for `year` are present in TIFF_CACHE_DIR/<year>/.
Downloads and extracts the USGS ZIP bundle if not already cached.
Returns the path to the directory containing the TIFFs.
"""
function ensure_tiffs_cached(year::Int)::String
    out_dir = joinpath(TIFF_CACHE_DIR, string(year))
    if isdir(out_dir) && !isempty(readdir(out_dir))
        return out_dir
    end
    mkpath(out_dir)

    url = replace(USGS_URL_TEMPLATE, "{YEAR}" => string(year))
    zip_path = joinpath(CACHE_DIR, "$(year)_wfpi.zip")

    println("Downloading WFPI data for $year from USGS...")
    _download_with_retry(url, zip_path)

    println("Extracting TIFFs for $year...")
    _extract_tiffs(zip_path, out_dir)

    # Remove the outer zip to save space
    isfile(zip_path) && rm(zip_path)

    return out_dir
end

"""
    _download_with_retry(url, dest; max_retries=3)

Download `url` to `dest` with exponential backoff on failure.
"""
function _download_with_retry(url::String, dest::String; max_retries::Int=3)
    mkpath(dirname(dest))
    for attempt in 1:max_retries
        try
            Downloads.download(url, dest)
            return
        catch e
            if attempt == max_retries
                rethrow(e)
            end
            wait_secs = 2^attempt
            @warn "Download attempt $attempt failed: $e. Retrying in $(wait_secs)s..."
            sleep(wait_secs)
        end
    end
end

"""
    _extract_tiffs(zip_path, out_dir)

Extract .tiff files from a (possibly nested) ZIP bundle.
USGS bundles contain inner ZIPs each holding .tiff files.
Output filenames are prefixed with "1_" if not already prefixed
(indicating forecast day 1).
"""
function _extract_tiffs(zip_path::String, out_dir::String)
    mkpath(out_dir)
    outer_zip = ZipFile.Reader(zip_path)
    try
        for f in outer_zip.files
            name = f.name
            if endswith(lowercase(name), ".zip")
                # Nested ZIP — read into memory and recurse
                inner_data = read(f)
                inner_zip_path = joinpath(out_dir, basename(name))
                write(inner_zip_path, inner_data)
                inner_zip = ZipFile.Reader(inner_zip_path)
                try
                    for inner_f in inner_zip.files
                        iname = inner_f.name
                        if endswith(lowercase(iname), ".tiff") || endswith(lowercase(iname), ".tif")
                            fname = basename(iname)
                            if !startswith(fname, "1_")
                                fname = "1_" * fname
                            end
                            dest = joinpath(out_dir, fname)
                            write(dest, read(inner_f))
                        end
                    end
                finally
                    close(inner_zip)
                end
                rm(inner_zip_path; force=true)
            elseif endswith(lowercase(name), ".tiff") || endswith(lowercase(name), ".tif")
                fname = basename(name)
                if !startswith(fname, "1_")
                    fname = "1_" * fname
                end
                dest = joinpath(out_dir, fname)
                write(dest, read(f))
            end
        end
    finally
        close(outer_zip)
    end
end

"""
    find_tiff_for_date(tiff_dir, date) -> Union{String, Nothing}

Find the WFPI TIFF file for a given date.
Expected filename pattern: 1_emodis-wfpi_data_YYYYMMDD_YYYYMMDD.tiff
"""
function find_tiff_for_date(tiff_dir::String, date::Date)::Union{String,Nothing}
    date_str = Dates.format(date, "yyyymmdd")
    for fname in readdir(tiff_dir)
        if startswith(fname, "1_") && occursin(date_str, fname) &&
           (endswith(fname, ".tiff") || endswith(fname, ".tif"))
            return joinpath(tiff_dir, fname)
        end
    end
    return nothing
end

# ---------------------------------------------------------------------------
# Stage 2 — Line Geometry Generation
# ---------------------------------------------------------------------------

"""
    _load_cats_geometries() -> Vector

Load CATS transmission line geometries from the project GeoJSON file.
Returns a vector of GeoInterface-compatible geometry objects.
"""
function _load_cats_geometries()
    geojson_path = joinpath(DATA_DIR, "CATS", "CATS_lines.geojson")
    isfile(geojson_path) || error("CATS GeoJSON not found: $geojson_path")
    fc = GeoJSON.read(read(geojson_path, String))
    geometries = []
    for feature in GeoInterface.getfeature(fc)
        geom = GeoInterface.geometry(feature)
        push!(geometries, geom)
    end
    return geometries
end

"""
    _load_bus_coords(network) -> DataFrame

Load bus lat/lon coordinates for a network.
Normalises column names to :Bus_ID, :lat, :lng.
"""
function _load_bus_coords(network::String)::DataFrame
    coord_file = get(BUS_COORD_FILES, network, nothing)
    coord_file === nothing && error("No bus coordinate file registered for network: $network")
    path = joinpath(DATA_DIR, "bus_lat_lons", coord_file)
    isfile(path) || error("Bus coordinate file not found: $path")

    df = CSV.read(path, DataFrame; header=1, silencewarnings=true)

    # Normalise column names
    rename_map = Dict{String,String}()
    for col in names(df)
        lc = lowercase(col)
        if lc == "bus_id"
            rename_map[col] = "Bus_ID"
        elseif lc == "lat"
            rename_map[col] = "lat"
        elseif lc in ("lng", "lon")
            rename_map[col] = "lng"
        end
    end
    rename!(df, rename_map)

    # Keep only needed columns and drop rows with missing values
    select!(df, [:Bus_ID, :lat, :lng])
    dropmissing!(df)
    return df
end

"""
    _generate_point_to_point_geometries(network) -> (Vector, Dict{Int,Int})

Build LineString geometries for each branch in a PowerModels network.
Returns `(geometries, id_map)` where `id_map[i]` is the PowerModels branch id
corresponding to `geometries[i]`.
"""
function _generate_point_to_point_geometries(network::String)
    net_file = get(NETWORK_FILE_NAMES, network, nothing)
    net_file === nothing && error("No network file registered for network: $network")
    net_path = joinpath(DATA_DIR, "networks", net_file)
    isfile(net_path) || error("Network file not found: $net_path")

    bus_coords = _load_bus_coords(network)
    # Build lookup: bus_id -> (lat, lon)
    coord_lookup = Dict{Int,Tuple{Float64,Float64}}()
    for row in eachrow(bus_coords)
        # Skip rows with missing coordinates
        (ismissing(row.lat) || ismissing(row.lng) || ismissing(row.Bus_ID)) && continue
        coord_lookup[Int(row.Bus_ID)] = (Float64(row.lat), Float64(row.lng))
    end

    # Parse network
    data = PowerModels.parse_file(net_path)
    ref_full = PowerModels.build_ref(data)
    ref = ref_full[:it][:pm][:nw][0]

    geometries = []
    id_map = Dict{Int,Int}()  # geometry index -> branch id

    for (branch_id, branch) in ref[:branch]
        f_bus = branch["f_bus"]
        t_bus = branch["t_bus"]

        if !haskey(coord_lookup, f_bus) || !haskey(coord_lookup, t_bus)
            continue
        end

        f_lat, f_lon = coord_lookup[f_bus]
        t_lat, t_lon = coord_lookup[t_bus]

        # Skip buses with zero/missing coordinates
        if (f_lat == 0.0 && f_lon == 0.0) || (t_lat == 0.0 && t_lon == 0.0)
            continue
        end

        geom = GeoInterface.LineString([(f_lon, f_lat), (t_lon, t_lat)])
        push!(geometries, geom)
        id_map[length(geometries)] = branch_id
    end

    return geometries, id_map
end

"""
    compute_network_extent(network; padding=0.5) -> Extents.Extent

Compute the bounding box of a network's bus coordinates with optional padding.
"""
function compute_network_extent(network::String; padding::Float64=0.5)::Extents.Extent
    bus_coords = _load_bus_coords(network)
    lats = filter(x -> x != 0.0, Float64.(bus_coords.lat))
    lons = filter(x -> x != 0.0, Float64.(bus_coords.lng))
    isempty(lats) && error("No valid coordinates found for network: $network")

    min_lat = minimum(lats) - padding
    max_lat = maximum(lats) + padding
    min_lon = minimum(lons) - padding
    max_lon = maximum(lons) + padding

    return Extents.Extent(X=(min_lon, max_lon), Y=(min_lat, max_lat))
end

# ---------------------------------------------------------------------------
# Stage 3 — Threshold Computation
# ---------------------------------------------------------------------------

"""
    ensure_threshold_cached(network, geometries, calibration_year) -> Int

Return the risk threshold for `network`, computing and caching it if needed.
Threshold = floor(mean(pixels) + std(pixels)) over all valid pixels across
all lines in the calibration year.
"""
function ensure_threshold_cached(network::String, geometries::Vector, calibration_year::Int)::Int
    fpi_name = get(NETWORK_FPI_NAMES, network, network)
    cache_key = "$(fpi_name)_$(calibration_year)"

    cache = _load_threshold_cache()
    if haskey(cache, cache_key)
        return Int(cache[cache_key])
    end

    println("Computing risk threshold for $network (calibration year $calibration_year)...")
    ext = compute_network_extent(network)
    tiff_dir = ensure_tiffs_cached(calibration_year)

    pixel_values = Float64[]
    tiff_files = filter(f -> startswith(f, "1_") && (endswith(f, ".tiff") || endswith(f, ".tif")),
                        readdir(tiff_dir))

    prog = Progress(length(tiff_files); desc="Threshold calibration: ")
    for fname in tiff_files
        tiff_path = joinpath(tiff_dir, fname)
        try
            wfpi = _load_and_crop_raster(tiff_path, ext)
            _collect_masked_pixels!(pixel_values, wfpi, geometries)
        catch e
            @warn "Skipping $fname during threshold calibration: $e"
        end
        next!(prog)
    end

    if isempty(pixel_values)
        error("No valid pixels found for threshold calibration")
    end

    threshold = floor(Int, mean(pixel_values) + std(pixel_values))
    cache[cache_key] = threshold
    _save_threshold_cache(cache)
    println("Threshold for $network: $threshold")
    return threshold
end

"""
    _load_and_crop_raster(tiff_path, ext) -> Raster

Load a WFPI GeoTIFF, reproject to WGS84 (EPSG:4326), and crop to `ext`.
"""
function _load_and_crop_raster(tiff_path::String, ext::Extents.Extent)
    raster = Raster(tiff_path; missingval=0xff, lazy=true)
    # Resample to EPSG:4326 if needed, then crop to extent, then materialize
    raster = resample(raster; crs=EPSG(4326), method=:near)
    raster = crop(raster; to=ext)
    return read(raster)
end

"""
    _collect_masked_pixels!(pixel_values, wfpi, geometries)

Append all valid pixel values (≤247) within the union of all line geometries
to `pixel_values`. Builds a combined mask to avoid double-counting overlapping
pixels.
"""
function _collect_masked_pixels!(pixel_values::Vector{Float64}, wfpi, geometries::Vector)
    # Build combined mask (union of all line masks) to avoid double-counting
    combined_mask = Rasters.boolmask(geometries[1]; to=wfpi)
    for i in 2:length(geometries)
        combined_mask .|= Rasters.boolmask(geometries[i]; to=wfpi)
    end

    wfpi_data = Matrix{Int}(wfpi.data)
    for I in eachindex(wfpi_data)
        if combined_mask[I] && wfpi_data[I] <= 247
            push!(pixel_values, Float64(wfpi_data[I]))
        end
    end
end

"""
    _load_threshold_cache() -> Dict{String,Any}

Load the threshold JSON cache file, returning empty dict if not found.
"""
function _load_threshold_cache()::Dict{String,Any}
    isfile(THRESHOLD_CACHE_FILE) || return Dict{String,Any}()
    try
        return JSON.parsefile(THRESHOLD_CACHE_FILE)
    catch
        return Dict{String,Any}()
    end
end

"""
    _save_threshold_cache(cache)

Write the threshold cache dict to JSON.
"""
function _save_threshold_cache(cache::Dict)
    mkpath(dirname(THRESHOLD_CACHE_FILE))
    open(THRESHOLD_CACHE_FILE, "w") do io
        JSON.print(io, cache, 2)
    end
end

# ---------------------------------------------------------------------------
# Stage 4 — Per-Line Risk Processing
# ---------------------------------------------------------------------------

"""
    process_day(tiff_path, date, geometries, ext, threshold; id_map=nothing)
        -> Vector{NamedTuple}

Process one day's WFPI raster and return per-line risk metrics.
`id_map` maps geometry index to branch id; if nothing, geometry index is used.
"""
function process_day(tiff_path::String, date::Date, geometries::Vector,
                     ext::Extents.Extent, threshold::Int;
                     id_map::Union{Dict{Int,Int},Nothing}=nothing)

    wfpi = _load_and_crop_raster(tiff_path, ext)
    results = NamedTuple[]

    wfpi_data = Matrix{Int}(wfpi.data)

    for (i, geom) in enumerate(geometries)
        branch_id = id_map !== nothing ? get(id_map, i, i) : i
        mask = Rasters.boolmask(geom; to=wfpi)
        metrics = _compute_line_metrics(wfpi_data, BitMatrix(mask.data), threshold)

        push!(results, (
            date_of_forecast = date,
            date_of_risk     = date,
            branch_id        = branch_id,
            max_wfpi         = metrics.max_wfpi,
            mean_wfpi        = metrics.mean_wfpi,
            cum_wfpi         = metrics.cum_wfpi,
            hr_max_wfpi      = metrics.hr_max_wfpi,
            hr_mean_wfpi     = metrics.hr_mean_wfpi,
            hr_cum_wfpi      = metrics.hr_cum_wfpi,
        ))
    end

    return results
end

"""
    _compute_line_metrics(wfpi_data, mask, threshold) -> NamedTuple

Compute the 6 risk metrics for a single line given its pixel mask.
Only pixels with value ≤ 247 are counted as valid.
High-risk (hr_) metrics count only pixels that also exceed `threshold`.
"""
function _compute_line_metrics(wfpi_data::Matrix{Int}, mask::BitMatrix, threshold::Int)
    max_val   = 0
    sum_val   = 0
    count_val = 0
    hr_max    = 0
    hr_sum    = 0

    for I in eachindex(wfpi_data)
        @inbounds if mask[I]
            if wfpi_data[I] <= 247
                count_val += 1
                sum_val += wfpi_data[I]
                if wfpi_data[I] > max_val
                    max_val = wfpi_data[I]
                end
                if wfpi_data[I] > threshold
                    hr_sum += wfpi_data[I]
                    if wfpi_data[I] > hr_max
                        hr_max = wfpi_data[I]
                    end
                end
            end
        end
    end

    mean_val    = count_val > 0 ? sum_val / count_val : 0.0
    hr_mean_val = count_val > 0 ? hr_sum / count_val : 0.0

    return (
        max_wfpi    = max_val,
        mean_wfpi   = mean_val,
        cum_wfpi    = sum_val,
        hr_max_wfpi = hr_max,
        hr_mean_wfpi = hr_mean_val,
        hr_cum_wfpi = hr_sum,
    )
end

# ---------------------------------------------------------------------------
# Stage 5 — Output
# ---------------------------------------------------------------------------

"""
    write_risk_csv(results, network, year; force=false)

Write computed risk results to `data/USGS_FPI/<fpi_name>/<year>_risk.csv`.
If the file already exists:
  - force=true:  remove rows for recomputed dates, then append new results
  - force=false: skip dates already present, only write new dates
"""
function write_risk_csv(results::Vector, network::String, year::Int; force::Bool=false)
    fpi_name = get(NETWORK_FPI_NAMES, network, network)
    out_dir  = joinpath(USGS_FPI_DIR, fpi_name)
    mkpath(out_dir)
    out_path = joinpath(out_dir, "$(year)_risk.csv")

    new_df = DataFrame(results)

    if isfile(out_path)
        existing_df = CSV.read(out_path, DataFrame)
        new_dates = Set(new_df.date_of_forecast)

        if force
            # Remove existing rows for dates we're recomputing
            existing_df = filter(row -> row.date_of_forecast ∉ new_dates, existing_df)
            combined = vcat(existing_df, new_df)
        else
            # Skip dates already in the CSV
            existing_dates = Set(existing_df.date_of_forecast)
            new_df = filter(row -> row.date_of_forecast ∉ existing_dates, new_df)
            combined = vcat(existing_df, new_df)
        end
    else
        combined = new_df
    end

    sort!(combined, [:date_of_forecast, :branch_id])
    CSV.write(out_path, combined)
    println("Wrote $(nrow(combined)) rows to $out_path")
end

# ---------------------------------------------------------------------------
# Main Orchestration
# ---------------------------------------------------------------------------

"""
    _to_date(d) -> Date

Convert Date, Tuple{Int,Int,Int}, or String to Date.
"""
_to_date(d::Date) = d
_to_date(d::Tuple) = Date(d[1], d[2], d[3])
_to_date(d::String) = Date(d)

"""
    _process_sequential(network, dates, geometries, ext, threshold, id_map; force)

Process all dates sequentially with a progress bar.
Groups results by year and writes CSVs per year.
"""
function _process_sequential(network::String, dates::Vector{Date},
                              geometries::Vector, ext::Extents.Extent,
                              threshold::Int, id_map::Union{Dict{Int,Int},Nothing};
                              force::Bool=false)
    # Group dates by year
    by_year = Dict{Int,Vector{Date}}()
    for d in dates
        yr = Dates.year(d)
        push!(get!(by_year, yr, Date[]), d)
    end

    all_results = Dict{Int,Vector}()
    for yr in keys(by_year)
        all_results[yr] = []
    end

    @showprogress "Processing days: " for date in dates
        yr = Dates.year(date)
        tiff_dir = ensure_tiffs_cached(yr)
        tiff_path = find_tiff_for_date(tiff_dir, date)
        if tiff_path === nothing
            @warn "No TIFF found for $date, skipping."
            continue
        end
        day_results = process_day(tiff_path, date, geometries, ext, threshold; id_map=id_map)
        append!(all_results[yr], day_results)
    end

    for (yr, res) in all_results
        isempty(res) && continue
        write_risk_csv(res, network, yr; force=force)
    end
end

"""
    _process_parallel(network, dates, geometries, ext, threshold, id_map, nworkers_req; force)

Process dates in parallel using Distributed workers.
"""
function _process_parallel(network::String, dates::Vector{Date},
                            geometries::Vector, ext::Extents.Extent,
                            threshold::Int, id_map::Union{Dict{Int,Int},Nothing},
                            nworkers_req::Int; force::Bool=false)
    n = nworkers_req <= 0 ? Hwloc.num_physical_cores() : nworkers_req
    actual = min(n, length(dates))
    println("Starting $actual distributed workers...")
    Distributed.addprocs(actual)

    script_path = @__FILE__

    # Load dependencies and this script on all workers.
    # Using Distributed.remotecall_eval to avoid @everywhere at non-toplevel.
    Distributed.remotecall_eval(Main, Distributed.workers(),
        :(using Rasters, Extents, GeoInterface, GeoJSON))
    Distributed.remotecall_eval(Main, Distributed.workers(),
        :(include($script_path)))

    # Build work items: (tiff_path, date) pairs
    work_items = Tuple{String,Date}[]
    for date in dates
        yr = Dates.year(date)
        tiff_dir = ensure_tiffs_cached(yr)
        tiff_path = find_tiff_for_date(tiff_dir, date)
        if tiff_path === nothing
            @warn "No TIFF found for $date, skipping."
            continue
        end
        push!(work_items, (tiff_path, date))
    end

    # Distribute
    pmap_results = pmap(work_items) do (tiff_path, date)
        process_day(tiff_path, date, geometries, ext, threshold; id_map=id_map)
    end

    # Group by year and write
    by_year = Dict{Int,Vector}()
    for day_res in pmap_results
        isempty(day_res) && continue
        yr = Dates.year(first(day_res).date_of_forecast)
        push!(get!(by_year, yr, []), day_res...)
    end

    for (yr, res) in by_year
        isempty(res) && continue
        write_risk_csv(res, network, yr; force=force)
    end

    Distributed.rmprocs(Distributed.workers())
end

"""
    fetch_wfpi_data(network, start_date, end_date=start_date;
                    nworkers=0, calibration_year=2019, force=false)

Main entry point. Downloads WFPI rasters, computes per-line risk metrics, and
writes results to data/USGS_FPI/<network>/<year>_risk.csv.

- `nworkers=0`: use number of physical cores; set to 1 to run sequentially.
- `calibration_year`: year used to compute risk threshold.
- `force`: overwrite existing dates.
"""
function fetch_wfpi_data(network::String, start_date, end_date=start_date;
                         nworkers::Int=0, calibration_year::Int=2019, force::Bool=false)
    d_start = _to_date(start_date)
    d_end   = _to_date(end_date)
    d_start > d_end && error("start_date must be ≤ end_date")

    dates = collect(d_start:Day(1):d_end)
    println("Processing $(length(dates)) day(s) for network: $network")

    # Build geometries
    println("Building line geometries...")
    if network == "CATS" || get(NETWORK_FPI_NAMES, network, network) == "CATS"
        geometries = _load_cats_geometries()
        id_map = nothing
    else
        geometries, id_map = _generate_point_to_point_geometries(network)
    end
    println("  $(length(geometries)) lines loaded.")

    # Compute extent
    ext = compute_network_extent(network)

    # Ensure calibration TIFFs are cached
    ensure_tiffs_cached(calibration_year)

    # Compute threshold
    threshold = ensure_threshold_cached(network, geometries, calibration_year)

    # Process
    if nworkers == 1 || length(dates) == 1
        _process_sequential(network, dates, geometries, ext, threshold, id_map; force=force)
    else
        _process_parallel(network, dates, geometries, ext, threshold, id_map, nworkers; force=force)
    end

    println("Done.")
end

# ---------------------------------------------------------------------------
# CLI Entry Point
# ---------------------------------------------------------------------------

"""
    parse_commandline() -> Dict

Parse CLI arguments.
"""
function parse_commandline()
    s = ArgParseSettings(
        description = "Download USGS WFPI rasters and compute per-line wildfire risk metrics.",
        version     = "1.0",
        add_version = true,
    )

    @add_arg_table! s begin
        "--network", "-n"
            help     = "Network name (e.g. RTS, CATS, Texas7k, Texas2k, WECC10k, WECC240)"
            arg_type = String
            required = true

        "--start", "-s"
            help     = "Start date (YYYY-MM-DD)"
            arg_type = String
            required = true

        "--end", "-e"
            help     = "End date (YYYY-MM-DD, defaults to start)"
            arg_type = String
            default  = ""

        "--nworkers"
            help     = "Number of parallel workers (0 = auto, 1 = sequential)"
            arg_type = Int
            default  = 0

        "--calibration-year"
            help     = "Year used to compute risk threshold"
            arg_type = Int
            default  = 2019

        "--force"
            help     = "Overwrite existing dates in output CSV"
            action   = :store_true
    end

    return parse_args(s)
end

if abspath(PROGRAM_FILE) == @__FILE__
    args = parse_commandline()

    network          = args["network"]
    start_date       = Date(args["start"])
    end_date_str     = args["end"]
    end_date         = isempty(end_date_str) ? start_date : Date(end_date_str)
    nworkers         = args["nworkers"]
    calibration_year = args["calibration-year"]
    force            = args["force"]

    fetch_wfpi_data(network, start_date, end_date;
                    nworkers=nworkers,
                    calibration_year=calibration_year,
                    force=force)
end
