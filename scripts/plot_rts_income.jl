#!/usr/bin/env julia
# Render the RTS network with:
#   • census tract outlines (no fill), clipped to the bus bbox
#   • branches (steel blue)
#   • buses color-coded by median household income (from the unified
#     per-bus census CSV produced by scripts/generate_census_data.jl)

using Pkg
Pkg.activate(dirname(@__DIR__))

using GridPlanning
using DataFrames
using CSV
using Plots
using Statistics

const NET      = "RTS"
const DATA_DIR = "test_data"
const ACS_YEAR = 2022
const OUT_PATH = joinpath(dirname(@__DIR__), "figures", "RTS_income_map.png")

# ── Load unified per-bus census CSV ─────────────────────────────────────────
df = load_census_data(NET; acs_year=ACS_YEAR, data_dir=DATA_DIR)
@assert !isempty(df) "No census data at $(DATA_DIR)/census_data/$(NET)_census_$(ACS_YEAR).csv"

income_by_bus = Dict{Int,Float64}()
for r in eachrow(df)
    ismissing(r.median_income) && continue
    income_by_bus[Int(r.Bus_ID)] = Float64(r.median_income)
end
println("Buses with computed income: $(length(income_by_bus))")
if !isempty(income_by_bus)
    vals = collect(values(income_by_bus))
    println("  Income range: \$$(round(Int, minimum(vals))) – \$$(round(Int, maximum(vals))), median \$$(round(Int, median(vals)))")
end

# ── Base plot, branches, tract outlines ─────────────────────────────────────
p, ref, bus_coords, bus_xy = GridPlanning.build_geo_context(NET, "RTS — Median Household Income by Bus")

config = GridPlanning.network_plot_config(NET)
shapes, geoids = GridPlanning.load_census_tracts(collect(config.states))

# Restrict outlines to the exact tract set the CSV was generated from
# (per-bus 25 km centroid filter, matching get_network_census).
used_tracts = GridPlanning.load_network_tracts_near_buses(NET; radius_m=25_000.0)
used_geoids = Set(String(t.geoid) for t in used_tracts)

ox, oy = Float64[], Float64[]
for (shp, gid) in zip(shapes, geoids)
    gid in used_geoids || continue
    append!(ox, shp.x); push!(ox, shp.x[1], NaN)
    append!(oy, shp.y); push!(oy, shp.y[1], NaN)
end
if !isempty(ox)
    plot!(p, ox, oy; seriestype=:path, linecolor=:grey70, linewidth=0.3, label=false)
end

# ── Branches ────────────────────────────────────────────────────────────────
bx, by = Float64[], Float64[]
for (_, branch) in ref[:branch]
    f, t = branch["f_bus"], branch["t_bus"]
    (haskey(bus_xy, f) && haskey(bus_xy, t)) || continue
    x1, y1 = bus_xy[f]; x2, y2 = bus_xy[t]
    push!(bx, x1, x2, NaN); push!(by, y1, y2, NaN)
end
plot!(p, bx, by; seriestype=:path, linecolor=:steelblue, linewidth=0.9, label=false)

# ── Buses colored by income (buses w/o data drawn as hollow markers) ───────
xs_inc, ys_inc, vs = Float64[], Float64[], Float64[]
xs_none, ys_none   = Float64[], Float64[]
for row in eachrow(bus_coords)
    ismissing(row.Bus_ID) && continue
    b = Int(row.Bus_ID)
    haskey(bus_xy, b) || continue
    x, y = bus_xy[b]
    if haskey(income_by_bus, b)
        push!(xs_inc, x); push!(ys_inc, y); push!(vs, income_by_bus[b])
    else
        push!(xs_none, x); push!(ys_none, y)
    end
end

if !isempty(xs_none)
    scatter!(p, xs_none, ys_none; label="No income data",
             color=:white, markerstrokecolor=:black, markerstrokewidth=0.6,
             markersize=4)
end
if !isempty(xs_inc)
    lo, hi = minimum(vs), maximum(vs)
    scatter!(p, xs_inc, ys_inc; label=false,
             marker_z=vs, clims=(lo, hi), seriescolor=cgrad(:viridis),
             markersize=6, markerstrokecolor=:black, markerstrokewidth=0.5,
             colorbar=true, colorbar_title="Median Household Income (\$)")
end

mkpath(dirname(OUT_PATH))
savefig(p, OUT_PATH)
println("Saved → $OUT_PATH")
