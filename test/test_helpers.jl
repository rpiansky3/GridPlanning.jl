# test/test_helpers.jl
# Shared validation helpers for runtests_full.jl.
# Extracted from resources/test_reference.jl.

all_pass = true
check_num = 0

function check(description, condition)
    global check_num, all_pass
    check_num += 1
    if condition
        println("[PASS] Check $check_num: $description")
    else
        println("[FAIL] Check $check_num: $description")
        all_pass = false
    end
end

function reset_checks!()
    global all_pass, check_num
    all_pass = true
    check_num = 0
end

# ── Battery helpers ──────────────────────────────────────────────────────────

function validate_linearized(results)
    T = get(results, :T, 24)
    D = get(results, :D, 1)
    c_rate = 1.0; d_rate = 1.0
    max_p_chg_viol = 0.0; max_q_chg_viol = 0.0
    max_p_dis_viol = 0.0; max_q_dis_viol = 0.0
    for bus in results[:batteries_installed]
        cap = results[:x][bus]
        for d in 1:D
            for t in 1:T
                pc = results[:p_charge][(d, t, bus)]
                pd = results[:p_discharge][(d, t, bus)]
                qc = results[:q_charge][(d, t, bus)]
                qd = results[:q_discharge][(d, t, bus)]
                max_p_chg_viol = max(max_p_chg_viol, pc - c_rate * cap)
                max_p_dis_viol = max(max_p_dis_viol, pd - d_rate * cap)
                max_q_chg_viol = max(max_q_chg_viol, qc - c_rate * cap)
                max_q_dis_viol = max(max_q_dis_viol, qd - d_rate * cap)
            end
        end
    end
    check("p_charge ≤ c_rate × x (linearized)", max_p_chg_viol < 1e-4)
    check("p_discharge ≤ d_rate × x (linearized)", max_p_dis_viol < 1e-4)
    check("q_charge ≤ c_rate × x (linearized)", max_q_chg_viol < 1e-4)
    check("q_discharge ≤ d_rate × x (linearized)", max_q_dis_viol < 1e-4)
end

function validate_soc_dynamics(results)
    T = get(results, :T, 24)
    D = get(results, :D, 1)
    eta_c = 0.95; eta_d = 0.95; decay = 0.999958
    max_viol = 0.0
    for bus in results[:batteries_installed]
        cap = results[:x][bus]
        for d in 1:D
            soc_init = results[:soc][(d, 0, bus)]
            max_viol = max(max_viol, abs(soc_init - cap))
            for t in 1:T
                soc_prev = results[:soc][(d, t-1, bus)]
                soc_curr = results[:soc][(d, t, bus)]
                pc = results[:p_charge][(d, t, bus)]
                pd = results[:p_discharge][(d, t, bus)]
                expected = decay * soc_prev + eta_c * pc - pd / eta_d
                max_viol = max(max_viol, abs(soc_curr - expected))
            end
        end
    end
    check("SOC dynamics correct (active power only)", max_viol < 1e-3)
end

function validate_nonlinear(results)
    T = get(results, :T, 24)
    D = get(results, :D, 1)
    max_chg_viol = 0.0; max_dis_viol = 0.0
    for bus in results[:batteries_installed]
        cap = results[:x][bus]
        for d in 1:D
            for t in 1:T
                pc = results[:p_charge][(d, t, bus)]
                qc = results[:q_charge][(d, t, bus)]
                pd = results[:p_discharge][(d, t, bus)]
                qd = results[:q_discharge][(d, t, bus)]
                max_chg_viol = max(max_chg_viol, sqrt(pc^2 + qc^2) - 1.0 * cap)
                max_dis_viol = max(max_dis_viol, sqrt(pd^2 + qd^2) - 1.0 * cap)
            end
        end
    end
    check("Charge norm(P,Q) ≤ c_rate×x (nonlinear)", max_chg_viol < 1e-3)
    check("Discharge norm(P,Q) ≤ d_rate×x (nonlinear)", max_dis_viol < 1e-3)
end

function validate_exclusive_dcots(results)
    T = get(results, :T, 24)
    D = get(results, :D, 1)
    max_rate = 1.0; max_viol = 0.0
    for bus in results[:batteries_installed]
        cap = results[:x][bus]
        for d in 1:D
            for t in 1:T
                pc = results[:p_charge][(d, t, bus)]
                pd = results[:p_discharge][(d, t, bus)]
                max_viol = max(max_viol, (pc + pd) - max_rate * cap)
            end
        end
    end
    check("p_charge + p_discharge ≤ max_rate × x (exclusive)", max_viol < 1e-3)
end

function validate_exclusive_lacots(results)
    T = get(results, :T, 24)
    D = get(results, :D, 1)
    max_rate = 1.0; max_p_viol = 0.0; max_q_viol = 0.0
    for bus in results[:batteries_installed]
        cap = results[:x][bus]
        for d in 1:D
            for t in 1:T
                pc = results[:p_charge][(d, t, bus)]
                pd = results[:p_discharge][(d, t, bus)]
                qc = results[:q_charge][(d, t, bus)]
                qd = results[:q_discharge][(d, t, bus)]
                max_p_viol = max(max_p_viol, (pc + pd) - max_rate * cap)
                max_q_viol = max(max_q_viol, (qc + qd) - max_rate * cap)
            end
        end
    end
    check("LACOTS P exclusive: p_chg + p_dis ≤ rate × x", max_p_viol < 1e-3)
    check("LACOTS Q exclusive: q_chg + q_dis ≤ rate × x", max_q_viol < 1e-3)
end

# ── Solar helpers ─────────────────────────────────────────────────────────────

function validate_generation_bounded(results, cf_dict, flat_cf=0.3)
    max_viol = 0.0
    for (key, p_val) in results[:p_solar]
        d, t, n = key
        s_n = get(results[:s], n, 0.0)
        cf = cf_dict !== nothing ? get(cf_dict, (n, t), 0.0) : flat_cf
        max_viol = max(max_viol, p_val - cf * s_n)
    end
    check("p_solar ≤ CF × s[n] (generation bounded by capacity factor)", max_viol < 1e-4)
end

function validate_zero_cf_q(results, cf_dict)
    max_q_night = 0.0
    for (key, q_val) in results[:q_solar]
        d, t, n = key
        cf = get(cf_dict, (n, t), 0.0)
        if cf == 0.0
            max_q_night = max(max_q_night, abs(q_val))
        end
    end
    check("q_solar = 0 when CF = 0 (inverter offline at night)", max_q_night < 1e-4)
end

function validate_linearized_solar(results, cf_dict)
    max_viol = 0.0
    for (key, q_val) in results[:q_solar]
        d, t, n = key
        s_n = get(results[:s], n, 0.0)
        cf = get(cf_dict, (n, t), 0.0)
        max_viol = max(max_viol, abs(q_val) - cf * s_n)
    end
    check("Linearized |q_solar| ≤ cf × s[n]", max_viol < 1e-4)
end

function validate_nonlinear_solar(results)
    max_viol = 0.0
    for (key, p_val) in results[:p_solar]
        d, t, n = key
        s_n = get(results[:s], n, 0.0)
        q_val = get(results[:q_solar], key, 0.0)
        max_viol = max(max_viol, sqrt(p_val^2 + q_val^2) - s_n)
    end
    check("Nonlinear norm(P,Q) ≤ s[n] (circular capability curve)", max_viol < 1e-3)
end

# ── Hardening helpers ─────────────────────────────────────────────────────────

function validate_hardening_results(results::Dict, config::Dict, test_name::String)
    check("$test_name: :status present",      haskey(results, :status))
    check("$test_name: :solve_time present",   haskey(results, :solve_time))
    check("$test_name: :objective_value present", haskey(results, :objective_value))

    if get(config, :hardening_enabled, false)
        check("$test_name: :y present",              haskey(results, :y))
        check("$test_name: :hardened_lines present",  haskey(results, :hardened_lines))
        check("$test_name: :hardening_cost present",  haskey(results, :hardening_cost))
        check("$test_name: :mitigated_risk present",  haskey(results, :mitigated_risk))

        if haskey(config, :infrastructure_budget)
            budget = config[:infrastructure_budget]
            check("$test_name: hardening_cost ≤ infrastructure_budget",
                  results[:hardening_cost] <= budget + 1e-6)
        end

        for (l, y_val) in results[:y]
            check("$test_name: y[$l] is binary",
                  isapprox(y_val, 0.0, atol=1e-3) || isapprox(y_val, 1.0, atol=1e-3))
        end

        if get(config, :hardening_enforce_energization, true)
            for l in results[:hardened_lines]
                for (d_l, z_val) in results[:z]
                    d, line_id = d_l
                    if line_id == l
                        check("$test_name: hardened line $l energized on day $d",
                              isapprox(z_val, 1.0, atol=1e-3))
                    end
                end
            end
        end
    end

    check("$test_name: total_load_shed ≥ 0",    results[:total_load_shed] >= -1e-6)
    check("$test_name: risk_reduction_pct ∈ [0,100]",
          results[:risk_reduction_pct] >= -1e-6 && results[:risk_reduction_pct] <= 100.0 + 1e-6)
end
