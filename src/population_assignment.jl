"""
Assign census-tract populations to transmission buses via the 3-pass radius
algorithm, then aggregate tract demographics to per-bus totals.

Pass 1: r_c ← min_n dist(c, n); mark the closest bus to each tract as assigned.
Pass 2: for each unassigned bus, expand its nearest tract's radius to include
        it, mark the bus as assigned.
Pass 3: for each tract, gather buses within r_c; split tract population
        between them according to the chosen weighting rule.

Weighting modes:
  - :inverse      (default)  a_{cn} = (1/d_{cn}) / Σ(1/d_{ci})
  - :proportional (spec)     a_{cn} =   d_{cn}   / Σ  d_{ci}

Candidate tracts are restricted to those whose centroid lies within
`radius_m` of ANY load bus — union of per-bus disks, not a single enclosing
rectangle. This keeps sparse networks (e.g. WECC240) from pulling ACS data
for every tract in the intervening empty region.

Distances are geodesic (haversine, meters), consistent with
`calculate_line_lengths` in preprocessing.jl.
"""

using Printf

"""
    haversine_m(lat1, lon1, lat2, lon2) -> Float64

Great-circle distance between two (lat, lon) points in meters.
"""
function haversine_m(lat1::Float64, lon1::Float64, lat2::Float64, lon2::Float64)
    R = 6_371_000.0
    φ1 = lat1 * π / 180.0
    φ2 = lat2 * π / 180.0
    Δφ = (lat2 - lat1) * π / 180.0
    Δλ = (lon2 - lon1) * π / 180.0
    a = sin(Δφ/2)^2 + cos(φ1) * cos(φ2) * sin(Δλ/2)^2
    return R * 2 * atan(sqrt(a), sqrt(1 - a))
end

"""
    tract_centroid(ring) -> (lat::Float64, lon::Float64)

Polygon centroid via the shoelace formula. `ring` is a vector of
`[lon, lat]` points (GeoInterface convention). Falls back to the vertex
arithmetic mean for degenerate (|A| < 1e-12) rings.
"""
function tract_centroid(ring)
    n = length(ring)
    n < 3 && return (Float64(ring[1][2]), Float64(ring[1][1]))
    A = 0.0; cx = 0.0; cy = 0.0
    for i in 1:(n-1)
        xi, yi = Float64(ring[i][1]),   Float64(ring[i][2])
        xj, yj = Float64(ring[i+1][1]), Float64(ring[i+1][2])
        cross = xi * yj - xj * yi
        A  += cross
        cx += (xi + xj) * cross
        cy += (yi + yj) * cross
    end
    A *= 0.5
    if abs(A) < 1e-12
        lon = sum(Float64(p[1]) for p in ring) / n
        lat = sum(Float64(p[2]) for p in ring) / n
        return (lat, lon)
    end
    return (cy / (6.0 * A), cx / (6.0 * A))  # (lat, lon)
end

"""
    load_network_tracts_near_buses(network_name; radius_m=25_000.0) -> Vector{NamedTuple}

Load census tracts in the network's state(s) whose centroid is within
`radius_m` of ANY bus in the network. Uses a lat/lon prefilter derived from
the network's overall bbox + margin to avoid a full haversine cross-product.

Returns NamedTuples with `geoid, state_fips, county_fips, tract_fips,
centroid_lat, centroid_lng`. Warns and returns an empty vector if the
shapefile is missing.
"""
function load_network_tracts_near_buses(network_name::String; radius_m::Float64=25_000.0)
    base_path = something(pkgdir(GridPlanning), dirname(dirname(@__FILE__)))
    shp_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2023_us_tract_500k.shp")
    dbf_path = joinpath(base_path, "data", "US_Shapefiles", "cb_2023_us_tract_500k.dbf")

    if !isfile(shp_path)
        zip_path = joinpath(dirname(shp_path), "cb_2023_us_tract_500k.zip")
        @warn "Census tract shapefile not found at $shp_path — cannot build tract set. " *
              "Download with: curl -L -o $zip_path https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_tract_500k.zip && unzip -o $zip_path -d $(dirname(shp_path))"
        return NamedTuple[]
    end

    config = network_plot_config(network_name)
    target_fips = Set(get(STATE_NAME_TO_FIPS, s, "") for s in config.states)
    delete!(target_fips, "")
    isempty(target_fips) && return NamedTuple[]

    bus_coords = load_bus_coordinates(network_name)
    blat = Float64[]; blon = Float64[]
    for row in eachrow(bus_coords)
        (ismissing(row.lat) || ismissing(row.lng)) && continue
        push!(blat, Float64(row.lat)); push!(blon, Float64(row.lng))
    end
    isempty(blat) && return NamedTuple[]

    # Cheap lat/lon bbox prefilter before per-bus haversine check.
    mean_lat = sum(blat) / length(blat)
    margin_lat_deg = radius_m / 111_320.0
    margin_lon_deg = radius_m / (111_320.0 * max(cos(mean_lat * π / 180.0), 0.1))
    lat_min = minimum(blat) - margin_lat_deg
    lat_max = maximum(blat) + margin_lat_deg
    lon_min = minimum(blon) - margin_lon_deg
    lon_max = maximum(blon) + margin_lon_deg

    shp = Shapefile.Handle(shp_path)
    dbf = DBFTables.Table(dbf_path)
    df = DataFrame(dbf); df[!, :SHAPES] = shp.shapes

    out = NamedTuple[]
    for r in eachrow(df)
        String(r.STATEFP) in target_fips || continue
        geom = r.SHAPES
        geom === nothing && continue
        coords = GeoInterface.coordinates(geom)
        ring = coords[1][1]   # first polygon, exterior ring

        c_lat, c_lon = tract_centroid(ring)
        # Coarse bbox cull first
        (c_lat < lat_min || c_lat > lat_max ||
         c_lon < lon_min || c_lon > lon_max) && continue

        # Per-bus radius check: keep if any bus is within radius_m of the centroid
        near = false
        for k in eachindex(blat)
            if haversine_m(c_lat, c_lon, blat[k], blon[k]) ≤ radius_m
                near = true; break
            end
        end
        near || continue

        push!(out, (
            geoid        = String(r.GEOID),
            state_fips   = String(r.STATEFP),
            county_fips  = String(r.COUNTYFP),
            tract_fips   = String(r.TRACTCE),
            centroid_lat = c_lat,
            centroid_lng = c_lon,
        ))
    end
    return out
end

"""
    fetch_tract_demographics(tracts, acs_year, api_key) -> Vector{NamedTuple}

Pull ACS demographics for the tracts returned by
`load_network_tracts_near_buses`. Missing responses produce rows with all
demographic fields = missing but the tract still appears in the output.
"""
function fetch_tract_demographics(tracts, acs_year::Int, api_key::String)
    isempty(tracts) && return NamedTuple[]
    keys_in = [(t.state_fips, t.county_fips, t.tract_fips) for t in tracts]
    raw = fetch_acs_data(keys_in, ACS_VARIABLES, acs_year, api_key)

    out = NamedTuple[]
    for t in tracts
        rec = get(raw, (t.state_fips, t.county_fips, t.tract_fips), nothing)
        push!(out, _assemble_tract_row(t, rec))
    end
    return out
end

function _assemble_tract_row(t, raw::Union{Nothing,Dict})
    if raw === nothing
        return (geoid=t.geoid,
                centroid_lat=t.centroid_lat, centroid_lng=t.centroid_lng,
                total_pop=missing, num_households=missing,
                num_white=missing, num_black=missing, num_native=missing,
                num_asian=missing, num_hispanic=missing,
                num_below_poverty=missing, num_above_poverty=missing,
                num_low_income=missing, num_middle_income=missing, num_high_income=missing,
                median_income=missing)
    end
    total_pop   = _to_float(get(raw, "B01003_001E", nothing))
    white       = _to_float(get(raw, "B02001_002E", nothing))
    black       = _to_float(get(raw, "B02001_003E", nothing))
    native      = _to_float(get(raw, "B02001_004E", nothing))
    asian       = _to_float(get(raw, "B02001_005E", nothing))
    hispanic    = _to_float(get(raw, "B03003_003E", nothing))
    households  = _to_float(get(raw, "B11001_001E", nothing))
    pov_total   = _to_float(get(raw, "B17001_001E", nothing))
    pov_below   = _to_float(get(raw, "B17001_002E", nothing))
    med_inc     = _to_float(get(raw, "B19013_001E", nothing))
    low_inc     = _bracket_sum(raw, B19001_LOW)
    mid_inc     = _bracket_sum(raw, B19001_MIDDLE)
    high_inc    = _bracket_sum(raw, B19001_HIGH)
    above_pov   = (ismissing(pov_total) || ismissing(pov_below)) ? missing : (pov_total - pov_below)

    return (geoid=t.geoid,
            centroid_lat=t.centroid_lat, centroid_lng=t.centroid_lng,
            total_pop=total_pop, num_households=households,
            num_white=white, num_black=black, num_native=native,
            num_asian=asian, num_hispanic=hispanic,
            num_below_poverty=pov_below, num_above_poverty=above_pov,
            num_low_income=low_inc, num_middle_income=mid_inc, num_high_income=high_inc,
            median_income=med_inc)
end

"""
    load_buses_with_load(network_name; data_dir="data") -> Vector{Int}

Return bus IDs whose active load (sum of ref[:load][j]["pd"] across their
connected loads) is strictly positive.
"""
function load_buses_with_load(network_name::String; data_dir::String="data")
    network_data = load_network(network_name, data_dir)
    ref = PowerModels.build_ref(network_data)[:it][:pm][:nw][0]
    out = Int[]
    for (b, load_ids) in ref[:bus_loads]
        pd_sum = reduce(+, ref[:load][j]["pd"] for j in load_ids; init=0.0)
        pd_sum > 0 && push!(out, b)
    end
    return sort(out)
end

"""
    assign_population(tracts, buses; weighting=:inverse) -> Vector{NamedTuple}

Run the 3-pass radius assignment. `tracts` is an iterable of NamedTuples
with at least `geoid, centroid_lat, centroid_lng, total_pop`. `buses` is
an iterable of NamedTuples with at least `bus_id, lat, lng`.

Returns one NamedTuple per (tract, bus) pair with non-zero weight:
`(tract_geoid, bus_id, weight, distance_m, assigned_population)`.
"""
function assign_population(tracts, buses; weighting::Symbol=:inverse)
    weighting in (:inverse, :proportional) ||
        error("weighting must be :inverse or :proportional, got :$weighting")

    tlat = [Float64(t.centroid_lat) for t in tracts]
    tlon = [Float64(t.centroid_lng) for t in tracts]
    geoid = [String(t.geoid) for t in tracts]
    tpop  = [ismissing(t.total_pop) ? 0.0 : Float64(t.total_pop) for t in tracts]

    blat = [Float64(b.lat) for b in buses]
    blon = [Float64(b.lng) for b in buses]
    bid  = [Int(b.bus_id)  for b in buses]

    nT = length(tlat); nB = length(blat)
    (nT == 0 || nB == 0) && return NamedTuple[]

    # Pass 1: per-tract radius = min distance to any bus
    radii = fill(Inf, nT)
    assigned_bus = falses(nB)
    for i in 1:nT
        best_d = Inf; best_j = 0
        for j in 1:nB
            d = haversine_m(tlat[i], tlon[i], blat[j], blon[j])
            if d < best_d
                best_d = d; best_j = j
            end
        end
        radii[i] = best_d
        best_j > 0 && (assigned_bus[best_j] = true)
    end

    # Pass 2: each unassigned bus expands its nearest tract's radius
    for j in 1:nB
        assigned_bus[j] && continue
        best_d = Inf; best_i = 0
        for i in 1:nT
            d = haversine_m(tlat[i], tlon[i], blat[j], blon[j])
            if d < best_d
                best_d = d; best_i = i
            end
        end
        if best_i > 0
            radii[best_i] = max(radii[best_i], best_d)
            assigned_bus[j] = true
        end
    end

    # Pass 3: for each tract, split population across buses within r_c
    out = NamedTuple[]
    for i in 1:nT
        r = radii[i]
        cand_j = Int[]; cand_d = Float64[]
        for j in 1:nB
            d = haversine_m(tlat[i], tlon[i], blat[j], blon[j])
            if d <= r
                push!(cand_j, j); push!(cand_d, d)
            end
        end
        isempty(cand_j) && continue

        weights = _compute_weights(cand_d, weighting)
        for (k, j) in enumerate(cand_j)
            push!(out, (tract_geoid=geoid[i],
                        bus_id=bid[j],
                        weight=weights[k],
                        distance_m=cand_d[k],
                        assigned_population=weights[k] * tpop[i]))
        end
    end
    return out
end

function _compute_weights(distances::Vector{Float64}, mode::Symbol)
    n = length(distances)
    if mode == :inverse
        # Co-located bus (d ≈ 0) dominates: hand it full weight.
        zero_idx = findall(d -> d < 1e-9, distances)
        if !isempty(zero_idx)
            w = zeros(n)
            for k in zero_idx
                w[k] = 1.0 / length(zero_idx)
            end
            return w
        end
        inv = 1.0 ./ distances
        return inv ./ sum(inv)
    else  # :proportional
        total = sum(distances)
        return total > 0 ? distances ./ total : fill(1.0 / n, n)
    end
end

"""
    aggregate_tract_to_bus(tract_rows, assignment_rows) -> Vector{NamedTuple}

Aggregate tract-level demographic counts to per-bus totals using the
`weight` column from `assignment_rows`. `median_income` is
population-weighted across assigned tracts. Returns one NamedTuple per bus
that appears in `assignment_rows`.
"""
function aggregate_tract_to_bus(tract_rows, assignment_rows)
    tract_by_geoid = Dict{String, NamedTuple}()
    for t in tract_rows
        tract_by_geoid[String(t.geoid)] = t
    end

    count_fields = (:total_pop, :num_households, :num_white, :num_black, :num_native,
                    :num_asian, :num_hispanic, :num_below_poverty, :num_above_poverty,
                    :num_low_income, :num_middle_income, :num_high_income)

    per_bus = Dict{Int, Dict{Symbol, Float64}}()
    # Weighted numerator/denominator for median_income (by weight × total_pop)
    med_num = Dict{Int, Float64}()
    med_den = Dict{Int, Float64}()

    for a in assignment_rows
        t = get(tract_by_geoid, String(a.tract_geoid), nothing)
        t === nothing && continue
        bus = Int(a.bus_id)
        w   = Float64(a.weight)
        accum = get!(per_bus, bus, Dict{Symbol, Float64}())
        for f in count_fields
            v = getproperty(t, f)
            ismissing(v) && continue
            accum[f] = get(accum, f, 0.0) + w * Float64(v)
        end
        if !ismissing(t.median_income) && !ismissing(t.total_pop)
            weight_pop = w * Float64(t.total_pop)
            med_num[bus] = get(med_num, bus, 0.0) + weight_pop * Float64(t.median_income)
            med_den[bus] = get(med_den, bus, 0.0) + weight_pop
        end
    end

    out = NamedTuple[]
    for bus in sort(collect(keys(per_bus)))
        acc = per_bus[bus]
        med = get(med_den, bus, 0.0) > 0 ? med_num[bus] / med_den[bus] : missing
        push!(out, (
            Bus_ID            = bus,
            total_pop         = get(acc, :total_pop, 0.0),
            num_households    = get(acc, :num_households, 0.0),
            num_white         = get(acc, :num_white, 0.0),
            num_black         = get(acc, :num_black, 0.0),
            num_native        = get(acc, :num_native, 0.0),
            num_asian         = get(acc, :num_asian, 0.0),
            num_hispanic      = get(acc, :num_hispanic, 0.0),
            num_below_poverty = get(acc, :num_below_poverty, 0.0),
            num_above_poverty = get(acc, :num_above_poverty, 0.0),
            num_low_income    = get(acc, :num_low_income, 0.0),
            num_middle_income = get(acc, :num_middle_income, 0.0),
            num_high_income   = get(acc, :num_high_income, 0.0),
            median_income     = med,
        ))
    end
    return out
end

"""
    save_census_csv(path, rows)

Write the unified per-bus census CSV. `rows` is the output of
`aggregate_tract_to_bus`.
"""
function save_census_csv(path::String, rows)
    mkpath(dirname(path))
    open(path, "w") do io
        println(io, "Bus_ID,total_pop,num_households,num_white,num_black,num_native,num_asian," *
                    "num_hispanic,num_below_poverty,num_above_poverty," *
                    "num_low_income,num_middle_income,num_high_income,median_income")
        for r in rows
            @printf(io, "%d,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n",
                r.Bus_ID,
                _fmt(r.total_pop), _fmt(r.num_households),
                _fmt(r.num_white), _fmt(r.num_black), _fmt(r.num_native),
                _fmt(r.num_asian), _fmt(r.num_hispanic),
                _fmt(r.num_below_poverty), _fmt(r.num_above_poverty),
                _fmt(r.num_low_income), _fmt(r.num_middle_income), _fmt(r.num_high_income),
                _fmt(r.median_income))
        end
    end
end

"""
    get_network_census(network_name; kwargs...) -> String

End-to-end entry point. Pulls tract demographics within `radius_m` of any
bus in the network, runs the 3-pass assignment against load buses,
aggregates to per-bus totals, and writes a single CSV to
`<data_dir>/census_data/<network_name>_census_<acs_year>.csv`. Returns the
output path.

# Keyword arguments
- `api_key::String=""`       — Census API key (or `CENSUS_API_KEY` env var;
                                anonymous fallback ~500 req/day)
- `acs_year::Int=2022`
- `radius_m::Float64=25_000.0` — per-bus tract-inclusion radius (meters)
- `weighting::Symbol=:inverse` — `:inverse` (default) or `:proportional`
- `data_dir::String="data"`
- `output_path::String=""`   — override the default output location
"""
function get_network_census(network_name::String;
                            api_key::String="",
                            acs_year::Int=2022,
                            radius_m::Float64=25_000.0,
                            weighting::Symbol=:inverse,
                            data_dir::String="data",
                            output_path::String="")
    if isempty(api_key)
        api_key = get(ENV, "CENSUS_API_KEY", "")
        isempty(api_key) && @warn "No CENSUS_API_KEY set — using anonymous ACS (~500 req/day)"
    end

    base_path = something(pkgdir(GridPlanning), dirname(dirname(@__FILE__)))
    if isempty(output_path)
        output_path = joinpath(base_path, data_dir, "census_data",
                               "$(network_name)_census_$(acs_year).csv")
    end
    mkpath(dirname(output_path))

    println("Loading tracts within $(radius_m/1000) km of any $network_name bus...")
    tracts = load_network_tracts_near_buses(network_name; radius_m=radius_m)
    println("  $(length(tracts)) tracts in region")
    if isempty(tracts)
        @warn "No tracts found — aborting"
        return output_path
    end

    println("Fetching ACS $(acs_year) demographics...")
    tract_rows = fetch_tract_demographics(tracts, acs_year, api_key)

    load_bus_ids = Set(load_buses_with_load(network_name; data_dir=data_dir))
    bus_coords = load_bus_coordinates(network_name)
    buses = NamedTuple[]
    for row in eachrow(bus_coords)
        ismissing(row.Bus_ID) && continue
        b = Int(row.Bus_ID)
        b in load_bus_ids || continue
        (ismissing(row.lat) || ismissing(row.lng)) && continue
        push!(buses, (bus_id=b, lat=Float64(row.lat), lng=Float64(row.lng)))
    end
    println("  $(length(buses)) load buses with coordinates")

    populated = [r for r in tract_rows if !ismissing(r.total_pop) && r.total_pop > 0]
    println("  $(length(populated)) populated tracts")

    println("Running 3-pass assignment (weighting=$weighting)...")
    assignments = assign_population(populated, buses; weighting=weighting)
    println("  $(length(assignments)) (tract, bus) pairs")

    println("Aggregating to per-bus totals...")
    bus_rows = aggregate_tract_to_bus(populated, assignments)
    println("  $(length(bus_rows)) buses with demographics")

    save_census_csv(output_path, bus_rows)
    println("Saved → $output_path")
    return output_path
end
