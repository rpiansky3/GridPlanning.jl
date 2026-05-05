# Plotting entry point — plot_results dispatch and file naming
# Requires: Plots, src/plotting_helpers.jl

# Features that require battery results
const BATTERY_FEATURES = Set([:battery_dispatch])
# Features that require solar results
const SOLAR_FEATURES = Set([:solar_generation])
# Features that require infrastructure (hardening/battery/solar)
const INFRA_FEATURES = Set([:cost_breakdown])
# Features that require geographic data
const GEO_FEATURES = Set([:network_overview])
# All valid features
const ALL_FEATURES = Set([:network_overview,
                           :load_shed_timeseries, :battery_dispatch,
                           :solar_generation, :generation_dispatch,
                           :tradeoff_curve, :cost_breakdown])

function validate_features(results::Dict, features::Vector{Symbol})
    valid = Symbol[]
    for f in features
        if f ∉ ALL_FEATURES
            @warn "Unknown feature :$f — skipping. Valid features: $(join(sort(string.(collect(ALL_FEATURES))), ", "))"
            continue
        end
        if f in BATTERY_FEATURES && !haskey(results, :batteries_installed)
            @warn ":$f requested but battery not enabled in this run — skipping"
            continue
        end
        if f in SOLAR_FEATURES && !haskey(results, :solar_installed)
            @warn ":$f requested but solar not enabled in this run — skipping"
            continue
        end
        if f in INFRA_FEATURES
            has_infra = haskey(results, :batteries_installed) ||
                        haskey(results, :solar_installed) ||
                        haskey(results, :hardened_lines)
            if !has_infra
                @warn ":$f requested but no infrastructure (battery/solar/hardening) in this run — skipping"
                continue
            end
        end
        push!(valid, f)
    end
    return valid
end

function plot_filename(feature::Symbol, results::Dict, day::Union{Nothing,Int}, format::String)
    network = get(results, :network, "network")
    times = get(results, :times, nothing)
    date_str = if day !== nothing && times !== nothing && day <= length(times)
        t = times[day]
        @sprintf("%04d-%02d-%02d", t[1], t[2], t[3])
    elseif times !== nothing && length(times) > 0
        t = times[1]
        D = get(results, :D, 1)
        D == 1 ? @sprintf("%04d-%02d-%02d", t[1], t[2], t[3]) : "aggregate"
    else
        "result"
    end
    return "$(feature)_$(network)_$(date_str).$(format)"
end

"""
    plot_results(results, features; format="pdf", output_dir=".", plot_dir="", day=nothing, infrastructure_off=false, ls_off=false, kwargs...)

Generate publication-quality plots from solve_ots() results.

# Arguments
- `results`: Dict from solve_ots(), String path to .jld2 file, or Vector{Dict} for :tradeoff_curve
- `features`: Vector of Symbols — which plots to generate (see documentation for full list)
- `format`: Output format — "png", "pdf", "svg", "eps" (default: "pdf")
- `output_dir`: Directory to save output files (default: current directory)
- `plot_dir`: Alternative to `output_dir` — if non-empty, takes precedence (default: "")
- `day`: For geographic plots — nothing=aggregate view, Int=specific day (default: nothing)
- `infrastructure_off`: For :network_overview — hide infrastructure layer (batteries, solar, hardened lines) (default: false)
- `ls_off`: For :network_overview — hide load shed bubble layer (default: false)
- `kwargs...`: Passed through to underlying renderers (dpi, size, fontsize, etc.)

# Feature Symbols
- `:network_overview` — All layers combined (branches, buses, infrastructure, load shed)
- `:load_shed_timeseries` — Hourly load shedding bar chart (T1)
- `:battery_dispatch` — SOC and charge/discharge profiles (T2)
- `:solar_generation` — Hourly solar generation (T3)
- `:generation_dispatch` — Total generation over time (T4)
- `:tradeoff_curve` — Risk vs. load shed Pareto curve (S1); requires Vector{Dict} input
- `:cost_breakdown` — Infrastructure cost bar chart (S2)
"""
function plot_results(results_input, features::Vector{Symbol};
                      format::String="pdf",
                      output_dir::String=".",
                      plot_dir::String="",
                      day::Union{Nothing,Int}=nothing,
                      infrastructure_off::Bool=false,
                      ls_off::Bool=false,
                      census_overlay::Union{Nothing,Symbol}=nothing,
                      kwargs...)
    # plot_dir takes precedence over output_dir if provided
    output_dir = isempty(plot_dir) ? output_dir : plot_dir
    # Handle tradeoff curve separately (needs Vector input)
    if :tradeoff_curve in features
        results_vec = results_input isa Vector ? results_input :
                      error(":tradeoff_curve requires results to be a Vector{Dict}")
        fname = joinpath(output_dir, "tradeoff_curve.$(format)")
        mkpath(output_dir)
        p = _plot_tradeoff_curve(results_vec; kwargs...)
        Plots.closeall()
        savefig(p, fname)
        println("✓ Saved: $fname")
        features = filter(!=((:tradeoff_curve)), features)
        isempty(features) && return
    end

    results = load_results_for_plotting(results_input)
    valid_features = validate_features(results, features)
    isempty(valid_features) && return
    mkpath(output_dir)

    for feature in valid_features
        fname = joinpath(output_dir, plot_filename(feature, results, day, format))
        p = if feature == :network_overview
            _plot_network_overview(results; day=day, infrastructure_off=infrastructure_off,
                                   ls_off=ls_off, census_overlay=census_overlay)
        elseif feature == :load_shed_timeseries
            _plot_load_shed_timeseries(results; kwargs...)
        elseif feature == :battery_dispatch
            _plot_battery_dispatch(results; kwargs...)
        elseif feature == :solar_generation
            _plot_solar_generation(results; kwargs...)
        elseif feature == :generation_dispatch
            _plot_generation_dispatch(results; kwargs...)
        elseif feature == :cost_breakdown
            _plot_cost_breakdown(results; kwargs...)
        end
        Plots.closeall()
        savefig(p, fname)
        println("✓ Saved: $fname")
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# Geographic network plot renderers
# ─────────────────────────────────────────────────────────────────────────────

"""
Draw all branches. Returns NamedTuple with legend flags and color scale (lo, hi, cmap)
for optional colorbar attachment by the caller.

hardening_label: legend label for hardened lines (e.g. "Undergrounded")
"""
function _draw_branches!(p, ref, bus_xy, risk_flat, pd; hardening_label="Undergrounded")
    risky_ids = Set(keys(risk_flat))

    cmap = risk_colormap()
    risky_vals = isempty(risk_flat) ? Float64[] : collect(values(risk_flat))
    lo = isempty(risky_vals) ? 0.0 : minimum(risky_vals)
    hi = isempty(risky_vals) ? 1.0 : maximum(risky_vals)

    hardened_set = Set(pd["hardened_lines"])

    # Collect branch coordinates by category (NaN-separated segments)
    normal_xs, normal_ys = Float64[], Float64[]
    off_xs, off_ys = Float64[], Float64[]
    risky_xs, risky_ys, risky_zs = Float64[], Float64[], Float64[]
    hard_xs, hard_ys = Float64[], Float64[]

    for (l, branch) in ref[:branch]
        f_bus, t_bus = branch["f_bus"], branch["t_bus"]
        (haskey(bus_xy, f_bus) && haskey(bus_xy, t_bus)) || continue
        x1, y1 = bus_xy[f_bus]
        x2, y2 = bus_xy[t_bus]

        if l in hardened_set
            push!(hard_xs, x1, x2, NaN)
            push!(hard_ys, y1, y2, NaN)
        elseif l in pd["off_lines"]
            push!(off_xs, x1, x2, NaN)
            push!(off_ys, y1, y2, NaN)
        elseif l in risky_ids
            push!(risky_xs, x1, x2, NaN)
            push!(risky_ys, y1, y2, NaN)
            push!(risky_zs, risk_flat[l], risk_flat[l], NaN)
        else
            push!(normal_xs, x1, x2, NaN)
            push!(normal_ys, y1, y2, NaN)
        end
    end

    # One plot! call per category (reduces GR series from O(branches) to 4)
    !isempty(normal_xs) && plot!(p, normal_xs, normal_ys;
        color=:black, linewidth=0.4, label=false)
    !isempty(risky_xs) && plot!(p, risky_xs, risky_ys;
        line_z=risky_zs, seriescolor=cmap, linewidth=2.0, label=false, colorbar=false)
    !isempty(off_xs) && plot!(p, off_xs, off_ys;
        color=:grey, linewidth=0.5, linestyle=:dash, label="De-energized")
    !isempty(hard_xs) && plot!(p, hard_xs, hard_ys;
        color=:steelblue, linewidth=10.0, label=hardening_label)

    return (hardened=!isempty(hard_xs), off=!isempty(off_xs), lo=lo, hi=hi, cmap=cmap)
end

"""
If risk_scale=true, attach a colorbar to the plot showing the risk→color mapping.
Requires the lo/hi/cmap returned by _draw_branches!.
"""
function _add_risk_colorbar!(p, lo, hi, cmap)
    scatter!(p, [NaN], [NaN];
             marker_z=[lo], clims=(lo, hi),
             seriescolor=cmap, colorbar=true,
             colorbar_title="Wildfire Risk",
             markersize=0, markerstrokewidth=0, label=false)
end

"""
Color each bus by a demographic metric from the unified per-bus census CSV.

Supported `metric` values (computed from the absolute counts in the CSV):
  - `:median_income`  — raw column value
  - `:pct_poverty`    — num_below_poverty / (num_below_poverty + num_above_poverty)
  - `:pct_nonwhite`   — 1 − num_white / total_pop

Buses without census data are skipped silently.
"""
function _draw_census_overlay!(p, results::Dict, bus_xy::Dict, metric::Symbol)
    network  = get(results, :network, "")
    data_dir = get(results, :data_dir, "data")
    acs_year = get(results, :acs_year, 2022)

    census_df = load_census_data(network; acs_year=acs_year, data_dir=data_dir)
    if isempty(census_df)
        @warn "Census overlay requested but no census CSV found for $network — skipping overlay."
        return
    end

    value_of = if metric == :median_income
        r -> ismissing(r.median_income) ? missing : Float64(r.median_income)
    elseif metric == :pct_poverty
        r -> begin
            denom = Float64(r.num_below_poverty) + Float64(r.num_above_poverty)
            denom > 0 ? Float64(r.num_below_poverty) / denom : missing
        end
    elseif metric == :pct_nonwhite
        r -> begin
            pop = Float64(r.total_pop)
            pop > 0 ? 1.0 - Float64(r.num_white) / pop : missing
        end
    else
        @warn "Unknown census_overlay metric :$metric — skipping overlay."
        return
    end

    xs, ys, vs = Float64[], Float64[], Float64[]
    for r in eachrow(census_df)
        b = Int(r.Bus_ID)
        haskey(bus_xy, b) || continue
        v = value_of(r)
        ismissing(v) && continue
        x, y = bus_xy[b]
        push!(xs, x); push!(ys, y); push!(vs, v)
    end
    isempty(xs) && return

    lo, hi = minimum(vs), maximum(vs)
    cmap = metric == :median_income ? cgrad(:viridis) : cgrad([:white, :darkred])
    label = metric == :median_income ? "Median Income (\$)" :
            metric == :pct_poverty   ? "% Poverty" :
            metric == :pct_nonwhite  ? "% Non-white" : String(metric)

    scatter!(p, xs, ys; label=false, marker_z=vs, clims=(lo, hi),
             seriescolor=cmap, colorbar=true, colorbar_title=label,
             markersize=6, markerstrokecolor=:black, markerstrokewidth=0.5)
end

"""Scatter all buses as small black dots (no legend entry)."""
function _draw_buses!(p, bus_coords, bus_xy)
    ms = nrow(bus_coords) > 3000 ? 1.0 : 2.5
    xs, ys = Float64[], Float64[]
    for row in eachrow(bus_coords)
        haskey(bus_xy, row.Bus_ID) || continue
        x, y = bus_xy[row.Bus_ID]
        push!(xs, x); push!(ys, y)
    end
    !isempty(xs) && scatter!(p, xs, ys; label=false, color=:black,
        markershape=:circle, markersize=ms, markerstrokewidth=0)
end

function _plot_network_overview(results::Dict;
                                day::Union{Nothing,Int}=nothing,
                                risk_scale=false,
                                infrastructure_off::Bool=false,
                                ls_off::Bool=false,
                                census_overlay::Union{Nothing,Symbol}=nothing,
                                kwargs...)
    network = get(results, :network, "RTS")
    p, ref, bus_coords, bus_xy = build_geo_context(network, "$network $(_title_date_str(results, day))")
    risk_per_line = load_plot_risk_data(results)
    pd = results_to_plot_dict(results, day)
    pd_infra = results_to_plot_dict(results, nothing)
    hlabel = get(results, :hardening_type, "Undergrounded")

    # Layer 0 (optional): per-bus census overlay (drawn under load-shed/infrastructure)
    census_overlay !== nothing && _draw_census_overlay!(p, results, bus_xy, census_overlay)

    # Layer 1: branches (risk-colored, de-energized, hardened)
    branch_info = _draw_branches!(p, ref, bus_xy, risk_per_line, pd; hardening_label=hlabel)

    # Layer 2: bus dots (drawn first so markers overlay them)
    _draw_buses!(p, bus_coords, bus_xy)

    # Layer 3: load shed bubbles
    shed = pd["load_shedding"]
    shed_vals = [v for v in values(shed) if v > 1e-4]
    max_shed = isempty(shed_vals) ? 1.0 : maximum(shed_vals)
    min_shed = isempty(shed_vals) ? 0.0 : minimum(shed_vals)
    range_shed = max_shed > min_shed ? max_shed - min_shed : 1.0

    if !ls_off
        saw_shed = false
        for row in eachrow(bus_coords)
            i = row.Bus_ID
            haskey(bus_xy, i) || continue
            s = get(shed, i, 0.0)
            s > 1e-4 || continue
            x, y = bus_xy[i]
            sz = (s - min_shed) * (10.0 / range_shed) + 5.0
            lbl = saw_shed ? false : "Load shedding"
            saw_shed = true
            scatter!(p, [x], [y]; label=lbl, color=:red,
                     marker=(:circle, sz, 0.3, Plots.stroke(2, :red)))
        end
    end

    # Layer 4: infrastructure markers (on top of everything)
    if !infrastructure_off
        batt_caps = [v for v in values(pd_infra["buses_w_batts"]) if v > 0]
        solar_caps = [v for v in values(pd_infra["buses_w_solar"]) if v > 0]

        saw_batt = false
        saw_solar = false
        for row in eachrow(bus_coords)
            i = row.Bus_ID
            haskey(bus_xy, i) || continue
            x, y = bus_xy[i]

            if haskey(pd_infra["buses_w_batts"], i) && pd_infra["buses_w_batts"][i] > 0
                cap = pd_infra["buses_w_batts"][i]
                lo, hi = isempty(batt_caps) ? (0.0,1.0) : (minimum(batt_caps), maximum(batt_caps))
                sz = hi == lo ? 8.0 : 5.0 + 10.0 * (cap - lo) / (hi - lo)
                lbl = saw_batt ? false : "Battery"
                saw_batt = true
                scatter!(p, [x], [y]; label=lbl, color=:grey,
                         marker=(:hex, sz, 0.5, Plots.stroke(1.5, :grey)))
            end

            if haskey(pd_infra["buses_w_solar"], i) && pd_infra["buses_w_solar"][i] > 0
                cap = pd_infra["buses_w_solar"][i]
                lo, hi = isempty(solar_caps) ? (0.0,1.0) : (minimum(solar_caps), maximum(solar_caps))
                sz = hi == lo ? 8.0 : 5.0 + 10.0 * (cap - lo) / (hi - lo)
                lbl = saw_solar ? false : "Solar"
                saw_solar = true
                scatter!(p, [x], [y]; label=lbl, color=:gold,
                         marker=(:diamond, sz, 0.5, Plots.stroke(1.5, :goldenrod)))
            end
        end
    end

    risk_scale && _add_risk_colorbar!(p, branch_info.lo, branch_info.hi, branch_info.cmap)
    return p
end

# ─────────────────────────────────────────────────────────────────────────────
# Time series and summary plot renderers
# ─────────────────────────────────────────────────────────────────────────────

function _plot_load_shed_timeseries(results::Dict; kwargs...)
    D = get(results, :D, 1)
    T = get(results, :T, 24)
    network = get(results, :network, "network")

    ls_key = haskey(results, :load_shedding) ? :load_shedding : :p_load_shedding
    ls = results[ls_key]

    hours = 1:(D*T)
    totals = Float64[]
    try
        bus_axis = axes(ls)[3]
        for d in 1:D, t in 1:T
            push!(totals, sum(ls[d, t, bus] for bus in bus_axis))
        end
    catch
        # Fallback for Dict-keyed results
        for d in 1:D, t in 1:T
            push!(totals, sum(v for ((dd,tt,_), v) in ls if dd==d && tt==t; init=0.0))
        end
    end

    p = bar(hours, totals;
            xlabel="Hour", ylabel="Load Shed (p.u.)",
            title="Load Shedding Over Time — $network",
            color=:tomato, legend=false, grid=true)

    for d in 1:(D-1)
        vline!(p, [d*T + 0.5]; color=:black, linewidth=0.5, linestyle=:dash, label=false)
    end

    return p
end

function _plot_battery_dispatch(results::Dict; bus=nothing, kwargs...)
    D = get(results, :D, 1)
    T = get(results, :T, 24)
    network = get(results, :network, "network")

    batt_buses = get(results, :batteries_installed, Int[])
    isempty(batt_buses) && return plot(title="No batteries installed")

    target_buses = bus === nothing ? batt_buses : [bus]
    hours = 0:(D*T)

    p = plot(; xlabel="Hour", title="Battery Dispatch — $network",
               legend=:outerright, grid=true)

    soc_data = get(results, :soc, Dict())
    for b in target_buses
        soc_vals = Float64[]
        for d in 1:D, t in 0:T
            push!(soc_vals, get(soc_data, (d, t, b), 0.0))
        end
        plot!(p, hours, soc_vals; label="SOC Bus $b", linewidth=1.5)
    end

    for d in 1:(D-1)
        vline!(p, [d*T]; color=:black, linewidth=0.5, linestyle=:dash, label=false)
    end

    yaxis!(p, "SOC / Charge / Discharge (p.u.)")
    return p
end

function _plot_solar_generation(results::Dict; bus=nothing, kwargs...)
    D = get(results, :D, 1)
    T = get(results, :T, 24)
    network = get(results, :network, "network")

    solar_buses = get(results, :solar_installed, Int[])
    isempty(solar_buses) && return plot(title="No solar installed")

    target_buses = bus === nothing ? solar_buses : [bus]
    hours = 1:(D*T)

    p = plot(; xlabel="Hour", ylabel="Generation (p.u.)",
               title="Solar Generation — $network", grid=true, legend=:outerright)

    p_solar_data = get(results, :p_solar, Dict())
    q_solar_data = get(results, :q_solar, nothing)

    for b in target_buses
        p_vals = [get(p_solar_data, (d, t, b), 0.0) for d in 1:D for t in 1:T]
        bar!(p, hours, p_vals; label="P Bus $b", alpha=0.6)
        if q_solar_data !== nothing
            q_vals = [get(q_solar_data, (d, t, b), 0.0) for d in 1:D for t in 1:T]
            plot!(p, hours, q_vals; label="Q Bus $b", linewidth=1.5, linestyle=:dash)
        end
    end

    for d in 1:(D-1)
        vline!(p, [d*T + 0.5]; color=:black, linewidth=0.5, linestyle=:dash, label=false)
    end
    return p
end

function _plot_generation_dispatch(results::Dict; kwargs...)
    D = get(results, :D, 1)
    T = get(results, :T, 24)
    network = get(results, :network, "network")

    gen_key = haskey(results, :g) ? :g : :pg
    hours = 1:(D*T)

    p = plot(; xlabel="Hour", ylabel="Generation (p.u.)",
               title="Generation Dispatch — $network", grid=true)

    g = results[gen_key]
    totals = Float64[]
    try
        gen_ids = axes(g)[3]
        for d in 1:D, t in 1:T
            push!(totals, sum(g[d, t, gen] for gen in gen_ids))
        end
    catch
        for d in 1:D, t in 1:T
            push!(totals, sum(v for ((dd,tt,_), v) in g if dd==d && tt==t; init=0.0))
        end
    end
    plot!(p, hours, totals; label="Total Generation", linewidth=2, color=:steelblue)

    for d in 1:(D-1)
        vline!(p, [d*T + 0.5]; color=:black, linewidth=0.5, linestyle=:dash, label=false)
    end
    return p
end

function _plot_tradeoff_curve(results_list::Vector; kwargs...)
    xs = Float64[]  # normalized load shed
    ys = Float64[]  # normalized risk
    ws = Float64[]  # tradeoff weights for sorting

    for r in results_list
        ls_norm = get(r, :total_load_shed, 0.0)
        risk_norm = get(r, :active_risk, 0.0) / max(get(r, :total_risk, 1.0), 1e-9)
        w = get(r, :tradeoff_weight, NaN)
        push!(xs, ls_norm); push!(ys, risk_norm); push!(ws, w)
    end

    # Sort by weight so connecting line follows the Pareto frontier
    order = sortperm(ws)
    xs, ys, ws = xs[order], ys[order], ws[order]
    labels = [isnan(w) ? "" : "w=$(round(w, digits=2))" for w in ws]

    p = scatter(xs, ys;
                xlabel="Normalized Load Shed", ylabel="Normalized Active Risk",
                title="Risk vs. Load Shed Tradeoff",
                markersize=6, color=:steelblue, legend=false, grid=true)

    plot!(p, xs, ys; color=:steelblue, linewidth=1, linestyle=:dash, label=false)

    for (x, y, lbl) in zip(xs, ys, labels)
        isempty(lbl) && continue
        annotate!(p, x, y, text(lbl, 7, :left))
    end
    return p
end

function _plot_cost_breakdown(results::Dict; kwargs...)
    network = get(results, :network, "network")
    budget = get(results, :infrastructure_budget, nothing)

    labels = String[]
    costs  = Float64[]

    haskey(results, :battery_cost) && results[:battery_cost] > 0 &&
        (push!(labels, "Battery"); push!(costs, results[:battery_cost]))
    haskey(results, :solar_cost) && results[:solar_cost] > 0 &&
        (push!(labels, "Solar"); push!(costs, results[:solar_cost]))
    haskey(results, :hardening_cost) && results[:hardening_cost] > 0 &&
        (push!(labels, "Hardening"); push!(costs, results[:hardening_cost]))

    isempty(labels) && return plot(title="No infrastructure costs to display")

    costs_M = costs ./ 1e6
    colors = [:tomato, :steelblue, :forestgreen]
    budget_str = budget !== nothing ? "\$$(round(Int, budget/1e6))M" : ""
    title_str = isempty(budget_str) ? "Cost Breakdown — $network" :
                                      "Budget Breakdown $(budget_str) — $network"
    p = bar(labels, costs_M;
            ylabel="Cost (\$M)", title=title_str,
            color=colors[1:length(labels)],
            legend=false, grid=true)

    if budget !== nothing
        hline!(p, [budget/1e6]; color=:black, linewidth=1.5, linestyle=:dash, label=false)
    end
    return p
end
