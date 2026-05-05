"""
Add objective function to the optimization model.
Supports: loadshed, wildfire, cost, and tradeoff objectives.
"""

"""
    add_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict)

Add the appropriate objective function based on opt_parameters[:objective].
"""
function add_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict)
    objective_type = opt_parameters[:objective]
    model_type = opt_parameters[:model]

    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    wf_data = opt_parameters[:wildfire_data]

    metadata = model[:metadata]
    bus_names = metadata[:bus_names]
    gen_names = metadata[:gen_names]
    risky_lines = metadata[:risky_lines]

    # Calculate total load and total risk for normalization
    total_load = calculate_total_load(preprocessed, bus_names, D, T)
    total_risk = sum(sum(values(wf_data[d])) for d in 1:D)

    # Get load shedding expression based on model type
    if model_type == "DCOTS"
        load_shedding = model[:load_shedding]
        nonneg_loadshed = sum(load_shedding[d, t, i] for d in 1:D for t in 1:T for i in bus_names)
    else  # LACOTS
        p_load_shedding = model[:p_load_shedding]
        nonneg_loadshed = sum(p_load_shedding[d, t, i] for d in 1:D for t in 1:T for i in bus_names)
    end

    # Handle switching: either variables (optimal) or fixed values (thresholded)
    switching_method = get(opt_parameters, :switching_method, "optimal")
    hardening_enabled = get(opt_parameters, :hardening_enabled, false)

    if switching_method == "optimal"
        z = model[:z]

        # Calculate active risk (risk from energized lines)
        # risky_lines is now per-day indexed: risky_lines[d] = Vector of line IDs risky on day d
        # If hardening is enabled, reduce risk by effectiveness factor for hardened lines
        if hardening_enabled
            hardenable_lines = opt_parameters[:hardenable_lines]
            effectiveness = opt_parameters[:hardening_effectiveness]
            y = model[:y]

            # Build set for efficient lookup
            hardenable_set = Set(hardenable_lines)

            # Active risk with hardening: risk reduced by (effectiveness * y[l]) for hardenable lines
            active_risk = sum(
                wf_data[d][l] * z[(d, l)] * (l in hardenable_set ? (1 - effectiveness * y[l]) : 1.0)
                for d in 1:D for l in risky_lines[d];
                init=0.0
            )
        else
            # Standard active risk without hardening
            active_risk = sum(wf_data[d][l] * z[(d, l)] for d in 1:D for l in risky_lines[d]; init=0.0)
        end

        # Small penalty for switching (encourages fewer switches when objectives are tied)
        line_penalty = 0.01 * sum((1 - z[(d, l)]) for d in 1:D for l in risky_lines[d]; init=0.0)
    else  # "thresholded"
        z_fixed = opt_parameters[:z_fixed]

        # Calculate active risk from fixed switching decisions + optimal hardening variables.
        # For hardenable lines thresholded off (z_fixed=0): z_eff = y[l] (hardened → re-energized)
        # For hardenable lines energized (z_fixed=1): z_eff = 1, risk reduced by hardening
        # For non-hardenable lines: z_eff = z_fixed (scalar)
        if hardening_enabled
            hardenable_lines = opt_parameters[:hardenable_lines]
            effectiveness = opt_parameters[:hardening_effectiveness]
            y = model[:y]
            hardenable_set = Set(hardenable_lines)

            active_risk = sum(
                begin
                    z_val = z_fixed[(d, l)]
                    risk_val = wf_data[d][l]
                    if l in hardenable_set
                        if z_val == 0
                            # Thresholded off: energized only if hardened (y=1)
                            # Risk contribution (binary y): risk*(1-e)*y[l]
                            risk_val * (1 - effectiveness) * y[l]
                        else
                            # Already energized: risk reduced by hardening
                            risk_val * (1 - effectiveness * y[l])
                        end
                    else
                        risk_val * z_val
                    end
                end
                for d in 1:D for l in risky_lines[d]
            )
        else
            active_risk = sum(wf_data[d][l] * z_fixed[(d, l)] for d in 1:D for l in risky_lines[d]; init=0.0)
        end

        # No line penalty needed for thresholded (switching decisions are pre-fixed)
        line_penalty = 0.0
    end

    # Set objective based on type
    if objective_type == "loadshed"
        add_loadshed_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, line_penalty)
    elseif objective_type == "wildfire"
        add_wildfire_objective!(model, preprocessed, opt_parameters, active_risk, total_risk, nonneg_loadshed, total_load)
    elseif objective_type == "cost"
        add_cost_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, gen_names, D, T)
    elseif objective_type == "tradeoff"
        add_tradeoff_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, total_load, active_risk, total_risk)
    else
        error("Unknown objective type: $objective_type")
    end

    # Store computed values in model for later extraction
    model[:total_load] = total_load
    model[:total_risk] = total_risk
end

"""
    calculate_total_load(preprocessed, bus_names, D, T) -> Float64

Calculate total non-negative load across all buses, days, and hours.
"""
function calculate_total_load(preprocessed::Dict, bus_names, D::Int, T::Int)
    is_cats = preprocessed[:is_cats]
    hourly_loads = preprocessed[:hourly_loads]
    total_load = 0.0

    for d in 1:D
        for t in 1:T
            for i in bus_names
                if is_cats
                    hourly_ref = preprocessed[:hourly_refs][d][t]
                    load_val = reduce(+, hourly_ref[:load][j]["pd"] for j in hourly_ref[:bus_loads][i]; init=0.0)
                    total_load += max(0.0, load_val)
                else
                    total_load += hourly_loads[d]["pd"][i][t]
                end
            end
        end
    end

    return total_load
end

"""
    add_loadshed_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, line_penalty)

Minimize total load shedding with small penalty for switching, not hardening, and battery cost.
"""
function add_loadshed_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                                  nonneg_loadshed, line_penalty)
    switching_method = get(opt_parameters, :switching_method, "optimal")
    objective_expr = nonneg_loadshed + line_penalty

    # Add hardening penalty if enabled (encourages hardening when costs are similar)
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]
        y = model[:y]
        hardening_penalty = 0.01 * sum((1 - y[l]) for l in hardenable_lines)
        objective_expr += hardening_penalty
    end

    # Add battery penalty if enabled (small penalty to encourage battery use)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        battery_cost = opt_parameters[:battery_cost_per_pu]
        battery_penalty = 0.01 * sum(battery_cost * x[i] for i in battery_locs) / 1e9
        objective_expr += battery_penalty
    end

    # Add solar penalty if enabled (small penalty proportional to installation cost)
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        s = model[:s]
        solar_cost = opt_parameters[:solar_cost_per_pu]
        solar_penalty = 0.01 * sum(solar_cost * s[n] for n in solar_locs) / 1e9
        objective_expr += solar_penalty
    end

    @objective(model, Min, objective_expr)
end

"""
    add_wildfire_objective!(model, preprocessed, opt_parameters, active_risk, total_risk, nonneg_loadshed, total_load)

Minimize total wildfire risk (maximize risk removed by switching).
"""
function add_wildfire_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                                  active_risk, total_risk, nonneg_loadshed, total_load)
    # Minimize active risk (risk from energized lines)
    # Add small penalty for load shedding to avoid unnecessary shedding
    loadshed_penalty = 0.001 * nonneg_loadshed / total_load
    objective_expr = active_risk / total_risk + loadshed_penalty

    # Add battery penalty if enabled (small penalty to encourage battery use)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        battery_cost = opt_parameters[:battery_cost_per_pu]
        battery_penalty = 0.001 * sum(battery_cost * x[i] for i in battery_locs) / 1e9
        objective_expr += battery_penalty
    end

    # Add solar penalty if enabled
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        s = model[:s]
        solar_cost = opt_parameters[:solar_cost_per_pu]
        solar_penalty = 0.001 * sum(solar_cost * s[n] for n in solar_locs) / 1e9
        objective_expr += solar_penalty
    end

    @objective(model, Min, objective_expr)
end

"""
    add_cost_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, gen_names, D, T)

Minimize generation cost plus Value of Lost Load (VOLL) penalty plus hardening cost plus battery cost.
"""
function add_cost_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                              nonneg_loadshed, gen_names, D::Int, T::Int)
    ref = preprocessed[:base_ref]
    voll = opt_parameters[:voll]
    model_type = opt_parameters[:model]
    switching_method = get(opt_parameters, :switching_method, "optimal")

    # Get generation variables
    if model_type == "DCOTS"
        g = model[:g]
        # Calculate generation cost using piecewise linear cost curves
        gen_cost = calculate_generation_cost(ref, g, gen_names, D, T)
    else  # LACOTS
        pg = model[:pg]
        gen_cost = calculate_generation_cost(ref, pg, gen_names, D, T)
    end

    # Total cost = generation cost + VOLL * load shed + hardening cost + battery cost
    total_cost = gen_cost + voll * nonneg_loadshed

    # Add hardening cost if enabled
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]
        line_lengths = preprocessed[:line_lengths]
        cost_per_mile = opt_parameters[:hardening_cost_per_mile]
        y = model[:y]

        hardening_cost = sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
        total_cost += hardening_cost
    end

    # Add battery cost if enabled (always add for cost objective)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        battery_cost_per_pu = opt_parameters[:battery_cost_per_pu]
        battery_cost = sum(battery_cost_per_pu * x[i] for i in battery_locs)
        total_cost += battery_cost
    end

    # Add solar cost if enabled (always add for cost objective)
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        s = model[:s]
        solar_cost_per_pu = opt_parameters[:solar_cost_per_pu]
        solar_cost = sum(solar_cost_per_pu * s[n] for n in solar_locs)
        total_cost += solar_cost
    end

    @objective(model, Min, total_cost)
end

"""
    calculate_generation_cost(ref, gen_var, gen_names, D, T) -> AffExpr

Calculate total generation cost from cost curves.
"""
function calculate_generation_cost(ref::Dict, gen_var, gen_names, D::Int, T::Int)
    gen_cost = AffExpr(0.0)

    for d in 1:D
        for t in 1:T
            for i in gen_names
                if haskey(ref[:gen][i], "cost")
                    cost_data = ref[:gen][i]["cost"]
                    # PowerModels uses polynomial cost: cost = c2*g^2 + c1*g + c0
                    # For linear approximation, use c1 (marginal cost)
                    if length(cost_data) >= 2
                        # cost_data is typically [c2, c1, c0] or [c1, c0]
                        if length(cost_data) == 3
                            # Quadratic cost: linearize using c1 (first-order term)
                            c1 = cost_data[2]
                        else
                            # Linear cost: c1 is first element
                            c1 = cost_data[1]
                        end
                        add_to_expression!(gen_cost, c1 * gen_var[d, t, i])
                    end
                else
                    # Default cost if not specified ($/MWh)
                    default_cost = 50.0
                    add_to_expression!(gen_cost, default_cost * gen_var[d, t, i])
                end
            end
        end
    end

    return gen_cost
end

"""
    add_tradeoff_objective!(model, preprocessed, opt_parameters, nonneg_loadshed, total_load, active_risk, total_risk)

Minimize weighted combination of normalized load shed and wildfire risk.
weight = 0: minimize load shed only
weight = 1: minimize wildfire risk only
"""
function add_tradeoff_objective!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                                  nonneg_loadshed, total_load, active_risk, total_risk)
    weight = opt_parameters[:tradeoff_weight]

    # Normalize both objectives to [0, 1] range
    normalized_loadshed = nonneg_loadshed / total_load
    normalized_risk = active_risk / total_risk

    # Weighted combination: (1-w)*loadshed + w*risk
    objective_expr = (1 - weight) * normalized_loadshed + weight * normalized_risk

    # Add battery penalty if enabled (small penalty to encourage battery use)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        battery_cost = opt_parameters[:battery_cost_per_pu]
        battery_penalty = 0.01 * sum(battery_cost * x[i] for i in battery_locs) / 1e9
        objective_expr += battery_penalty
    end

    # Add solar penalty if enabled
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        s = model[:s]
        solar_cost = opt_parameters[:solar_cost_per_pu]
        solar_penalty = 0.01 * sum(solar_cost * s[n] for n in solar_locs) / 1e9
        objective_expr += solar_penalty
    end

    @objective(model, Min, objective_expr)
end
