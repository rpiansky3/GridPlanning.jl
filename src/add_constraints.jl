"""
Add power flow and operational constraints to the optimization model.
"""

"""
    add_constraints!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict, flow_exprs::Dict)

Add all constraints based on model type (DCOTS or LACOTS).
"""
function add_constraints!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict, flow_exprs::Dict)
    model_type = opt_parameters[:model]

    if model_type == "DCOTS"
        add_dcots_constraints!(model, preprocessed, opt_parameters, flow_exprs[:p_expr])
    else  # LACOTS
        add_lacots_constraints!(model, preprocessed, opt_parameters, flow_exprs[:p_expr], flow_exprs[:q_expr])
    end
end

"""
    add_dcots_constraints!(model, preprocessed, opt_parameters, p_expr)

Add DC Optimal Power Flow constraints with switching.
"""
function add_dcots_constraints!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict, p_expr::Dict)
    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    hourly_loads = preprocessed[:hourly_loads]
    is_cats = preprocessed[:is_cats]
    wf_data = opt_parameters[:wildfire_data]
    threshold = opt_parameters[:threshold]

    metadata = model[:metadata]
    bus_names = metadata[:bus_names]
    branch_names = metadata[:branch_names]
    risky_lines = metadata[:risky_lines]

    # Extract variables
    va = model[:va]
    load_shedding = model[:load_shedding]
    g = model[:g]
    p = model[:p]

    # Handle switching: either variables (optimal) or fixed values (thresholded)
    switching_method = get(opt_parameters, :switching_method, "optimal")
    if switching_method == "optimal"
        z = model[:z]  # Decision variables
        z_fixed = nothing
    else  # "thresholded"
        z = nothing
        z_fixed = opt_parameters[:z_fixed]  # Fixed parameters
    end

    # Pre-load hardening data needed inside the power flow loop
    hardening_enabled = get(opt_parameters, :hardening_enabled, false)
    hardenable_set = hardening_enabled ? Set(opt_parameters[:hardenable_lines]) : Set{Int}()
    y = hardening_enabled ? model[:y] : nothing

    # Big-M values for voltage angle relaxation
    vad_max = 2 * pi
    vad_min = -2 * pi

    # Reference bus constraints
    for d in 1:D, t in 1:T
        for i in keys(ref[:ref_buses])
            @constraint(model, va[d, t, i] == 0)
        end
    end

    # Power flow and angle constraints for each branch
    for d in 1:D, t in 1:T
        for (l, i, j) in branch_names
            va_fr = va[d, t, i]
            va_to = va[d, t, j]

            # Compute branch parameters
            g1, b1 = PowerModels.calc_branch_y(ref[:branch][l])

            if l in risky_lines[d]
                # Switchable line on this day: relax constraints with Big-M
                # z_val is z variable (optimal), or fixed value (thresholded).
                # For thresholded + hardening: hardenable lines that were switched off
                # can be re-energized by the hardening decision variable y[l].
                if switching_method == "optimal"
                    z_val = z[(d, l)]
                elseif hardening_enabled && l in hardenable_set && z_fixed[(d, l)] == 0
                    z_val = y[l]  # Hardened → re-energized; not hardened → stays off
                else
                    z_val = z_fixed[(d, l)]
                end

                # Power flow limits: |p| <= rate_a * z
                rate_a = branch_rate_a(ref[:branch][l])
                @constraint(model, -rate_a * z_val <= p[d, t, (l, i, j)])
                @constraint(model, p[d, t, (l, i, j)] <= rate_a * z_val)

                # DC power flow: p = -b1*(va_fr - va_to) when z=1
                # Relaxed with Big-M when z=0
                @constraint(model, p[d, t, (l, i, j)] <= -b1 * (va_fr - va_to) + abs(b1) * vad_max * (1 - z_val))
                @constraint(model, p[d, t, (l, i, j)] >= -b1 * (va_fr - va_to) + abs(b1) * vad_min * (1 - z_val))

                # Voltage angle difference limits (relaxed when z=0)
                @constraint(model, va_fr - va_to <= ref[:branch][l]["angmax"] + vad_max * (1 - z_val))
                @constraint(model, va_fr - va_to >= ref[:branch][l]["angmin"] + vad_min * (1 - z_val))
            else
                # Non-switchable line: standard constraints

                # Voltage angle difference limits
                @constraint(model, va_fr - va_to <= ref[:branch][l]["angmax"])
                @constraint(model, va_fr - va_to >= ref[:branch][l]["angmin"])

                # DC power flow constraint
                @constraint(model, p[d, t, (l, i, j)] == -b1 * (va_fr - va_to))
            end
        end
    end

    # Risk threshold constraint (if specified and using optimal method).
    # For thresholded method, threshold is already satisfied by design.
    # When hardening is enabled: under the energization constraint (y[l] <= z[d,l]),
    # z[d,l]*y[l] = y[l] for binary variables, so z*(1-e*y) = z - e*y (linear).
    # This credits hardening toward meeting the threshold, incentivizing line hardening
    # instead of de-energization when the risk constraint must be satisfied.
    if threshold !== nothing && switching_method == "optimal"
        println("Setting risk threshold of $threshold")
        effectiveness_thresh = hardening_enabled ? opt_parameters[:hardening_effectiveness] : 0.0
        for d in 1:D
            active_risk = sum(
                begin
                    rv = wf_data[d][l] * z[(d, l)]
                    (hardening_enabled && l in hardenable_set) ?
                        rv - effectiveness_thresh * wf_data[d][l] * y[l] : rv
                end
                for l in risky_lines[d]
            )
            @constraint(model, active_risk <= threshold)
        end
    end

    # Hardening constraints (apply regardless of switching method — y is always a variable)
    if hardening_enabled
        hardenable_lines = opt_parameters[:hardenable_lines]
        line_lengths = preprocessed[:line_lengths]
        cost_per_mile = opt_parameters[:hardening_cost_per_mile]
        budget = opt_parameters[:hardening_budget]
        enforce_energization = opt_parameters[:hardening_enforce_energization]

        # Budget constraint (if budget is finite)
        if budget < Inf
            hardening_cost = sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
            @constraint(model, hardening_budget_constraint, hardening_cost <= budget)
        end

        # Hardening-energization coupling: if hardened, must be energized (y[l] <= z[d,l]).
        # For "optimal": enforced via z variable constraint.
        # For "thresholded": handled implicitly — thresholded-off hardenable lines use y[l]
        #   as their effective z in the power flow constraints (see loop above).
        if switching_method == "optimal" && enforce_energization
            for d in 1:D
                for l in hardenable_lines
                    if l in risky_lines[d]
                        @constraint(model, (1 - z[(d, l)]) + y[l] <= 1)
                    end
                end
            end
        end
    end

    # Battery constraints
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        soc = model[:soc]
        p_charge = model[:p_charge]
        p_discharge = model[:p_discharge]

        eta_c = opt_parameters[:battery_charge_efficiency]
        eta_d = opt_parameters[:battery_discharge_efficiency]
        decay = opt_parameters[:battery_soc_carryover]
        c_rate = opt_parameters[:battery_charge_rate]
        d_rate = opt_parameters[:battery_discharge_rate]
        exclusive = opt_parameters[:battery_exclusive_operation]
        max_network = opt_parameters[:battery_max_network]

        # Initial SOC and inter-day SOC carryover
        for d in 1:D
            for i in battery_locs
                if d == 1
                    # First day: start fully charged
                    @constraint(model, soc[d, 0, i] == x[i])
                else
                    # Subsequent days: carry over SOC from previous day
                    @constraint(model, soc[d, 0, i] == soc[d-1, T, i])
                end
            end
        end

        # SOC dynamics and bounds
        for d in 1:D, t in 1:T, i in battery_locs
            # SOC dynamics: energy balance with efficiency and hourly decay
            @constraint(model,
                soc[d, t, i] == decay * soc[d, t-1, i] +
                                eta_c * p_charge[d, t, i] -
                                p_discharge[d, t, i] / eta_d
            )

            # SOC upper bound (constrained by installed capacity)
            @constraint(model, soc[d, t, i] <= x[i])

            # Charge/discharge rate constraints (linked to installed capacity)
            @constraint(model, p_charge[d, t, i] <= c_rate * x[i])
            @constraint(model, p_discharge[d, t, i] <= d_rate * x[i])

            # Exclusive operation constraint (if enabled)
            if exclusive
                max_rate = max(c_rate, d_rate)
                @constraint(model, p_charge[d, t, i] + p_discharge[d, t, i] <= max_rate * x[i])
            end
        end

        # Network-wide capacity limit
        if max_network !== nothing
            @constraint(model, battery_network_limit, sum(x[i] for i in battery_locs) <= max_network)
        end

        # Infrastructure budget constraint (shared with hardening)
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            battery_cost = sum(opt_parameters[:battery_cost_per_pu] * x[i] for i in battery_locs)
            if hardening_enabled
                # Replace hardening-only constraint with combined constraint
                if haskey(model, :hardening_budget_constraint)
                    delete(model, model[:hardening_budget_constraint])
                    unregister(model, :hardening_budget_constraint)
                end
                hardenable_lines = opt_parameters[:hardenable_lines]
                line_lengths = preprocessed[:line_lengths]
                cost_per_mile = opt_parameters[:hardening_cost_per_mile]
                hardening_cost = sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
                @constraint(model, infrastructure_budget_constraint, hardening_cost + battery_cost <= budget)
            else
                @constraint(model, infrastructure_budget_constraint, battery_cost <= budget)
            end
        end
    end

    # Solar constraints
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        solar_cf = preprocessed[:solar_cf]
        s = model[:s]
        p_solar = model[:p_solar]
        max_network = opt_parameters[:solar_max_network]

        # Generation bound: p_solar[d,t,n] <= capacity_factor[d,t,n] * s[n]
        for d in 1:D, t in 1:T, n in solar_locs
            cf = get(solar_cf, (d, t, n), 0.0)
            @constraint(model, p_solar[d, t, n] <= cf * s[n])
        end

        # Network-wide solar capacity limit
        if max_network !== nothing
            @constraint(model, solar_network_limit, sum(s[n] for n in solar_locs) <= max_network)
        end

        # Infrastructure budget constraint (replace any existing budget constraint)
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            total_infra_cost = sum(opt_parameters[:solar_cost_per_pu] * s[n] for n in solar_locs)

            if get(opt_parameters, :battery_enabled, false)
                battery_locs = preprocessed[:battery_locs]
                x = model[:x]
                total_infra_cost += sum(opt_parameters[:battery_cost_per_pu] * x[i] for i in battery_locs)
            end

            if hardening_enabled
                hardenable_lines = opt_parameters[:hardenable_lines]
                line_lengths = preprocessed[:line_lengths]
                cost_per_mile = opt_parameters[:hardening_cost_per_mile]
                total_infra_cost += sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
            end

            # Replace any existing budget constraint
            for cname in [:infrastructure_budget_constraint, :hardening_budget_constraint]
                if haskey(model, cname)
                    delete(model, model[cname])
                    unregister(model, cname)
                end
            end

            @constraint(model, infrastructure_budget_constraint, total_infra_cost <= budget)
        end
    end

    # Bus power balance constraints
    for d in 1:D, t in 1:T
        for k in bus_names
            if is_cats
                hourly_ref = preprocessed[:hourly_refs][d][t]
                bus_load = reduce(+, hourly_ref[:load][j]["pd"] for j in hourly_ref[:bus_loads][k]; init=0.0)
            else
                bus_load = hourly_loads[d]["pd"][k][t]
            end

            # Battery charge/discharge terms (if battery enabled at this bus)
            battery_net_injection = 0.0
            if get(opt_parameters, :battery_enabled, false)
                battery_locs = preprocessed[:battery_locs]
                if k in battery_locs
                    x = model[:x]
                    p_charge = model[:p_charge]
                    p_discharge = model[:p_discharge]
                    battery_net_injection = p_discharge[d, t, k] - p_charge[d, t, k]
                end
            end

            # Solar generation term (if solar enabled at this bus)
            solar_injection = 0.0
            if get(opt_parameters, :solar_enabled, false)
                solar_locs = preprocessed[:solar_locs]
                if k in solar_locs
                    p_solar = model[:p_solar]
                    solar_injection = p_solar[d, t, k]
                end
            end

            @constraint(model,
                sum(p_expr[(d, t, (l, i, j))] for (l, i, j) in ref[:bus_arcs][k])
                == sum(g[d, t, m] for m in ref[:bus_gens][k])
                - bus_load
                + load_shedding[d, t, k]
                + battery_net_injection
                + solar_injection
            )
        end
    end
end

"""
    add_lacots_constraints!(model, preprocessed, opt_parameters, p_expr, q_expr)

Add Linear AC Optimal Power Flow constraints with switching.
"""
function add_lacots_constraints!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict, p_expr::Dict, q_expr::Dict)
    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    hourly_loads = preprocessed[:hourly_loads]
    is_cats = preprocessed[:is_cats]
    wf_data = opt_parameters[:wildfire_data]
    threshold = opt_parameters[:threshold]
    non_linear = opt_parameters[:non_linear]

    metadata = model[:metadata]
    bus_names = metadata[:bus_names]
    branch_names = metadata[:branch_names]
    risky_lines = metadata[:risky_lines]

    # Extract variables
    va = model[:va]
    vm = model[:vm]
    p_load_shedding = model[:p_load_shedding]
    q_load_shedding = model[:q_load_shedding]
    pg = model[:pg]
    qg = model[:qg]
    p = model[:p]
    q = model[:q]

    # Handle switching: either variables (optimal) or fixed values (thresholded)
    switching_method = get(opt_parameters, :switching_method, "optimal")
    if switching_method == "optimal"
        z = model[:z]  # Decision variables
        z_fixed = nothing
    else  # "thresholded"
        z = nothing
        z_fixed = opt_parameters[:z_fixed]  # Fixed parameters
    end

    # Pre-load hardening data needed inside the power flow loop
    hardening_enabled = get(opt_parameters, :hardening_enabled, false)
    hardenable_set = hardening_enabled ? Set(opt_parameters[:hardenable_lines]) : Set{Int}()
    y = hardening_enabled ? model[:y] : nothing

    # Big-M values
    vad_max = sum([branch["angmax"] for branch in values(ref[:branch])])
    vad_min = sum([branch["angmin"] for branch in values(ref[:branch]) if branch["angmin"] <= 0])

    # Calculate voltage magnitude big-M
    vm_max = maximum([ref[:bus][i]["vmax"] for i in bus_names])
    vm_min = minimum([ref[:bus][i]["vmin"] for i in bus_names])
    big_vm = vm_max - vm_min

    # Reference bus constraints
    for d in 1:D, t in 1:T
        for i in keys(ref[:ref_buses])
            @constraint(model, va[d, t, i] == 0)
        end
    end

    # Power flow and angle constraints
    for d in 1:D, t in 1:T
        for (l, i, j) in branch_names
            va_fr = va[d, t, i]
            va_to = va[d, t, j]
            vm_fr = vm[d, t, i]
            vm_to = vm[d, t, j]

            # Compute branch parameters
            g1, b1 = PowerModels.calc_branch_y(ref[:branch][l])

            if l in risky_lines[d]
                # Switchable line on this day: relax constraints with Big-M
                # For thresholded + hardening: hardenable lines switched off can be
                # re-energized by the hardening decision variable y[l].
                if switching_method == "optimal"
                    z_val = z[(d, l)]
                elseif hardening_enabled && l in hardenable_set && z_fixed[(d, l)] == 0
                    z_val = y[l]  # Hardened → re-energized; not hardened → stays off
                else
                    z_val = z_fixed[(d, l)]
                end

                # Active power flow limits
                rate_a = branch_rate_a(ref[:branch][l])
                @constraint(model, -rate_a * z_val <= p[d, t, (l, i, j)])
                @constraint(model, p[d, t, (l, i, j)] <= rate_a * z_val)

                # Reactive power flow limits
                @constraint(model, -rate_a * z_val <= q[d, t, (l, i, j)])
                @constraint(model, q[d, t, (l, i, j)] <= rate_a * z_val)

                # Linear AC active power flow (relaxed when z=0)
                @constraint(model,
                    p[d, t, (l, i, j)] <= -b1 * (va_fr - va_to) + g1 * (vm_fr - vm_to) +
                                           abs(b1) * vad_max * (1 - z_val) + abs(g1) * big_vm * (1 - z_val))
                @constraint(model,
                    p[d, t, (l, i, j)] >= -b1 * (va_fr - va_to) + g1 * (vm_fr - vm_to) +
                                           abs(b1) * vad_min * (1 - z_val) - abs(g1) * big_vm * (1 - z_val))

                # Linear AC reactive power flow (relaxed when z=0)
                @constraint(model,
                    q[d, t, (l, i, j)] <= -g1 * (va_fr - va_to) - b1 * (vm_fr - vm_to) +
                                           abs(g1) * vad_max * (1 - z_val) + abs(b1) * big_vm * (1 - z_val))
                @constraint(model,
                    q[d, t, (l, i, j)] >= -g1 * (va_fr - va_to) - b1 * (vm_fr - vm_to) +
                                           abs(g1) * vad_min * (1 - z_val) - abs(b1) * big_vm * (1 - z_val))

                # Voltage angle difference limits (relaxed when z=0)
                @constraint(model, va_fr - va_to <= ref[:branch][l]["angmax"] + vad_max * (1 - z_val))
                @constraint(model, va_fr - va_to >= ref[:branch][l]["angmin"] + vad_min * (1 - z_val))
            else
                # Non-switchable line: standard constraints

                # Voltage angle difference limits
                @constraint(model, va_fr - va_to <= ref[:branch][l]["angmax"])
                @constraint(model, va_fr - va_to >= ref[:branch][l]["angmin"])

                # Linear AC active power flow
                @constraint(model, p[d, t, (l, i, j)] == -b1 * (va_fr - va_to) + g1 * (vm_fr - vm_to))

                # Linear AC reactive power flow
                @constraint(model, q[d, t, (l, i, j)] == -g1 * (va_fr - va_to) - b1 * (vm_fr - vm_to))
            end

            # Non-linear apparent power constraint (optional)
            if non_linear
                rate_a = branch_rate_a(ref[:branch][l])
                @constraint(model, p[d, t, (l, i, j)]^2 + q[d, t, (l, i, j)]^2 <= rate_a^2)
            end
        end
    end

    # Risk threshold constraint (if specified and using optimal method).
    # For thresholded method, threshold is already satisfied by design.
    # When hardening is enabled: under the energization constraint (y[l] <= z[d,l]),
    # z[d,l]*y[l] = y[l] for binary variables, so z*(1-e*y) = z - e*y (linear).
    # This credits hardening toward meeting the threshold, incentivizing line hardening
    # instead of de-energization when the risk constraint must be satisfied.
    if threshold !== nothing && switching_method == "optimal"
        println("Setting risk threshold of $threshold")
        effectiveness_thresh = hardening_enabled ? opt_parameters[:hardening_effectiveness] : 0.0
        for d in 1:D
            active_risk = sum(
                begin
                    rv = wf_data[d][l] * z[(d, l)]
                    (hardening_enabled && l in hardenable_set) ?
                        rv - effectiveness_thresh * wf_data[d][l] * y[l] : rv
                end
                for l in risky_lines[d]
            )
            @constraint(model, active_risk <= threshold)
        end
    end

    # Hardening constraints (apply regardless of switching method — y is always a variable)
    if hardening_enabled
        hardenable_lines = opt_parameters[:hardenable_lines]
        line_lengths = preprocessed[:line_lengths]
        cost_per_mile = opt_parameters[:hardening_cost_per_mile]
        budget = opt_parameters[:hardening_budget]
        enforce_energization = opt_parameters[:hardening_enforce_energization]

        # Budget constraint (if budget is finite)
        if budget < Inf
            hardening_cost = sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
            @constraint(model, hardening_budget_constraint, hardening_cost <= budget)
        end

        # Hardening-energization coupling (only for "optimal" — thresholded handles implicitly)
        if switching_method == "optimal" && enforce_energization
            for d in 1:D
                for l in hardenable_lines
                    if l in risky_lines[d]
                        @constraint(model, (1 - z[(d, l)]) + y[l] <= 1)
                    end
                end
            end
        end
    end

    # Battery constraints (active and reactive power for LACOTS)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        x = model[:x]
        soc = model[:soc]
        p_charge = model[:p_charge]
        p_discharge = model[:p_discharge]
        q_charge = model[:q_charge]
        q_discharge = model[:q_discharge]

        eta_c = opt_parameters[:battery_charge_efficiency]
        eta_d = opt_parameters[:battery_discharge_efficiency]
        decay = opt_parameters[:battery_soc_carryover]
        c_rate = opt_parameters[:battery_charge_rate]
        d_rate = opt_parameters[:battery_discharge_rate]
        exclusive = opt_parameters[:battery_exclusive_operation]
        max_network = opt_parameters[:battery_max_network]
        linearized = opt_parameters[:linearized_battery_power]

        # Initial SOC and inter-day SOC carryover
        for d in 1:D
            for i in battery_locs
                if d == 1
                    # First day: start fully charged
                    @constraint(model, soc[d, 0, i] == x[i])
                else
                    # Subsequent days: carry over SOC from previous day
                    @constraint(model, soc[d, 0, i] == soc[d-1, T, i])
                end
            end
        end

        # SOC dynamics and bounds
        for d in 1:D, t in 1:T, i in battery_locs
            # SOC dynamics: energy balance with efficiency and hourly decay
            # Note: SOC is based on active power only (energy storage)
            @constraint(model,
                soc[d, t, i] == decay * soc[d, t-1, i] +
                                eta_c * p_charge[d, t, i] -
                                p_discharge[d, t, i] / eta_d
            )

            # SOC upper bound (constrained by installed capacity)
            @constraint(model, soc[d, t, i] <= x[i])

            # Power constraints: linearized vs nonlinear
            if linearized
                # Linearized case: separate bounds for P and Q
                @constraint(model, p_charge[d, t, i] <= c_rate * x[i])
                @constraint(model, p_discharge[d, t, i] <= d_rate * x[i])
                @constraint(model, q_charge[d, t, i] <= c_rate * x[i])
                @constraint(model, q_discharge[d, t, i] <= d_rate * x[i])

                # Exclusive operation constraint (if enabled)
                if exclusive
                    max_rate = max(c_rate, d_rate)
                    @constraint(model, p_charge[d, t, i] + p_discharge[d, t, i] <= max_rate * x[i])
                    @constraint(model, q_charge[d, t, i] + q_discharge[d, t, i] <= max_rate * x[i])
                end
            else
                # Nonlinear case: capability curve constraints
                @constraint(model, p_charge[d, t, i]^2 + q_charge[d, t, i]^2 <= (c_rate * x[i])^2)
                @constraint(model, p_discharge[d, t, i]^2 + q_discharge[d, t, i]^2 <= (d_rate * x[i])^2)

                # Exclusive operation constraint (if enabled)
                if exclusive
                    max_rate = max(c_rate, d_rate)
                    @constraint(model, p_charge[d, t, i]^2 + q_charge[d, t, i]^2 +
                                       p_discharge[d, t, i]^2 + q_discharge[d, t, i]^2 <= (max_rate * x[i])^2)
                end
            end
        end

        # Network-wide capacity limit
        if max_network !== nothing
            @constraint(model, battery_network_limit, sum(x[i] for i in battery_locs) <= max_network)
        end

        # Infrastructure budget constraint (shared with hardening)
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            battery_cost = sum(opt_parameters[:battery_cost_per_pu] * x[i] for i in battery_locs)
            if hardening_enabled
                if haskey(model, :hardening_budget_constraint)
                    delete(model, model[:hardening_budget_constraint])
                    unregister(model, :hardening_budget_constraint)
                end
                hardenable_lines = opt_parameters[:hardenable_lines]
                line_lengths = preprocessed[:line_lengths]
                cost_per_mile = opt_parameters[:hardening_cost_per_mile]
                hardening_cost = sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
                @constraint(model, infrastructure_budget_constraint, hardening_cost + battery_cost <= budget)
            else
                @constraint(model, infrastructure_budget_constraint, battery_cost <= budget)
            end
        end
    end

    # Solar constraints (active and reactive power for LACOTS)
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        solar_cf = preprocessed[:solar_cf]
        s = model[:s]
        p_solar = model[:p_solar]
        q_solar = model[:q_solar]
        max_network = opt_parameters[:solar_max_network]
        linearized_solar = opt_parameters[:linearized_solar_power]

        for d in 1:D, t in 1:T, n in solar_locs
            cf = get(solar_cf, (d, t, n), 0.0)
            @constraint(model, p_solar[d, t, n] <= cf * s[n])

            if cf > 0
                if linearized_solar
                    # Linearized (rectangular) capability: |Q| ≤ cf * S_rated
                    @constraint(model, q_solar[d, t, n] <= cf * s[n])
                    @constraint(model, q_solar[d, t, n] >= -cf * s[n])
                else
                    # Nonlinear (circular) capability curve: P² + Q² ≤ S_rated²
                    @constraint(model, p_solar[d, t, n]^2 + q_solar[d, t, n]^2 <= s[n]^2)
                end
            else
                # No reactive power when solar is unavailable (inverter offline)
                @constraint(model, q_solar[d, t, n] == 0)
            end
        end

        if max_network !== nothing
            @constraint(model, solar_network_limit, sum(s[n] for n in solar_locs) <= max_network)
        end

        # Replace any existing budget constraint with full infrastructure budget
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            total_infra_cost = sum(opt_parameters[:solar_cost_per_pu] * s[n] for n in solar_locs)

            if get(opt_parameters, :battery_enabled, false)
                battery_locs = preprocessed[:battery_locs]
                x = model[:x]
                total_infra_cost += sum(opt_parameters[:battery_cost_per_pu] * x[i] for i in battery_locs)
            end

            if hardening_enabled
                hardenable_lines = opt_parameters[:hardenable_lines]
                line_lengths = preprocessed[:line_lengths]
                cost_per_mile = opt_parameters[:hardening_cost_per_mile]
                total_infra_cost += sum(cost_per_mile * line_lengths[l] * y[l] for l in hardenable_lines)
            end

            for cname in [:infrastructure_budget_constraint, :hardening_budget_constraint]
                if haskey(model, cname)
                    delete(model, model[cname])
                    unregister(model, cname)
                end
            end

            @constraint(model, infrastructure_budget_constraint, total_infra_cost <= budget)
        end
    end

    # Bus power balance constraints
    for d in 1:D, t in 1:T
        for k in bus_names
            if is_cats
                hourly_ref = preprocessed[:hourly_refs][d][t]
                pd_load = reduce(+, hourly_ref[:load][j]["pd"] for j in hourly_ref[:bus_loads][k]; init=0.0)
                qd_load = reduce(+, hourly_ref[:load][j]["qd"] for j in hourly_ref[:bus_loads][k]; init=0.0)
            else
                pd_load = hourly_loads[d]["pd"][k][t]
                qd_load = hourly_loads[d]["qd"][k][t]
            end

            # Battery charge/discharge terms (if battery enabled at this bus)
            battery_p_net_injection = 0.0
            battery_q_net_injection = 0.0
            if get(opt_parameters, :battery_enabled, false)
                battery_locs = preprocessed[:battery_locs]
                if k in battery_locs
                    p_charge = model[:p_charge]
                    p_discharge = model[:p_discharge]
                    q_charge = model[:q_charge]
                    q_discharge = model[:q_discharge]
                    battery_p_net_injection = p_discharge[d, t, k] - p_charge[d, t, k]
                    battery_q_net_injection = q_discharge[d, t, k] - q_charge[d, t, k]
                end
            end

            # Solar generation terms (active and reactive power)
            solar_p_injection = 0.0
            solar_q_injection = 0.0
            if get(opt_parameters, :solar_enabled, false)
                solar_locs = preprocessed[:solar_locs]
                if k in solar_locs
                    p_solar = model[:p_solar]
                    q_solar = model[:q_solar]
                    solar_p_injection = p_solar[d, t, k]
                    solar_q_injection = q_solar[d, t, k]
                end
            end

            # Proportional reactive load shedding constraint
            @constraint(model, q_load_shedding[d, t, k] <= 0.1 * p_load_shedding[d, t, k])

            # Active power balance
            @constraint(model,
                sum(p_expr[(d, t, (l, i, j))] for (l, i, j) in ref[:bus_arcs][k])
                == sum(pg[d, t, m] for m in ref[:bus_gens][k])
                - pd_load
                + p_load_shedding[d, t, k]
                + battery_p_net_injection
                + solar_p_injection
            )

            # Reactive power balance
            @constraint(model,
                sum(q_expr[(d, t, (l, i, j))] for (l, i, j) in ref[:bus_arcs][k])
                == sum(qg[d, t, m] for m in ref[:bus_gens][k])
                - qd_load
                + q_load_shedding[d, t, k]
                + battery_q_net_injection
                + solar_q_injection
            )
        end
    end
end
