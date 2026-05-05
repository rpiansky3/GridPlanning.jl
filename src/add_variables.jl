"""
Add optimization variables to the JuMP model for DCOTS and LACOTS formulations.
"""

"""
    add_variables!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict) -> Dict

Add all optimization variables to the model based on model type (DCOTS or LACOTS).
Returns a dictionary of expression mappings for power flows.
"""
function add_variables!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict)
    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    wf_data = opt_parameters[:wildfire_data]
    model_type = opt_parameters[:model]
    warm_start = opt_parameters[:warm_start]

    # Get names
    bus_names = sort([bus for bus in keys(ref[:bus])])
    branch_names = sort([branch for branch in ref[:arcs_from]])
    gen_names = sort([gen for gen in keys(ref[:gen])])

    # Extract per-day risky lines from wildfire data
    # wf_data is Dict{Int, Dict{Int, Float64}} indexed by day
    risky_lines = Dict{Int,Vector{Int}}()
    for d in 1:D
        risky_lines[d] = sort(collect(keys(wf_data[d])))
    end

    # Calculate big M for voltage angle bounds
    big_M = calculate_big_m(ref, branch_names, bus_names)

    # Store in model for later use
    model[:metadata] = Dict(
        :bus_names => bus_names,
        :branch_names => branch_names,
        :gen_names => gen_names,
        :risky_lines => risky_lines,
        :big_M => big_M
    )

    if model_type == "DCOTS"
        return add_dcots_variables!(model, preprocessed, opt_parameters, bus_names, branch_names, gen_names, risky_lines, big_M)
    else  # LACOTS
        return add_lacots_variables!(model, preprocessed, opt_parameters, bus_names, branch_names, gen_names, risky_lines, big_M)
    end
end

"""
    branch_rate_a(branch::Dict) -> Float64

Return the thermal limit (rate_a) for a branch. Preprocessing guarantees this key is
always set via tighten_branch_limits!, so this is a direct accessor.
"""
function branch_rate_a(branch::Dict)
    return branch["rate_a"]
end

"""
    calculate_big_m(ref::Dict, branch_names, bus_names) -> Float64

Calculate big M value for voltage angle constraints.
"""
function calculate_big_m(ref::Dict, branch_names, bus_names)
    all_ang_maxs = Float64[]
    for (l, i, j) in branch_names
        g1, b1 = PowerModels.calc_branch_y(ref[:branch][l])
        p_temp = branch_rate_a(ref[:branch][l])
        ad_temp = abs(p_temp / b1)
        push!(all_ang_maxs, minimum([ref[:branch][l]["angmax"], ad_temp]))
    end
    num_buses = length(bus_names)
    biggest_vals = partialsort!(all_ang_maxs, 1:min(num_buses, length(all_ang_maxs)), rev=true)
    return sum(biggest_vals)
end

"""
    add_dcots_variables!(model, preprocessed, opt_parameters, bus_names, branch_names, gen_names, risky_lines, big_M) -> Dict

Add DCOTS-specific variables (DC power flow, no reactive power).
"""
function add_dcots_variables!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                               bus_names, branch_names, gen_names, risky_lines, big_M)
    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    hourly_loads = preprocessed[:hourly_loads]
    is_cats = preprocessed[:is_cats]

    # Load shedding variables
    ls_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    ls_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)

    for d in 1:D
        for t in 1:T
            for i in bus_names
                ls_lb[d, t, i] = 0.0
                if is_cats
                    # For CATS, loads are embedded in hourly refs
                    hourly_ref = preprocessed[:hourly_refs][d][t]
                    sum_of_loads = reduce(+, hourly_ref[:load][j]["pd"] for j in hourly_ref[:bus_loads][i]; init=0.0)
                    ls_ub[d, t, i] = max(0.0, sum_of_loads)
                else
                    ls_ub[d, t, i] = hourly_loads[d]["pd"][i][t]
                end
            end
        end
    end
    @variable(model, ls_lb[d, t, i] <= load_shedding[d=1:D, t=1:T, i=bus_names] <= ls_ub[d, t, i])

    # Voltage angles
    va_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    va_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        va_lb[d, t, i] = -big_M
        va_ub[d, t, i] = big_M
    end
    @variable(model, va_lb[d, t, i] <= va[d=1:D, t=1:T, i=bus_names] <= va_ub[d, t, i])

    # Power generation
    g_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    g_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    for d in 1:D
        for t in 1:T
            for i in gen_names
                g_lb[d, t, i] = 0.0
                if is_cats
                    hourly_ref = preprocessed[:hourly_refs][d][t]
                    g_ub[d, t, i] = hourly_ref[:gen][i]["pmax"]
                else
                    g_ub[d, t, i] = ref[:gen][i]["pmax"]
                end
            end
        end
    end
    @variable(model, g_lb[d, t, i] <= g[d=1:D, t=1:T, i=gen_names] <= g_ub[d, t, i])

    # Power flows
    p_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    p_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    for d in 1:D, t in 1:T, (l, i, j) in branch_names
        rate_a = branch_rate_a(ref[:branch][l])
        p_lb[d, t, (l, i, j)] = -rate_a
        p_ub[d, t, (l, i, j)] = rate_a
    end
    @variable(model, p_lb[d, t, branch] <= p[d=1:D, t=1:T, branch=branch_names] <= p_ub[d, t, branch])

    # Binary switching variables (one per day per risky line for that day)
    # For "optimal" and "constrained" methods: create decision variables
    # For "thresholded" method: use fixed parameters (no variables)
    switching_method = get(opt_parameters, :switching_method, "optimal")

    if switching_method == "optimal"
        # Create index set for (d, l) pairs where l is risky on day d
        z_indices = [(d, l) for d in 1:D for l in risky_lines[d]]
        @variable(model, z[idx in z_indices], Bin)

        # Apply warm start if provided
        if opt_parameters[:warm_start] !== nothing && opt_parameters[:warm_start] != "auto"
            warm_start_vals = opt_parameters[:warm_start]
            for d in 1:D
                for l in risky_lines[d]
                    if haskey(warm_start_vals, l)
                        set_start_value(z[(d, l)], warm_start_vals[l])
                    end
                end
            end
        end
    else  # "thresholded"
        # Fixed line statuses are passed in opt_parameters[:z_fixed]
        # No variables needed - constraints will use fixed values directly
    end

    # Binary hardening variables (one per hardenable line, NOT indexed by day)
    # Hardening is always solved optimally regardless of switching method.
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]

        @variable(model, y[l in hardenable_lines], Bin)

        # Apply warm start if provided (for optimal/constrained methods)
        if switching_method == "optimal" &&
                opt_parameters[:warm_start] !== nothing && opt_parameters[:warm_start] != "auto"
            warm_start_vals = opt_parameters[:warm_start]
            if haskey(warm_start_vals, "y")
                for l in hardenable_lines
                    if haskey(warm_start_vals["y"], l)
                        set_start_value(y[l], warm_start_vals["y"][l])
                    end
                end
            end
        end

        println("✓ Added hardening variables for $(length(hardenable_lines)) lines")
    end

    # Battery variables (continuous capacity planning)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        max_per_node = opt_parameters[:battery_max_per_node]

        # Use default cap of 10000 p.u. for numerical stability if not specified
        capacity_ub = max_per_node === nothing ? 10000.0 : max_per_node

        # Battery capacity variable (continuous, in p.u. where 1 p.u. = 100 MWh)
        @variable(model, 0 <= x[i in battery_locs] <= capacity_ub)

        # State of charge (SOC) - includes t=0 for initial condition
        # Upper bound will be constrained to x[i] in constraints
        @variable(model, 0 <= soc[d=1:D, t=0:T, i=battery_locs] <= capacity_ub)

        # Charge power (active power absorbed from grid)
        c_rate = opt_parameters[:battery_charge_rate]
        @variable(model, 0 <= p_charge[d=1:D, t=1:T, i=battery_locs] <= c_rate * capacity_ub)

        # Discharge power (active power injected to grid)
        d_rate = opt_parameters[:battery_discharge_rate]
        @variable(model, 0 <= p_discharge[d=1:D, t=1:T, i=battery_locs] <= d_rate * capacity_ub)

        println("✓ Added battery variables for $(length(battery_locs)) candidate buses")
    end

    # Solar variables (continuous capacity planning, active power generation)
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        max_per_node = opt_parameters[:solar_max_per_node]

        # Use default cap of 10000 p.u. for numerical stability if not specified
        capacity_ub = max_per_node === nothing ? 10000.0 : max_per_node

        # Solar capacity variable (continuous, in p.u. where 1 p.u. = 100 MW)
        @variable(model, 0 <= s[n in solar_locs] <= capacity_ub)

        # Solar generation variable (curtailable generation, bounded by capacity factor)
        @variable(model, 0 <= p_solar[d=1:D, t=1:T, n=solar_locs] <= capacity_ub)

        println("✓ Added solar variables for $(length(solar_locs)) candidate buses")
    end

    # Create power flow expressions for both directions
    p_expr = Dict((d, t, (l, i, j)) => 1.0 * p[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names)
    p_expr = merge(p_expr, Dict((d, t, (l, j, i)) => -1.0 * p[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names))

    return Dict(:p_expr => p_expr)
end

"""
    add_lacots_variables!(model, preprocessed, opt_parameters, bus_names, branch_names, gen_names, risky_lines, big_M) -> Dict

Add LACOTS-specific variables (Linear AC power flow with reactive power).
"""
function add_lacots_variables!(model::JuMP.Model, preprocessed::Dict, opt_parameters::Dict,
                                bus_names, branch_names, gen_names, risky_lines, big_M)
    D = preprocessed[:D]
    T = preprocessed[:T]
    ref = preprocessed[:base_ref]
    hourly_loads = preprocessed[:hourly_loads]
    is_cats = preprocessed[:is_cats]

    # Active load shedding
    pls_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    pls_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        pls_lb[d, t, i] = 0.0
        if is_cats
            hourly_ref = preprocessed[:hourly_refs][d][t]
            sum_of_loads = reduce(+, hourly_ref[:load][j]["pd"] for j in hourly_ref[:bus_loads][i]; init=0.0)
            pls_ub[d, t, i] = max(0.0, sum_of_loads)
        else
            pls_ub[d, t, i] = hourly_loads[d]["pd"][i][t]
        end
    end
    @variable(model, pls_lb[d, t, i] <= p_load_shedding[d=1:D, t=1:T, i=bus_names] <= pls_ub[d, t, i])

    # Reactive load shedding
    qls_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    qls_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        qls_lb[d, t, i] = 0.0
        if is_cats
            hourly_ref = preprocessed[:hourly_refs][d][t]
            sum_of_loads = reduce(+, hourly_ref[:load][j]["qd"] for j in hourly_ref[:bus_loads][i]; init=0.0)
            qls_ub[d, t, i] = max(0.0, sum_of_loads)
        else
            qls_ub[d, t, i] = hourly_loads[d]["qd"][i][t]
        end
    end
    @variable(model, qls_lb[d, t, i] <= q_load_shedding[d=1:D, t=1:T, i=bus_names] <= qls_ub[d, t, i])

    # Voltage angles
    va_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    va_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        va_lb[d, t, i] = -big_M
        va_ub[d, t, i] = big_M
    end
    @variable(model, va_lb[d, t, i] <= va[d=1:D, t=1:T, i=bus_names] <= va_ub[d, t, i])

    # Voltage magnitudes
    vm_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    vm_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, bus_names)
    for d in 1:D, t in 1:T, i in bus_names
        vm_lb[d, t, i] = ref[:bus][i]["vmin"]
        vm_ub[d, t, i] = ref[:bus][i]["vmax"]
    end
    @variable(model, vm_lb[d, t, i] <= vm[d=1:D, t=1:T, i=bus_names] <= vm_ub[d, t, i])

    # Active power generation
    pg_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    pg_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    for d in 1:D, t in 1:T, i in gen_names
        pg_lb[d, t, i] = 0.0
        if is_cats
            hourly_ref = preprocessed[:hourly_refs][d][t]
            pg_ub[d, t, i] = hourly_ref[:gen][i]["pmax"]
        else
            pg_ub[d, t, i] = ref[:gen][i]["pmax"]
        end
    end
    @variable(model, pg_lb[d, t, i] <= pg[d=1:D, t=1:T, i=gen_names] <= pg_ub[d, t, i])

    # Reactive power generation
    qg_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    qg_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, gen_names)
    for d in 1:D, t in 1:T, i in gen_names
        qg_lb[d, t, i] = 0.0
        qg_ub[d, t, i] = ref[:gen][i]["qmax"]
    end
    @variable(model, qg_lb[d, t, i] <= qg[d=1:D, t=1:T, i=gen_names] <= qg_ub[d, t, i])

    # Active power flows
    p_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    p_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    for d in 1:D, t in 1:T, (l, i, j) in branch_names
        rate_a = branch_rate_a(ref[:branch][l])
        p_lb[d, t, (l, i, j)] = -rate_a
        p_ub[d, t, (l, i, j)] = rate_a
    end
    @variable(model, p_lb[d, t, branch] <= p[d=1:D, t=1:T, branch=branch_names] <= p_ub[d, t, branch])

    # Reactive power flows
    q_lb = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    q_ub = Containers.DenseAxisArray{Float64}(undef, 1:D, 1:T, branch_names)
    for d in 1:D, t in 1:T, (l, i, j) in branch_names
        rate_a = branch_rate_a(ref[:branch][l])
        q_lb[d, t, (l, i, j)] = -rate_a
        q_ub[d, t, (l, i, j)] = rate_a
    end
    @variable(model, q_lb[d, t, branch] <= q[d=1:D, t=1:T, branch=branch_names] <= q_ub[d, t, branch])

    # Binary switching variables (one per day per risky line for that day)
    # For "optimal" and "constrained" methods: create decision variables
    # For "thresholded" method: use fixed parameters (no variables)
    switching_method = get(opt_parameters, :switching_method, "optimal")

    if switching_method == "optimal"
        z_indices = [(d, l) for d in 1:D for l in risky_lines[d]]
        @variable(model, z[idx in z_indices], Bin)

        # Apply warm start if provided
        if opt_parameters[:warm_start] !== nothing && opt_parameters[:warm_start] != "auto"
            warm_start_vals = opt_parameters[:warm_start]
            for d in 1:D
                for l in risky_lines[d]
                    if haskey(warm_start_vals, l)
                        set_start_value(z[(d, l)], warm_start_vals[l])
                    end
                end
            end
        end
    else  # "thresholded"
        # Fixed line statuses are passed in opt_parameters[:z_fixed]
        # No variables needed - constraints will use fixed values directly
    end

    # Binary hardening variables (one per hardenable line, NOT indexed by day)
    # Hardening is always solved optimally regardless of switching method.
    if get(opt_parameters, :hardening_enabled, false)
        hardenable_lines = opt_parameters[:hardenable_lines]

        @variable(model, y[l in hardenable_lines], Bin)

        # Apply warm start if provided (for optimal/constrained methods)
        if switching_method == "optimal" &&
                opt_parameters[:warm_start] !== nothing && opt_parameters[:warm_start] != "auto"
            warm_start_vals = opt_parameters[:warm_start]
            if haskey(warm_start_vals, "y")
                for l in hardenable_lines
                    if haskey(warm_start_vals["y"], l)
                        set_start_value(y[l], warm_start_vals["y"][l])
                    end
                end
            end
        end

        println("✓ Added hardening variables for $(length(hardenable_lines)) lines")
    end

    # Battery variables (continuous capacity planning with reactive power support)
    if get(opt_parameters, :battery_enabled, false)
        battery_locs = preprocessed[:battery_locs]
        max_per_node = opt_parameters[:battery_max_per_node]
        c_rate = opt_parameters[:battery_charge_rate]
        d_rate = opt_parameters[:battery_discharge_rate]

        # Use default cap of 10000 p.u. for numerical stability if not specified
        capacity_ub = max_per_node === nothing ? 10000.0 : max_per_node

        # Battery capacity variable (continuous, in p.u. where 1 p.u. = 100 MWh)
        @variable(model, 0 <= x[i in battery_locs] <= capacity_ub)

        # State of charge (SOC) - includes t=0 for initial condition
        # Upper bound will be constrained to x[i] in constraints
        @variable(model, 0 <= soc[d=1:D, t=0:T, i=battery_locs] <= capacity_ub)

        # Active power charge (absorbed from grid)
        @variable(model, 0 <= p_charge[d=1:D, t=1:T, i=battery_locs] <= c_rate * capacity_ub)

        # Active power discharge (injected to grid)
        @variable(model, 0 <= p_discharge[d=1:D, t=1:T, i=battery_locs] <= d_rate * capacity_ub)

        # Reactive power charge (absorbed from grid)
        @variable(model, 0 <= q_charge[d=1:D, t=1:T, i=battery_locs] <= c_rate * capacity_ub)

        # Reactive power discharge (injected to grid)
        @variable(model, 0 <= q_discharge[d=1:D, t=1:T, i=battery_locs] <= d_rate * capacity_ub)

        println("✓ Added battery variables for $(length(battery_locs)) candidate buses (active and reactive power)")
    end

    # Solar variables (active and reactive power for LACOTS)
    if get(opt_parameters, :solar_enabled, false)
        solar_locs = preprocessed[:solar_locs]
        max_per_node = opt_parameters[:solar_max_per_node]

        capacity_ub = max_per_node === nothing ? 10000.0 : max_per_node

        @variable(model, 0 <= s[n in solar_locs] <= capacity_ub)
        @variable(model, 0 <= p_solar[d=1:D, t=1:T, n=solar_locs] <= capacity_ub)

        # Reactive power from solar inverter (bidirectional: injection and absorption)
        @variable(model, -capacity_ub <= q_solar[d=1:D, t=1:T, n=solar_locs] <= capacity_ub)

        println("✓ Added solar variables for $(length(solar_locs)) candidate buses (active and reactive power)")
    end

    # Create power flow expressions for both directions
    p_expr = Dict((d, t, (l, i, j)) => 1.0 * p[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names)
    p_expr = merge(p_expr, Dict((d, t, (l, j, i)) => -1.0 * p[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names))

    q_expr = Dict((d, t, (l, i, j)) => 1.0 * q[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names)
    q_expr = merge(q_expr, Dict((d, t, (l, j, i)) => -1.0 * q[d, t, (l, i, j)] for d in 1:D for t in 1:T for (l, i, j) in branch_names))

    return Dict(:p_expr => p_expr, :q_expr => q_expr)
end
