"""
Save and format optimization results for output.
"""

"""
    format_output(results::Dict, opt_parameters::Dict) -> Any

Format results based on output_format parameter.
Returns Dict, saves to JLD2, or saves formatted txt.
"""
function format_output(results::Dict, opt_parameters::Dict)
    output_format = opt_parameters[:output_format]
    output_path = opt_parameters[:output_path]

    if output_format == "dict"
        return results
    elseif output_format == "jld2"
        save_jld2(results, output_path)
        println("Results saved to: $output_path")
        return results
    elseif output_format == "txt"
        save_txt(results, output_path, opt_parameters)
        println("Results saved to: $output_path")
        return results
    else
        error("Unknown output format: $output_format")
    end
end

"""
    save_jld2(results::Dict, filepath::String)

Save results to JLD2 file.
"""
function save_jld2(results::Dict, filepath::String)
    # Ensure directory exists
    dir = dirname(filepath)
    if !isempty(dir) && !isdir(dir)
        mkpath(dir)
    end

    # Convert DenseAxisArrays to regular arrays for JLD2 compatibility
    results_to_save = convert_for_jld2(results)

    JLD2.@save filepath results_to_save
end

"""
    convert_for_jld2(results::Dict) -> Dict

Convert JuMP containers to standard Julia types for JLD2 serialization.
"""
function convert_for_jld2(results::Dict)
    converted = Dict{Symbol,Any}()

    for (key, val) in results
        if val isa Containers.DenseAxisArray
            # Convert to regular Dict with tuple keys
            # Manually iterate over all axes instead of using pairs()
            result_dict = Dict{Any,Any}()
            axes_ranges = [ax for ax in axes(val)]

            # Generate all index combinations
            for idx in Iterators.product(axes_ranges...)
                result_dict[idx] = val[idx...]
            end

            converted[key] = result_dict
        elseif val isa Dict
            # Already a dict, keep as is
            converted[key] = val
        else
            converted[key] = val
        end
    end

    return converted
end

"""
    load_txt(filepath::String) -> Dict

Load results from a text file saved by save_txt.
Returns a dictionary containing all variable data.
"""
function load_txt(filepath::String)
    if !isfile(filepath)
        error("File not found: $filepath")
    end

    results = Dict{Symbol, Any}()
    current_var = nothing
    current_data = Dict{Any, Any}()

    open(filepath, "r") do io
        for line in eachline(io)
            line = strip(line)

            # Skip empty lines and comments
            if isempty(line) || startswith(line, "#") || startswith(line, "=")
                continue
            end

            # Check for variable section headers
            if startswith(line, "[") && endswith(line, "]")
                # Save previous variable if exists
                if current_var !== nothing && !isempty(current_data)
                    results[current_var] = current_data
                    current_data = Dict{Any, Any}()
                end

                # Extract variable name (everything between [ and first space or ])
                var_match = match(r"\[(\w+)", line)
                if var_match !== nothing
                    current_var = Symbol(var_match.captures[1])
                end
                continue
            end

            # Parse variable data lines (format: "key => value" or "(idx1, idx2, ...) => value")
            if current_var !== nothing && contains(line, "=>")
                parts = split(line, "=>", limit=2)
                if length(parts) == 2
                    key_str = strip(parts[1])
                    value_str = strip(parts[2])

                    # Parse the key
                    if startswith(key_str, "(") && endswith(key_str, ")")
                        # Tuple key: parse each element
                        key_str_inner = key_str[2:end-1]  # Remove parentheses
                        key_parts = split(key_str_inner, ",")

                        # Try to parse as numbers, keep as string if fails
                        key_tuple = []
                        for part in key_parts
                            part = strip(part)
                            # Try integer first
                            try
                                push!(key_tuple, parse(Int, part))
                            catch
                                # Try float
                                try
                                    push!(key_tuple, parse(Float64, part))
                                catch
                                    # Keep as string (e.g., for tuple like (105, 315, 321))
                                    push!(key_tuple, part)
                                end
                            end
                        end
                        key = Tuple(key_tuple)
                    else
                        # Simple key: try to parse as number
                        try
                            key = parse(Int, key_str)
                        catch
                            try
                                key = parse(Float64, key_str)
                            catch
                                key = key_str
                            end
                        end
                    end

                    # Parse the value
                    try
                        value = parse(Float64, value_str)
                    catch
                        value = value_str
                    end

                    current_data[key] = value
                end
            end
        end

        # Save last variable
        if current_var !== nothing && !isempty(current_data)
            results[current_var] = current_data
        end
    end

    return results
end

"""
    save_txt(results::Dict, filepath::String, opt_parameters::Dict)

Save formatted results to text file with full variable data.
"""
function save_txt(results::Dict, filepath::String, opt_parameters::Dict)
    # Ensure directory exists
    dir = dirname(filepath)
    if !isempty(dir) && !isdir(dir)
        mkpath(dir)
    end

    open(filepath, "w") do io
        # Write summary sections
        write_header(io, results, opt_parameters)
        write_summary(io, results)
        write_switching_decisions(io, results)
        write_load_shedding_summary(io, results)
        write_risk_summary(io, results)
        write_hardening_summary(io, results, opt_parameters)
        write_battery_summary(io, results, opt_parameters)
        write_solar_summary(io, results, opt_parameters)

        # Write detailed variable data
        write_all_variables(io, results)
    end
end

"""
    write_header(io, results, opt_parameters)

Write header information to text file.
"""
function write_header(io::IO, results::Dict, opt_parameters::Dict)
    println(io, "=" ^ 80)
    println(io, "WILDFIRE SWITCHING OPTIMIZATION RESULTS")
    println(io, "=" ^ 80)
    println(io)

    println(io, "Configuration:")
    println(io, "-" ^ 40)
    @printf(io, "  Network:          %s\n", opt_parameters[:network])
    @printf(io, "  Model Type:       %s\n", results[:model_type])
    @printf(io, "  Objective:        %s\n", opt_parameters[:objective])
    @printf(io, "  Method:           %s\n", results[:switching_method])
    @printf(io, "  Days (D):         %d\n", results[:D])
    @printf(io, "  Hours per Day:    %d\n", results[:T])
    @printf(io, "  Time Limit:       %.1f seconds\n", opt_parameters[:time_limit])
    @printf(io, "  MIP Gap:          %.2f%%\n", opt_parameters[:mip_gap] * 100)

    # Hardening configuration
    if get(opt_parameters, :hardening_enabled, false)
        println(io, "\n  Hardening Enabled:")
        @printf(io, "    Effectiveness:     %.2f\n", opt_parameters[:hardening_effectiveness])
        @printf(io, "    Cost per Mile:     \$%.2fM\n", opt_parameters[:hardening_cost_per_mile] / 1e6)
        budget = get(opt_parameters, :infrastructure_budget, Inf)
        if budget < Inf
            @printf(io, "    Infra Budget:      \$%.2fM (shared)\n", budget / 1e6)
        else
            println(io, "    Infra Budget:      Unlimited")
        end
        @printf(io, "    Enforce Energize:  %s\n", opt_parameters[:hardening_enforce_energization])
    end

    # Battery configuration
    if get(opt_parameters, :battery_enabled, false)
        println(io, "\n  Battery Planning Enabled:")
        @printf(io, "    Cost per p.u.:     \$%.2fM\n", opt_parameters[:battery_cost_per_pu] / 1e6)
        @printf(io, "    Charge Eff.:       %.2f\n", opt_parameters[:battery_charge_efficiency])
        @printf(io, "    Discharge Eff.:    %.2f\n", opt_parameters[:battery_discharge_efficiency])
        @printf(io, "    Charge Rate:       %.2f p.u./hr\n", opt_parameters[:battery_charge_rate])
        @printf(io, "    Discharge Rate:    %.2f p.u./hr\n", opt_parameters[:battery_discharge_rate])
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            @printf(io, "    Budget:            \$%.2fM (shared)\n", budget / 1e6)
        else
            println(io, "    Budget:            Unlimited")
        end
    end

    # Solar configuration
    if get(opt_parameters, :solar_enabled, false)
        println(io, "\n  Solar Planning Enabled:")
        @printf(io, "    Cost per p.u.:     \$%.2fM\n", opt_parameters[:solar_cost_per_pu] / 1e6)
        @printf(io, "    Default CF:        %.2f\n", opt_parameters[:solar_capacity_factor_default])
        data_path = get(opt_parameters, :solar_data_path, nothing)
        if data_path !== nothing
            println(io, "    Data Path:         $data_path")
        else
            println(io, "    Data Path:         none (flat default CF)")
        end
        budget = opt_parameters[:infrastructure_budget]
        if budget < Inf
            @printf(io, "    Budget:            \$%.2fM (shared)\n", budget / 1e6)
        else
            println(io, "    Budget:            Unlimited")
        end
    end
    println(io)

    # Print date range
    times = results[:times]
    if length(times) > 0
        start_date = times[1]
        end_date = times[end]
        @printf(io, "  Date Range:       %04d-%02d-%02d to %04d-%02d-%02d\n",
                start_date[1], start_date[2], start_date[3],
                end_date[1], end_date[2], end_date[3])
    end
    println(io)
end

"""
    write_summary(io, results)

Write optimization summary to text file.
"""
function write_summary(io::IO, results::Dict)
    println(io, "Optimization Summary:")
    println(io, "-" ^ 40)
    @printf(io, "  Status:           %s\n", results[:status])
    @printf(io, "  Solve Time:       %.2f seconds\n", results[:solve_time])
    @printf(io, "  Objective Value:  %.6f\n", results[:objective_value])
    println(io)
end

"""
    write_switching_decisions(io, results)

Write line switching decisions to text file.
"""
function write_switching_decisions(io::IO, results::Dict)
    println(io, "Switching Decisions:")
    println(io, "-" ^ 40)

    switched_off = results[:switched_off_lines]
    for d in sort(collect(keys(switched_off)))
        lines_off = switched_off[d]
        if length(lines_off) > 0
            @printf(io, "  Day %d: %d lines switched off\n", d, length(lines_off))
            # Show first few lines
            if length(lines_off) <= 10
                @printf(io, "    Lines: %s\n", join(lines_off, ", "))
            else
                @printf(io, "    Lines: %s, ...\n", join(lines_off[1:10], ", "))
            end
        else
            @printf(io, "  Day %d: No lines switched off\n", d)
        end
    end
    println(io)
end

"""
    write_load_shedding_summary(io, results)

Write load shedding summary to text file.
"""
function write_load_shedding_summary(io::IO, results::Dict)
    println(io, "Load Shedding Summary:")
    println(io, "-" ^ 40)

    if results[:model_type] == "DCOTS"
        @printf(io, "  Total Load Shed:     %.4f MW-hours\n", results[:total_load_shed])
    else  # LACOTS
        @printf(io, "  Total P Load Shed:   %.4f MW-hours\n", results[:total_p_load_shed])
        @printf(io, "  Total Q Load Shed:   %.4f MVAr-hours\n", results[:total_q_load_shed])
    end

    # Calculate per-day statistics
    D = results[:D]
    T = results[:T]

    if results[:model_type] == "DCOTS"
        ls = results[:load_shedding]
        for d in 1:D
            day_shed = sum(ls[d, t, i] for t in 1:T for i in axes(ls, 3))
            @printf(io, "  Day %d Load Shed:     %.4f MW-hours\n", d, day_shed)
        end
    else
        pls = results[:p_load_shedding]
        for d in 1:D
            day_shed = sum(pls[d, t, i] for t in 1:T for i in axes(pls, 3))
            @printf(io, "  Day %d P Load Shed:   %.4f MW-hours\n", d, day_shed)
        end
    end
    println(io)
end

"""
    write_risk_summary(io, results)

Write wildfire risk summary to text file.
"""
function write_risk_summary(io::IO, results::Dict)
    println(io, "Wildfire Risk Summary:")
    println(io, "-" ^ 40)
    @printf(io, "  Total Possible Risk:   %.2f\n", results[:total_risk])
    @printf(io, "  Active Risk:           %.2f\n", results[:active_risk])
    @printf(io, "  Removed Risk:          %.2f\n", results[:removed_risk])
    @printf(io, "  Risk Reduction:        %.2f%%\n", results[:risk_reduction_pct])
    println(io)
end

"""
    write_hardening_summary(io, results, opt_parameters)

Write hardening summary to text file (if hardening is enabled).
"""
function write_hardening_summary(io::IO, results::Dict, opt_parameters::Dict)
    if !haskey(results, :y)
        println(io, "=" ^ 80)
        return
    end

    println(io, "Hardening Summary:")
    println(io, "-" ^ 40)
    @printf(io, "  Lines Hardened:        %d\n", length(results[:hardened_lines]))
    @printf(io, "  Hardening Cost:        \$%.2fM\n", results[:hardening_cost] / 1e6)
    @printf(io, "  Risk Mitigated:        %.2f\n", results[:mitigated_risk])

    # Show percentage of risk mitigated
    if results[:total_risk] > 0
        mitigated_pct = (results[:mitigated_risk] / results[:total_risk]) * 100
        @printf(io, "  Risk Mitigation:       %.2f%%\n", mitigated_pct)
    end

    println(io)

    # Show hardened lines
    if length(results[:hardened_lines]) > 0
        println(io, "  Hardened Lines:")
        hardened = results[:hardened_lines]
        if length(hardened) <= 20
            for l in hardened
                @printf(io, "    Line %d\n", l)
            end
        else
            # Show first 20
            for l in hardened[1:20]
                @printf(io, "    Line %d\n", l)
            end
            @printf(io, "    ... and %d more\n", length(hardened) - 20)
        end
    end
    println(io)

    println(io, "=" ^ 80)
end

"""
    write_battery_summary(io, results, opt_parameters)

Write battery summary to text file (if batteries are enabled).
"""
function write_battery_summary(io::IO, results::Dict, opt_parameters::Dict)
    if !haskey(results, :x)
        return
    end

    println(io, "Battery Summary:")
    println(io, "-" ^ 40)
    @printf(io, "  Buses with Batteries:  %d\n", length(results[:batteries_installed]))
    @printf(io, "  Total Capacity:        %.2f p.u. (%.2f MWh)\n",
            results[:total_battery_capacity], results[:total_battery_capacity] * 100)
    @printf(io, "  Battery Cost:          \$%.2fM\n", results[:battery_cost] / 1e6)

    println(io)

    # Show installed batteries
    if length(results[:batteries_installed]) > 0
        println(io, "  Installed Batteries:")
        installed = results[:batteries_installed]
        capacities = results[:battery_capacity]
        if length(installed) <= 20
            for bus_id in installed
                cap = capacities[bus_id]
                @printf(io, "    Bus %d: %.2f p.u. (%.2f MWh)\n", bus_id, cap, cap * 100)
            end
        else
            # Show first 20
            for bus_id in installed[1:20]
                cap = capacities[bus_id]
                @printf(io, "    Bus %d: %.2f p.u. (%.2f MWh)\n", bus_id, cap, cap * 100)
            end
            @printf(io, "    ... and %d more\n", length(installed) - 20)
        end
    end
    println(io)

    println(io, "=" ^ 80)
end

"""
    write_solar_summary(io, results, opt_parameters)

Write solar summary to text file (if solar is enabled).
"""
function write_solar_summary(io::IO, results::Dict, opt_parameters::Dict)
    if !haskey(results, :s)
        return
    end

    println(io, "Solar Summary:")
    println(io, "-" ^ 40)
    @printf(io, "  Buses with Solar:      %d\n", length(results[:solar_installed]))
    @printf(io, "  Total Capacity:        %.2f p.u. (%.2f MW)\n",
            results[:total_solar_capacity], results[:total_solar_capacity] * 100)
    @printf(io, "  Total Generation:      %.4f p.u.·h\n", results[:total_solar_generation])
    if haskey(results, :total_solar_q_injection)
        @printf(io, "  Total Q Injection:     %.4f p.u.·h\n", results[:total_solar_q_injection])
    end
    @printf(io, "  Solar Cost:            \$%.2fM\n", results[:solar_cost] / 1e6)

    println(io)

    if length(results[:solar_installed]) > 0
        println(io, "  Installed Solar:")
        installed = results[:solar_installed]
        capacities = results[:solar_capacity]
        if length(installed) <= 20
            for bus_id in installed
                cap = capacities[bus_id]
                @printf(io, "    Bus %d: %.2f p.u. (%.2f MW)\n", bus_id, cap, cap * 100)
            end
        else
            for bus_id in installed[1:20]
                cap = capacities[bus_id]
                @printf(io, "    Bus %d: %.2f p.u. (%.2f MW)\n", bus_id, cap, cap * 100)
            end
            @printf(io, "    ... and %d more\n", length(installed) - 20)
        end
    end
    println(io)

    println(io, "=" ^ 80)
end

"""
    write_variable_data(io, var_data, var_name)

Helper function to write variable data, handling DenseAxisArray.
"""
function write_variable_data(io::IO, var_data, var_name::String)
    try
        if var_data isa Containers.DenseAxisArray
            axes_tuple = axes(var_data)

            if length(axes_tuple) == 3
                # 3D case: (D, T, names)
                for d in axes_tuple[1]
                    for t in axes_tuple[2]
                        for name in axes_tuple[3]
                            value = var_data[d, t, name]
                            println(io, "($d, $t, $name) => $value")
                        end
                    end
                end
            elseif length(axes_tuple) == 2
                # 2D case: (D, names) or (T, names)
                for idx1 in axes_tuple[1]
                    for idx2 in axes_tuple[2]
                        value = var_data[idx1, idx2]
                        println(io, "($idx1, $idx2) => $value")
                    end
                end
            elseif length(axes_tuple) == 1
                # 1D case
                for idx in axes_tuple[1]
                    value = var_data[idx]
                    println(io, "$idx => $value")
                end
            end
        elseif var_data isa Dict
            # Handle Dict (for z variable after thresholded or saved results)
            for (key, value) in sort(collect(var_data))
                println(io, "$key => $value")
            end
        else
            println(io, "# Unsupported variable type: $(typeof(var_data))")
        end
    catch e
        println(io, "# ERROR writing $var_name: $e")
    end
end

"""
    write_all_variables(io, results)

Write all optimization variables to text file in detailed format.
"""
function write_all_variables(io::IO, results::Dict)
    println(io)
    println(io, "=" ^ 80)
    println(io, "DETAILED VARIABLE DATA")
    println(io, "=" ^ 80)
    println(io)

    model_type = results[:model_type]

    # Write switching variables (z)
    if haskey(results, :z)
        println(io, "[z - Line Switching Decisions]")
        println(io, "# Binary variables: 1 = energized, 0 = de-energized")
        write_variable_data(io, results[:z], "z")
        println(io)
    end

    # Write hardening variables (y)
    if haskey(results, :y)
        println(io, "[y - Line Hardening Decisions]")
        println(io, "# Binary variables: 1 = hardened (undergrounded), 0 = not hardened")
        write_variable_data(io, results[:y], "y")
        println(io)
    end

    # Write battery capacity (x)
    if haskey(results, :x)
        println(io, "[x - Battery Capacity (p.u., where 1 p.u. = 100 MWh)]")
        println(io, "# Continuous variables: capacity installed at each bus")
        write_variable_data(io, results[:x], "x")
        println(io)
    end

    # Write battery state of charge (soc)
    if haskey(results, :soc)
        println(io, "[soc - Battery State of Charge (p.u.)]")
        println(io, "# Format: (day, hour, bus) => SOC value")
        write_variable_data(io, results[:soc], "soc")
        println(io)
    end

    # Write battery charge power (p_charge)
    if haskey(results, :p_charge)
        println(io, "[p_charge - Battery Charging Power (p.u.)]")
        println(io, "# Power absorbed from grid")
        write_variable_data(io, results[:p_charge], "p_charge")
        println(io)
    end

    # Write battery discharge power (p_discharge)
    if haskey(results, :p_discharge)
        println(io, "[p_discharge - Battery Discharging Power (p.u.)]")
        println(io, "# Power injected to grid")
        write_variable_data(io, results[:p_discharge], "p_discharge")
        println(io)
    end

    # Write battery reactive charge power (q_charge) - LACOTS only
    if haskey(results, :q_charge)
        println(io, "[q_charge - Battery Reactive Charging Power (p.u.)]")
        println(io, "# Reactive power absorbed from grid (LACOTS only)")
        write_variable_data(io, results[:q_charge], "q_charge")
        println(io)
    end

    # Write battery reactive discharge power (q_discharge) - LACOTS only
    if haskey(results, :q_discharge)
        println(io, "[q_discharge - Battery Reactive Discharging Power (p.u.)]")
        println(io, "# Reactive power injected to grid (LACOTS only)")
        write_variable_data(io, results[:q_discharge], "q_discharge")
        println(io)
    end

    # Write solar capacity (s)
    if haskey(results, :s)
        println(io, "[s - Solar Capacity (p.u., where 1 p.u. = 100 MW)]")
        println(io, "# Continuous variables: installed solar capacity at each bus")
        write_variable_data(io, results[:s], "s")
        println(io)
    end

    # Write solar generation (p_solar)
    if haskey(results, :p_solar)
        println(io, "[p_solar - Solar Generation (p.u.)]")
        println(io, "# Format: (day, hour, bus) => generation value")
        write_variable_data(io, results[:p_solar], "p_solar")
        println(io)
    end

    # Write voltage angles (va)
    if haskey(results, :va)
        println(io, "[va - Voltage Angles (radians)]")
        write_variable_data(io, results[:va], "va")
        println(io)
    end

    if model_type == "DCOTS"
        # DCOTS variables
        if haskey(results, :load_shedding)
            println(io, "[load_shedding - Active Power Load Shedding (MW)]")
            write_variable_data(io, results[:load_shedding], "load_shedding")
            println(io)
        end

        if haskey(results, :g)
            println(io, "[g - Generator Active Power Output (MW)]")
            write_variable_data(io, results[:g], "g")
            println(io)
        end

        if haskey(results, :p)
            println(io, "[p - Branch Active Power Flow (MW)]")
            write_variable_data(io, results[:p], "p")
            println(io)
        end

    else  # LACOTS
        # Voltage magnitudes
        if haskey(results, :vm)
            println(io, "[vm - Voltage Magnitudes (p.u.)]")
            write_variable_data(io, results[:vm], "vm")
            println(io)
        end

        # Load shedding
        if haskey(results, :p_load_shedding)
            println(io, "[p_load_shedding - Active Power Load Shedding (MW)]")
            write_variable_data(io, results[:p_load_shedding], "p_load_shedding")
            println(io)
        end

        if haskey(results, :q_load_shedding)
            println(io, "[q_load_shedding - Reactive Power Load Shedding (MVAr)]")
            write_variable_data(io, results[:q_load_shedding], "q_load_shedding")
            println(io)
        end

        # Generator outputs
        if haskey(results, :pg)
            println(io, "[pg - Generator Active Power Output (MW)]")
            write_variable_data(io, results[:pg], "pg")
            println(io)
        end

        if haskey(results, :qg)
            println(io, "[qg - Generator Reactive Power Output (MVAr)]")
            write_variable_data(io, results[:qg], "qg")
            println(io)
        end

        # Branch flows
        if haskey(results, :p)
            println(io, "[p - Branch Active Power Flow (MW)]")
            write_variable_data(io, results[:p], "p")
            println(io)
        end

        if haskey(results, :q)
            println(io, "[q - Branch Reactive Power Flow (MVAr)]")
            write_variable_data(io, results[:q], "q")
            println(io)
        end
    end

    println(io, "=" ^ 80)
    println(io, "# End of results file")
    println(io, "=" ^ 80)
end
