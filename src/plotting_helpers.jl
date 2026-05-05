# Shared plotting helpers: coordinate projection, basemap loading, results translation
# Requires: Shapefile, DBFTables, GeoInterface, DataFrames, CSV, JLD2

"""Convert WGS84 (lat, lon) to Web Mercator (x, y) in meters."""
function latlon_to_webmercator(lat::Float64, lon::Float64)
    R = 6378137.0
    x = R * π * lon / 180.0
    y = R * log(tan(π/4 + π * lat / 360.0))
    return x, y
end

"""
Load US state boundary shapes for basemap plotting.

Returns a Vector of Plots.Shape objects (one per polygon part) for the requested states.
"""
function load_us_basemap(states::Vector{String})
    base_path = something(pkgdir(GridPlanning), dirname(dirname(@__FILE__)))
    shp_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2018_us_state_500k.shp")
    dbf_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2018_us_state_500k.dbf")

    if !isfile(shp_path)
        @warn "US shapefile not found at $shp_path — basemap will be skipped"
        return Plots.Shape[]
    end

    shp = Shapefile.Handle(shp_path)
    dbf = DBFTables.Table(dbf_path)
    state_df = DataFrame(dbf)
    state_df[!, :SHAPES] = shp.shapes

    plot_shapes = Plots.Shape[]
    for state_name in states
        idx = findfirst(==(state_name), state_df.NAME)
        idx === nothing && continue
        geom = state_df.SHAPES[idx]
        coords = GeoInterface.coordinates(geom)
        # coords structure: Vector{poly} where poly = Vector{ring},
        # ring = Vector{point}, point = Vector{Float64} [lon, lat]
        for poly in coords
            for ring in poly
                # Use only exterior ring (first ring) for each polygon part
                xs = [latlon_to_webmercator(Float64(p[2]), Float64(p[1]))[1] for p in ring]
                ys = [latlon_to_webmercator(Float64(p[2]), Float64(p[1]))[2] for p in ring]
                push!(plot_shapes, Plots.Shape(xs, ys))
                break  # only exterior ring, skip holes
            end
        end
    end
    return plot_shapes
end

"""State name → 2-digit FIPS code. Only includes states used in NETWORK_PLOT_CONFIG."""
const STATE_NAME_TO_FIPS = Dict(
    "Arizona"    => "04",  "California" => "06",  "Colorado"   => "08",
    "Idaho"      => "16",  "Montana"    => "30",  "Nevada"     => "32",
    "New Mexico" => "35",  "Oregon"     => "41",  "Texas"      => "48",
    "Utah"       => "49",  "Washington" => "53",  "Wyoming"    => "56",
)

"""
Load US census tract polygons for the given states.

Reads `data/US_Shapefiles/cb_2023_us_tract_500k.{shp,dbf}` (national file,
~100 MB). Filters to tracts whose STATEFP matches the FIPS of any requested
state. Returns (shapes::Vector{Plots.Shape}, geoids::Vector{String}) — one
entry per polygon part, paired by index. Graceful @warn + empty return if
the shapefile is missing.
"""
function load_census_tracts(states::Vector{String})
    base_path = something(pkgdir(GridPlanning), dirname(dirname(@__FILE__)))
    shp_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2023_us_tract_500k.shp")
    dbf_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2023_us_tract_500k.dbf")

    if !isfile(shp_path)
        zip_path = joinpath(dirname(shp_path), "cb_2023_us_tract_500k.zip")
        @warn "Census tract shapefile not found at $shp_path — overlay will be skipped. " *
              "Download with: curl -L -o $zip_path https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_tract_500k.zip && unzip -o $zip_path -d $(dirname(shp_path))"
        return Plots.Shape[], String[]
    end

    target_fips = Set(get(STATE_NAME_TO_FIPS, s, "") for s in states)
    delete!(target_fips, "")
    isempty(target_fips) && return Plots.Shape[], String[]

    shp = Shapefile.Handle(shp_path)
    dbf = DBFTables.Table(dbf_path)
    df = DataFrame(dbf)
    df[!, :SHAPES] = shp.shapes

    shapes = Plots.Shape[]
    geoids = String[]
    for r in eachrow(df)
        String(r.STATEFP) in target_fips || continue
        geom = r.SHAPES
        geom === nothing && continue
        coords = GeoInterface.coordinates(geom)
        for poly in coords
            for ring in poly
                xs = [latlon_to_webmercator(Float64(p[2]), Float64(p[1]))[1] for p in ring]
                ys = [latlon_to_webmercator(Float64(p[2]), Float64(p[1]))[2] for p in ring]
                push!(shapes, Plots.Shape(xs, ys))
                push!(geoids, String(r.GEOID))
                break  # exterior ring only, skip holes
            end
        end
    end
    return shapes, geoids
end

"""Standard wildfire risk color gradient: low (green) → high (dark red)."""
risk_colormap() = cgrad([:green, :yellow, :orange, :red, :darkred])

"""
Format the date or date range from results for use in plot titles.
Single day: "2021-06-15". Multi-day aggregate: "2021-06-15 to 2021-06-17".
"""
function _title_date_str(results::Dict, day::Union{Nothing,Int})
    times = get(results, :times, nothing)
    (times === nothing || isempty(times)) && return ""
    fmt(t) = @sprintf("%04d-%02d-%02d", t[1], t[2], t[3])
    if day !== nothing
        return day <= length(times) ? fmt(times[day]) : "Day $day"
    end
    length(times) == 1 && return fmt(times[1])
    return "$(fmt(times[1])) to $(fmt(times[end]))"
end

"""Normalize values to [0, 1]. Returns 0.5 for all-same-value inputs."""
function normalize_to_range(values::Vector{Float64})
    lo, hi = minimum(values), maximum(values)
    hi == lo && return fill(0.5, length(values))
    return (values .- lo) ./ (hi - lo)
end

const NETWORK_PLOT_CONFIG = Dict(
    "RTS"     => (states=["California","Nevada","Arizona"],            x_scale=0.05, y_scale=0.05),
    "CATS"    => (states=["California"],                                x_scale=0.05, y_scale=0.05),
    "Texas7k" => (states=["Texas"],                                    x_scale=0.05, y_scale=0.05),
    "Texas2k" => (states=["Texas"],                                    x_scale=0.05, y_scale=0.05),
    "WECC10k" => (states=["California","Nevada","Arizona","Oregon",
                           "Washington","Utah","Idaho","Montana",
                           "Wyoming","Colorado","New Mexico"],         x_scale=0.04, y_scale=0.05),
    "WECC240" => (states=["California","Nevada","Arizona","Oregon",
                           "Washington","Utah","Idaho","Montana",
                           "Wyoming","Colorado","New Mexico"],         x_scale=0.04, y_scale=0.05),
)

function network_plot_config(network_name::String)
    canonical = Dict(
        "RTS_GMLC" => "RTS", "CALIFORNIATESTS" => "CATS", "CALIFORNIATESTSYSTEM" => "CATS",
        "CaliforniaTestSystem" => "CATS",
        "ACTIVSg2000" => "Texas2k", "ACTIVSg10k" => "WECC10k", "pserc240" => "WECC240"
    )
    name = get(canonical, network_name, network_name)
    return get(NETWORK_PLOT_CONFIG, name,
               (states=String[], x_scale=0.05, y_scale=0.05))
end

"""
Translate solve_ots() results into plotting-internal format.

day=nothing: aggregate across all days (sum/any as appropriate)
day=d: use data for day d only
"""
function results_to_plot_dict(results::Dict, day::Union{Nothing,Int}=nothing)
    D = get(results, :D, 1)
    T = get(results, :T, 24)

    pd = Dict{String,Any}()

    # Infrastructure capacities (time-independent)
    pd["buses_w_batts"] = haskey(results, :x) ? results[:x] : Dict{Int,Float64}()
    pd["buses_w_solar"] = haskey(results, :s) ? results[:s] : Dict{Int,Float64}()
    pd["hardened_lines"] = get(results, :hardened_lines, Int[])

    # Switched-off lines
    switched = get(results, :switched_off_lines, Dict{Int,Vector{Int}}())
    if day === nothing
        pd["off_lines"] = Set(l for d in 1:D for l in get(switched, d, Int[]))
    else
        pd["off_lines"] = Set(get(switched, day, Int[]))
    end

    # Load shedding: sum per bus over selected day(s)
    ls_key = haskey(results, :load_shedding) ? :load_shedding : :p_load_shedding
    if haskey(results, ls_key)
        ls = results[ls_key]
        days_to_sum = day === nothing ? (1:D) : (day:day)
        pd["load_shedding"] = Dict{Int,Float64}()
        # Handle DenseAxisArray (JuMP results) — iterate over bus axis directly
        try
            bus_axis = axes(ls)[3]
            for d in days_to_sum, t in 1:T, bus in bus_axis
                val = ls[d, t, bus]
                pd["load_shedding"][bus] = get(pd["load_shedding"], bus, 0.0) + val
            end
        catch
            # Fallback: Dict with (d,t,bus) tuple keys
            for ((d, t, bus), val) in ls
                d in days_to_sum || continue
                pd["load_shedding"][bus] = get(pd["load_shedding"], bus, 0.0) + val
            end
        end
    else
        pd["load_shedding"] = Dict{Int,Float64}()
    end

    return pd
end

"""Load results for plotting from Dict, JLD2 path, or Vector{Dict}."""
function load_results_for_plotting(input)
    if input isa Dict
        return input
    elseif input isa String
        if endswith(input, ".jld2")
            return JLD2.load(input, "results")
        else
            error("Only .jld2 files supported for path-based loading. Got: $input")
        end
    elseif input isa Vector
        return input  # Vector{Dict} for tradeoff curve
    else
        error("results must be a Dict, a path String to .jld2, or a Vector{Dict}")
    end
end

"""
Load wildfire risk data for plotting from disk and aggregate to a flat
Dict{line_id => max_risk_across_days}, including lines with zero risk.

Uses the raw day-level loaders directly to avoid the optimization-layer
filter that strips zero-risk lines (which are still valid for coloring).
Falls back to an empty dict gracefully if data is unavailable.
"""
function load_plot_risk_data(results::Dict)
    network = get(results, :network, "")
    times   = get(results, :times, nothing)
    (isempty(network) || times === nothing) && return Dict{Int,Float64}()

    is_cats = occursin("California", network) || occursin("CATS", network)
    risk_metric = get(results, :risk_metric, "cum_wfpi")

    base_path = dirname(@__DIR__)
    data_dir = get(results, :data_dir, "data")
    wf_dir = joinpath(base_path, data_dir, "USGS_FPI")

    flat = Dict{Int,Float64}()
    try
        if is_cats
            # CATS: use existing loader (already returns all lines in the CSV)
            network_data = load_network(network, data_dir)
            ref = PowerModels.build_ref(network_data)[:it][:pm][:nw][0]
            wf_data = load_wildfire_data(network, collect(times), ref, is_cats, risk_metric, data_dir)
            for (_, day_risks) in wf_data
                for (l, r) in day_risks
                    flat[l] = max(get(flat, l, 0.0), r)
                end
            end
        else
            # Standard networks: use load_standard_wildfire_data (CSV first, JLD2 fallback)
            network_fpi_name = get_network_fpi_name(network)
            network_data = load_network(network, data_dir)
            ref = PowerModels.build_ref(network_data)[:it][:pm][:nw][0]
            wf_data = load_standard_wildfire_data(wf_dir, network_fpi_name, collect(times), ref, risk_metric)
            for (_, day_risks) in wf_data
                for (l, r) in day_risks
                    flat[l] = max(get(flat, l, 0.0), r)
                end
            end
        end
    catch e
        @warn "Could not load wildfire risk data for plotting: $e"
        return Dict{Int,Float64}()
    end
    return flat
end

"""
Build geographic context for network plots.

Returns (p, ref, bus_coords, bus_xy) where:
  p         — initialized Plots figure with basemap
  ref       — PowerModels reference dict (branch topology)
  bus_coords — DataFrame with Bus_ID, lat, lng
  bus_xy    — Dict{Int => (x,y)} in Web Mercator
"""
function build_geo_context(network_name::String, title::String="")
    config = network_plot_config(network_name)
    shapes = load_us_basemap(config.states)

    # Load network topology and bus coordinates first so we can compute extents
    # before creating the plot (avoids xlims!/ylims! mutation which resets top_margin)
    network_data = load_network(network_name)
    ref = PowerModels.build_ref(network_data)[:it][:pm][:nw][0]

    bus_coords = load_bus_coordinates(network_name)

    # Build Web Mercator lookup
    bus_xy = Dict{Int,Tuple{Float64,Float64}}()
    for row in eachrow(bus_coords)
        ismissing(row.Bus_ID) && continue   # blank trailing rows in CSV
        ismissing(row.lat) || ismissing(row.lng) && continue
        x, y = latlon_to_webmercator(Float64(row.lat), Float64(row.lng))
        bus_xy[Int(row.Bus_ID)] = (x, y)
    end

    # Warn and impute coordinates for any network buses missing from the lookup
    coord_bus_ids = Set(keys(bus_xy))
    network_bus_ids = Set(keys(ref[:bus]))
    missing_buses = setdiff(network_bus_ids, coord_bus_ids)
    if !isempty(missing_buses)
        @warn "$(length(missing_buses)) bus(es) have no coordinates — imputing from connected neighbors: $(sort(collect(missing_buses)))"
        neighbors = Dict{Int,Vector{Int}}()
        for (_, branch) in ref[:branch]
            f, t = branch["f_bus"], branch["t_bus"]
            push!(get!(neighbors, f, Int[]), t)
            push!(get!(neighbors, t, Int[]), f)
        end
        remaining = collect(missing_buses)
        max_iters = length(remaining) + 1
        iter = 0
        while !isempty(remaining) && iter < max_iters
            iter += 1
            still_missing = Int[]
            for b in remaining
                known = filter(n -> haskey(bus_xy, n), get(neighbors, b, Int[]))
                if isempty(known)
                    push!(still_missing, b)
                else
                    avg_x = sum(bus_xy[n][1] for n in known) / length(known)
                    avg_y = sum(bus_xy[n][2] for n in known) / length(known)
                    bus_xy[b] = (avg_x, avg_y)
                end
            end
            remaining = still_missing
        end
        if !isempty(remaining)
            @warn "Could not impute coordinates for $(length(remaining)) isolated buses: $remaining — they will be omitted from the plot"
        end
    end

    # Compute bus extents in Web Mercator for canvas sizing and axis limits.
    canvas_w = 900
    x_lims = y_lims = nothing
    title_y = nothing
    if !isempty(bus_xy)
        bus_xs = [v[1] for v in values(bus_xy)]
        bus_ys = [v[2] for v in values(bus_xy)]
        xmin, xmax = minimum(bus_xs), maximum(bus_xs)
        ymin, ymax = minimum(bus_ys), maximum(bus_ys)
        x_margin = (xmax - xmin) * config.x_scale
        y_margin = (ymax - ymin) * config.y_scale
        x_lims = (xmin - x_margin, xmax + x_margin)

        # Fixed title buffer above bus extent.  Shapes that extend beyond
        # ylims are clipped — we intentionally don't chase far-away state
        # boundaries (e.g. northern California when the network is in SoCal).
        title_space = (ymax - ymin) * 0.12
        y_lims = (ymin - y_margin, ymax + y_margin + title_space)
        title_y = ymax + y_margin + title_space * 0.6

        # Canvas height matches data aspect ratio. With aspect_ratio=:equal,
        # GR enforces correct proportions regardless — this just minimizes
        # whitespace around the map.
        x_range = x_lims[2] - x_lims[1]
        y_range = y_lims[2] - y_lims[1]
        canvas_h = max(round(Int, canvas_w * y_range / x_range), 400)
    else
        canvas_h = 700
    end

    # Create plot with aspect_ratio=:equal for correct geographic proportions.
    # All kwargs passed directly at init (not via mutation) to avoid layout resets.
    if x_lims !== nothing
        p = plot(; framestyle=:none, grid=false, legend=:outertopright,
                   size=(canvas_w, canvas_h), aspect_ratio=:equal,
                   xlims=x_lims, ylims=y_lims)
    else
        p = plot(; framestyle=:none, grid=false, legend=:outertopright,
                   size=(canvas_w, canvas_h), aspect_ratio=:equal)
    end

    # Basemap: batch all state boundary shapes into a single NaN-separated path
    map_xs, map_ys = Float64[], Float64[]
    for s in shapes
        append!(map_xs, s.x); push!(map_xs, s.x[1], NaN)
        append!(map_ys, s.y); push!(map_ys, s.y[1], NaN)
    end
    !isempty(map_xs) && plot!(p, map_xs, map_ys;
        seriestype=:path, color=:grey, linewidth=0.25, label=false)

    # Title as data-space annotation (bypasses GR's NDC title placement)
    if !isempty(title) && title_y !== nothing
        x_center = (x_lims[1] + x_lims[2]) / 2
        annotate!(p, x_center, title_y, Plots.text(title, 14, :black, :center))
    end

    return p, ref, bus_coords, bus_xy
end
