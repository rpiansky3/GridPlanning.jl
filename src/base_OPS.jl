"""
Main optimization solver for Optimal Transmission Switching with wildfire risk.
"""

"""
    run_optimization(opt_parameters::Dict, preprocessed::Dict) -> Dict

Main optimization function that builds and solves the OTS model.
"""
function run_optimization(opt_parameters::Dict, preprocessed::Dict)
    model_type = opt_parameters[:model]
    warm_start = opt_parameters[:warm_start]

    # Handle auto warm start for LACOTS
    if model_type == "LACOTS" && warm_start == "auto"
        println("Running DCOTS first for warm start...")
        warm_start_dict = run_dcots_for_warmstart(opt_parameters, preprocessed)
        opt_parameters[:warm_start] = warm_start_dict
    end

    # Build and solve the main model
    results = build_and_solve_model(opt_parameters, preprocessed)

    return results
end

"""
    run_dcots_for_warmstart(opt_parameters, preprocessed) -> Dict

Run DCOTS to generate warm start values for LACOTS.
Includes both z (switching) and y (hardening) values if hardening is enabled.
"""
function run_dcots_for_warmstart(opt_parameters::Dict, preprocessed::Dict)
    # Create a copy of opt_parameters for DCOTS
    dcots_params = copy(opt_parameters)
    dcots_params[:model] = "DCOTS"
    dcots_params[:warm_start] = nothing
    dcots_params[:output_format] = "dict"

    # Run DCOTS optimization
    dcots_results = build_and_solve_model(dcots_params, preprocessed)

    # Extract z values for warm start
    # Use first day's z values as warm start (they should be similar across days)
    z_values = Dict{Int,Float64}()
    wf_data = opt_parameters[:wildfire_data]
    D = preprocessed[:D]

    # Get unique risky lines across all days
    for d in 1:D
        for l in keys(wf_data[d])
            if !haskey(z_values, l)
                # Use this day's z value as warm start
                z_values[l] = dcots_results[:z][(d, l)]
            end
        end
    end

    # Extract y values if hardening is enabled
    warm_start_dict = Dict{String,Any}("z" => z_values)
    if haskey(dcots_results, :y)
        y_values = Dict{Int,Float64}()
        for (l, val) in dcots_results[:y]
            y_values[l] = val
        end
        warm_start_dict["y"] = y_values
    end

    return warm_start_dict
end

"""
    build_and_solve_model(opt_parameters, preprocessed) -> Dict

Build the JuMP model, add variables/constraints/objective, and solve.
"""
function build_and_solve_model(opt_parameters::Dict, preprocessed::Dict)
    time_limit = opt_parameters[:time_limit]
    mip_gap = opt_parameters[:mip_gap]
    switching_method = get(opt_parameters, :switching_method, "optimal")

    println("Building $(opt_parameters[:model]) model...")
    println("Switching method: $switching_method")
    println("Network: $(opt_parameters[:network])")
    println("Objective: $(opt_parameters[:objective])")
    println("Days: $(preprocessed[:D]), Hours per day: $(preprocessed[:T])")

    # For thresholded switching method: pre-compute fixed line statuses (greedy risk threshold).
    # Hardening is always solved optimally via binary y variables, regardless of switching method.
    if switching_method == "thresholded"
        threshold = opt_parameters[:threshold]
        if threshold === nothing
            error("Thresholded method requires a threshold parameter")
        end
        wf_data = opt_parameters[:wildfire_data]
        D = preprocessed[:D]
        z_fixed = compute_thresholded_line_statuses(wf_data, threshold, D)
        opt_parameters[:z_fixed] = z_fixed
    end

    # Initialize optimization model
    model = Model(Gurobi.Optimizer)

    # Set solver parameters
    set_optimizer_attribute(model, "Seed", 1)
    set_optimizer_attribute(model, "MIPGap", mip_gap)
    MOI.set(model, MOI.RawOptimizerAttribute("TimeLimit"), time_limit)
    set_optimizer_attribute(model, MOI.Silent(), false)

    # Set log file if requested
    log_str = opt_parameters[:log_str]
    if !isempty(log_str)
        set_optimizer_attribute(model, "LogFile", log_str)
        println("Gurobi log will be written to: $log_str")
    end

    # Additional parameters for numerical stability (especially for larger networks)
    if preprocessed[:is_cats] || preprocessed[:D] > 1
        set_optimizer_attribute(model, "MIPFocus", 2)
        set_optimizer_attribute(model, "Method", 2)  # Barrier method
    end

    # Add variables
    println("Adding variables...")
    flow_exprs = add_variables!(model, preprocessed, opt_parameters)

    # Add objective
    println("Adding objective function...")
    add_objective!(model, preprocessed, opt_parameters)

    # Add constraints
    println("Adding constraints...")
    add_constraints!(model, preprocessed, opt_parameters, flow_exprs)

    # Solve optimization
    println("Solving optimization...")
    start_time = time()
    optimize!(model)
    solve_time = time() - start_time

    # Save model to LP file if requested
    lp_str = opt_parameters[:lp_str]
    if !isempty(lp_str)
        println("Writing model to LP file: $lp_str")
        JuMP.write_to_file(model, lp_str)
    end

    # Extract results
    println("Extracting results...")
    results = extract_results(model, preprocessed, opt_parameters, solve_time)

    return results
end

"""
    extract_results(model, preprocessed, opt_parameters, solve_time) -> Dict

Extract optimization results from the solved model.
"""
function extract_results(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict, solve_time::Float64)
    D = preprocessed[:D]
    T = preprocessed[:T]
    model_type = opt_parameters[:model]
    wf_data = opt_parameters[:wildfire_data]

    metadata = model[:metadata]
    bus_names = metadata[:bus_names]
    branch_names = metadata[:branch_names]
    gen_names = metadata[:gen_names]
    risky_lines = metadata[:risky_lines]

    # Basic optimization info
    results = Dict{Symbol,Any}(
        :status => termination_status(model),
        :solve_time => solve_time,
        :objective_value => objective_value(model),
        :model_type => model_type,
        :D => D,
        :T => T,
        :times => preprocessed[:times_array],
        :network => opt_parameters[:network],
        :data_dir => get(opt_parameters, :data_dir, "data")
    )

    # Extract switching decisions
    # z is indexed by (d, l) tuples where l is risky on day d
    results[:z] = Dict{Tuple{Int,Int},Float64}()
    switching_method = get(opt_parameters, :switching_method, "optimal")

    if switching_method == "optimal"
        z = model[:z]
        for d in 1:D
            for l in risky_lines[d]
                results[:z][(d, l)] = value(z[(d, l)])
            end
        end
    else  # "thresholded"
        z_fixed = opt_parameters[:z_fixed]
        # For thresholded + hardening: hardenable lines that were thresholded off (z_fixed=0)
        # but hardened (y=1) are effectively energized. Adjust z values accordingly.
        if get(opt_parameters, :hardening_enabled, false)
            y_model = model[:y]
            hardenable_set = Set(opt_parameters[:hardenable_lines])
            for d in 1:D
                for l in risky_lines[d]
                    if l in hardenable_set && z_fixed[(d, l)] == 0 && value(y_model[l]) >= 0.5
                        results[:z][(d, l)] = 1.0  # Hardened → effectively energized
                    else
                        results[:z][(d, l)] = z_fixed[(d, l)]
                    end
                end
            end
        else
            for d in 1:D
                for l in risky_lines[d]
                    results[:z][(d, l)] = z_fixed[(d, l)]
                end
            end
        end
    end

    # Extract hardening decisions if enabled (y is always a model variable when hardening enabled)
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]
        line_lengths = preprocessed[:line_lengths]
        cost_per_mile = opt_parameters[:hardening_cost_per_mile]
        effectiveness = opt_parameters[:hardening_effectiveness]

        results[:y] = Dict{Int,Float64}()
        y = model[:y]
        for l in hardenable_lines
            results[:y][l] = value(y[l])
        end

        # List of hardened lines (y >= 0.5)
        results[:hardened_lines] = [l for l in hardenable_lines if results[:y][l] >= 0.5]
        results[:hardening_type] = "Undergrounded"

        # Calculate total hardening cost
        results[:hardening_cost] = sum(cost_per_mile * line_lengths[l] * results[:y][l] for l in hardenable_lines)

        # Calculate risk mitigated by hardening
        # This is the risk removed from hardened lines (effectiveness * y[l] * risk)
        mitigated_risk = 0.0
        hardenable_set = Set(hardenable_lines)
        for d in 1:D
            for l in risky_lines[d]
                if l in hardenable_set
                    # Risk mitigated = effectiveness * y[l] * z[d,l] * risk[d,l]
                    # (only counts if line is energized)
                    mitigated_risk += effectiveness * results[:y][l] * results[:z][(d, l)] * wf_data[d][l]
                end
            end
        end
        results[:mitigated_risk] = mitigated_risk
    end

    # Extract battery decisions if enabled
    if get(opt_parameters, :battery_enabled, false)
        results[:battery_enabled] = true
        battery_locs = preprocessed[:battery_locs]
        cost_per_pu = opt_parameters[:battery_cost_per_pu]
        model_type = opt_parameters[:model]

        # Extract battery capacity (x)
        x = model[:x]
        results[:x] = Dict{Int,Float64}()
        for i in battery_locs
            results[:x][i] = value(x[i])
        end

        # Extract battery state of charge (soc)
        soc = model[:soc]
        results[:soc] = Dict{Tuple,Float64}()
        for d in 1:D, t in 0:T, i in battery_locs
            results[:soc][(d, t, i)] = value(soc[d, t, i])
        end

        # Extract battery active power charge (p_charge)
        p_charge = model[:p_charge]
        results[:p_charge] = Dict{Tuple,Float64}()
        for d in 1:D, t in 1:T, i in battery_locs
            results[:p_charge][(d, t, i)] = value(p_charge[d, t, i])
        end

        # Extract battery active power discharge (p_discharge)
        p_discharge = model[:p_discharge]
        results[:p_discharge] = Dict{Tuple,Float64}()
        for d in 1:D, t in 1:T, i in battery_locs
            results[:p_discharge][(d, t, i)] = value(p_discharge[d, t, i])
        end

        # Extract reactive power variables (LACOTS only)
        if model_type == "LACOTS"
            # Extract battery reactive power charge (q_charge)
            q_charge = model[:q_charge]
            results[:q_charge] = Dict{Tuple,Float64}()
            for d in 1:D, t in 1:T, i in battery_locs
                results[:q_charge][(d, t, i)] = value(q_charge[d, t, i])
            end

            # Extract battery reactive power discharge (q_discharge)
            q_discharge = model[:q_discharge]
            results[:q_discharge] = Dict{Tuple,Float64}()
            for d in 1:D, t in 1:T, i in battery_locs
                results[:q_discharge][(d, t, i)] = value(q_discharge[d, t, i])
            end
        end

        # Store battery capacity for easy access
        results[:battery_capacity] = results[:x]

        # List of buses with installed batteries (capacity >= 0.01 p.u. = 1 MWh)
        results[:batteries_installed] = [i for i in battery_locs if results[:x][i] >= 0.01]

        # Calculate total battery capacity
        results[:total_battery_capacity] = sum(results[:x][i] for i in battery_locs)

        # Calculate total battery cost
        results[:battery_cost] = sum(cost_per_pu * results[:x][i] for i in battery_locs)
    end

    # Extract solar decisions if enabled
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        cost_per_pu = opt_parameters[:solar_cost_per_pu]

        # Extract solar capacity (s)
        s = model[:s]
        results[:s] = Dict{Int,Float64}()
        for n in solar_locs
            results[:s][n] = value(s[n])
        end

        # Extract solar generation (p_solar)
        p_solar = model[:p_solar]
        results[:p_solar] = Dict{Tuple,Float64}()
        for d in 1:D, t in 1:T, n in solar_locs
            results[:p_solar][(d, t, n)] = value(p_solar[d, t, n])
        end

        # Extract solar reactive power (LACOTS only)
        if model_type == "LACOTS"
            q_solar = model[:q_solar]
            results[:q_solar] = Dict{Tuple,Float64}()
            for d in 1:D, t in 1:T, n in solar_locs
                results[:q_solar][(d, t, n)] = value(q_solar[d, t, n])
            end
            results[:total_solar_q_injection] = sum(results[:q_solar][(d, t, n)]
                                                    for d in 1:D, t in 1:T, n in solar_locs)
        end

        # Aggregate solar results
        results[:solar_capacity] = results[:s]
        results[:solar_installed] = [n for n in solar_locs if results[:s][n] >= 0.01]
        results[:total_solar_capacity] = sum(results[:s][n] for n in solar_locs)
        results[:solar_cost] = sum(cost_per_pu * results[:s][n] for n in solar_locs)

        # Total solar energy generated across all days and hours (p.u. * hours = p.u.·h)
        results[:total_solar_generation] = sum(results[:p_solar][(d, t, n)]
                                               for d in 1:D, t in 1:T, n in solar_locs)
    end

    # Extract voltage angles
    va = model[:va]
    results[:va] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        results[:va][d, t, i] = value(va[d, t, i])
    end

    # Extract power flows
    p = model[:p]
    results[:p] = Dict{Tuple,Float64}()
    for d in 1:D, t in 1:T, (l, i, j) in branch_names
        results[:p][(d, t, (l, i, j))] = value(p[d, t, (l, i, j)])
    end

    if model_type == "DCOTS"
        # DCOTS-specific results
        load_shedding = model[:load_shedding]
        g = model[:g]

        results[:load_shedding] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
        for d in 1:D, t in 1:T, i in bus_names
            results[:load_shedding][d, t, i] = value(load_shedding[d, t, i])
        end

        results[:g] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
        for d in 1:D, t in 1:T, i in gen_names
            results[:g][d, t, i] = value(g[d, t, i])
        end

        # Calculate aggregate metrics
        results[:total_load_shed] = sum(results[:load_shedding])

    else  # LACOTS
        # LACOTS-specific results
        p_load_shedding = model[:p_load_shedding]
        q_load_shedding = model[:q_load_shedding]
        pg = model[:pg]
        qg = model[:qg]
        vm = model[:vm]
        q = model[:q]

        results[:p_load_shedding] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
        results[:q_load_shedding] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
        for d in 1:D, t in 1:T, i in bus_names
            results[:p_load_shedding][d, t, i] = value(p_load_shedding[d, t, i])
            results[:q_load_shedding][d, t, i] = value(q_load_shedding[d, t, i])
        end

        results[:pg] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
        results[:qg] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
        for d in 1:D, t in 1:T, i in gen_names
            results[:pg][d, t, i] = value(pg[d, t, i])
            results[:qg][d, t, i] = value(qg[d, t, i])
        end

        results[:vm] = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
        for d in 1:D, t in 1:T, i in bus_names
            results[:vm][d, t, i] = value(vm[d, t, i])
        end

        results[:q] = Dict{Tuple,Float64}()
        for d in 1:D, t in 1:T, (l, i, j) in branch_names
            results[:q][(d, t, (l, i, j))] = value(q[d, t, (l, i, j)])
        end

        # Calculate aggregate metrics
        results[:total_p_load_shed] = sum(results[:p_load_shedding])
        results[:total_q_load_shed] = sum(results[:q_load_shedding])
        results[:total_load_shed] = results[:total_p_load_shed]  # For consistency
    end

    # Calculate risk metrics
    # Total risk is sum of all risk values across all days
    total_risk = sum(sum(values(wf_data[d])) for d in 1:D)

    # Active risk is risk from energized lines (z=1 means energized)
    # If hardening is enabled, reduce risk by effectiveness factor for hardened lines
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]
        effectiveness = opt_parameters[:hardening_effectiveness]
        hardenable_set = Set(hardenable_lines)

        active_risk = 0.0
        for d in 1:D
            for l in risky_lines[d]
                z_val = results[:z][(d, l)]
                y_val = l in hardenable_set ? results[:y][l] : 0.0
                # Risk = z[d,l] * risk[d,l] * (1 - effectiveness * y[l])
                active_risk += z_val * wf_data[d][l] * (1 - effectiveness * y_val)
            end
        end
    else
        # Standard active risk without hardening
        active_risk = sum(results[:z][(d, l)] * wf_data[d][l] for d in 1:D for l in risky_lines[d]; init=0.0)
    end

    removed_risk = total_risk - active_risk

    results[:total_risk] = total_risk
    results[:active_risk] = active_risk
    results[:removed_risk] = removed_risk
    results[:risk_reduction_pct] = (removed_risk / total_risk) * 100

    # Lines that were switched off (per day)
    # Uses results[:z] which already accounts for hardened lines being re-energized.
    switched_off = Dict{Int,Vector{Int}}()
    for d in 1:D
        switched_off[d] = [l for l in risky_lines[d] if results[:z][(d, l)] < 0.5]
    end
    results[:switched_off_lines] = switched_off
    results[:switching_method] = switching_method

    println("Optimization complete!")
    println("Status: $(results[:status])")
    println("Objective value: $(results[:objective_value])")
    println("Total load shed: $(results[:total_load_shed])")
    println("Risk reduction: $(round(results[:risk_reduction_pct], digits=2))%")

    return results
end
