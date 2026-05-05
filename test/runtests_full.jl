# test/runtests_full.jl
# Full test suite — requires a valid Gurobi license.
# Run with: julia --project=. test/runtests_full.jl
#
# 18 test groups covering DCOTS, LACOTS, battery, solar, hardening,
# plotting, and a multi-network smoke test.
# All tests use June 2020 reference data from test_data/.

using Pkg
Pkg.activate(joinpath(@__DIR__, ".."))

using GridPlanning
using JuMP
using CSV
using DataFrames
using Dates
const MOI = JuMP.MOI

include(joinpath(@__DIR__, "test_helpers.jl"))

const PROJECT_ROOT = dirname(@__DIR__)
const TEST_DATE    = (2020, 6, 15)
const DATA_DIR     = "test_data"
const RTS_SOLAR    = joinpath(PROJECT_ROOT, "test_data", "solar_data", "RTS", "solar_data.csv")

# ── Common base config ────────────────────────────────────────────────────────
function base_rts(extra::Dict = Dict())
    merge(Dict(
        :network    => "RTS",
        :model      => "DCOTS",
        :objective  => "loadshed",
        :times      => [TEST_DATE],
        :data_dir   => DATA_DIR,
        :time_limit => 600.0,
        :mip_gap    => 0.01,
    ), extra)
end

# ── Group 1: DCOTS thresholded ────────────────────────────────────────────────
println("\n=== Group 1: DCOTS loadshed thresholded ===")
r1 = solve_ots(base_rts(Dict(
    :switching_method => "thresholded",
    :threshold_pct    => 0.75,
)))
check("DCOTS thresholded: status is OPTIMAL or TIME_LIMIT",
      r1[:status] in [MOI.OPTIMAL, MOI.TIME_LIMIT])
check("DCOTS thresholded: total_load_shed ≥ 0", r1[:total_load_shed] >= -1e-6)
check("DCOTS thresholded: switched_off_lines present", haskey(r1, :switched_off_lines))

# ── Group 2: DCOTS optimal ────────────────────────────────────────────────────
println("\n=== Group 2: DCOTS loadshed optimal ===")
r2 = solve_ots(base_rts(Dict(
    :switching_method => "optimal",
)))
check("DCOTS optimal: status is OPTIMAL or TIME_LIMIT",
      r2[:status] in [MOI.OPTIMAL, MOI.TIME_LIMIT])
check("DCOTS optimal: z keys present", haskey(r2, :z))
check("DCOTS optimal: load_shed ≤ thresholded load_shed (or TIME_LIMIT)",
      r2[:status] == MOI.TIME_LIMIT || r2[:total_load_shed] <= r1[:total_load_shed] + 1e-3)

# ── Group 3: LACOTS loadshed ──────────────────────────────────────────────────
println("\n=== Group 3: LACOTS loadshed ===")
r3 = solve_ots(merge(base_rts(), Dict(
    :model            => "LACOTS",
    :switching_method => "thresholded",
    :threshold_pct    => 0.75,
    :warm_start       => r1,
)))
check("LACOTS: status is OPTIMAL or TIME_LIMIT",
      r3[:status] in [MOI.OPTIMAL, MOI.TIME_LIMIT])
check("LACOTS: :vm (voltage magnitudes) present", haskey(r3, :vm))
check("LACOTS: :q (reactive flows) present",      haskey(r3, :q))

# ── Group 4: Battery LACOTS linearized ───────────────────────────────────────
println("\n=== Group 4: Battery LACOTS linearized ===")
r4 = solve_ots(merge(base_rts(), Dict(
    :model                    => "LACOTS",
    :switching_method         => "thresholded",
    :threshold_pct            => 0.75,
    :battery_enabled          => true,
    :battery_cost_per_pu      => 2e7,
    :battery_charge_rate      => 1.0,
    :battery_discharge_rate   => 1.0,
    :linearized_battery_power => true,
    :infrastructure_budget    => 500e6,
)))
check("Battery linearized: :x present",   haskey(r4, :x))
check("Battery linearized: :soc present", haskey(r4, :soc))
validate_linearized(r4)
validate_soc_dynamics(r4)

# ── Group 5: Battery LACOTS nonlinear ─────────────────────────────────────────
println("\n=== Group 5: Battery LACOTS nonlinear ===")
r5 = solve_ots(merge(base_rts(), Dict(
    :model                    => "LACOTS",
    :switching_method         => "thresholded",
    :threshold_pct            => 0.75,
    :battery_enabled          => true,
    :battery_cost_per_pu      => 2e7,
    :battery_charge_rate      => 1.0,
    :battery_discharge_rate   => 1.0,
    :linearized_battery_power => false,
    :infrastructure_budget    => 500e6,
)))
check("Battery nonlinear: :x present", haskey(r5, :x))
validate_nonlinear(r5)

# ── Group 6: Battery + hardening shared budget ────────────────────────────────
println("\n=== Group 6: Battery + hardening shared budget ===")
r6 = solve_ots(base_rts(Dict(
    :switching_method          => "optimal",
    :battery_enabled           => true,
    :battery_cost_per_pu       => 2e7,
    :hardening_enabled         => true,
    :hardening_cost_per_mile   => 7e6,
    :hardening_effectiveness   => 1.0,
    :infrastructure_budget     => 300e6,
)))
check("Budget group: :x and :y both present",
      haskey(r6, :x) && haskey(r6, :y))
battery_cost   = get(r6, :battery_cost,   0.0)
hardening_cost = get(r6, :hardening_cost, 0.0)
check("Budget group: battery_cost + hardening_cost ≤ 300M",
      battery_cost + hardening_cost <= 300e6 + 1e-3)

# ── Group 7: Battery exclusive DCOTS ─────────────────────────────────────────
println("\n=== Group 7: Battery exclusive operation (DCOTS) ===")
r7 = solve_ots(base_rts(Dict(
    :switching_method             => "thresholded",
    :threshold_pct                => 0.75,
    :battery_enabled              => true,
    :battery_cost_per_pu          => 2e7,
    :battery_charge_rate          => 1.0,
    :battery_discharge_rate       => 1.0,
    :battery_exclusive_operation  => true,
    :infrastructure_budget        => 500e6,
)))
check("Exclusive DCOTS: :x present", haskey(r7, :x))
validate_exclusive_dcots(r7)

# ── Group 8: Battery exclusive LACOTS ────────────────────────────────────────
println("\n=== Group 8: Battery exclusive operation (LACOTS) ===")
r8 = solve_ots(merge(base_rts(), Dict(
    :model                        => "LACOTS",
    :switching_method             => "thresholded",
    :threshold_pct                => 0.75,
    :battery_enabled              => true,
    :battery_cost_per_pu          => 2e7,
    :battery_charge_rate          => 1.0,
    :battery_discharge_rate       => 1.0,
    :battery_exclusive_operation  => true,
    :linearized_battery_power     => true,
    :infrastructure_budget        => 500e6,
)))
check("Exclusive LACOTS: :x present", haskey(r8, :x))
validate_exclusive_lacots(r8)

# ── Group 9: Solar flat CF DCOTS ─────────────────────────────────────────────
println("\n=== Group 9: Solar flat CF (DCOTS) ===")
r9 = solve_ots(base_rts(Dict(
    :switching_method              => "thresholded",
    :threshold_pct                 => 0.75,
    :solar_enabled                 => true,
    :solar_cost_per_pu             => 5e7,
    :solar_capacity_factor_default => 0.3,
    :infrastructure_budget         => 500e6,
    :time_limit                    => 120.0,
)))
check("Solar flat: :s present",       haskey(r9, :s))
check("Solar flat: :p_solar present", haskey(r9, :p_solar))
validate_generation_bounded(r9, nothing, 0.3)

# ── Group 10: Solar CSV CF LACOTS linearized ──────────────────────────────────
println("\n=== Group 10: Solar CSV CF LACOTS linearized ===")
r10 = solve_ots(merge(base_rts(), Dict(
    :model                  => "LACOTS",
    :switching_method       => "thresholded",
    :threshold_pct          => 0.75,
    :solar_enabled          => true,
    :solar_cost_per_pu      => 5e7,
    :solar_data_path        => RTS_SOLAR,
    :linearized_solar_power => true,
    :infrastructure_budget  => 500e6,
)))
check("Solar linearized: :s present",       haskey(r10, :s))
check("Solar linearized: :q_solar present", haskey(r10, :q_solar))
# Build cf_dict from source CSV (matching June 15 by month+day, TMY data uses 2019)
let solar_df = CSV.read(RTS_SOLAR, DataFrame),
    cf_dict   = Dict{Tuple{Int,Int}, Float64}()
    day_df = DataFrames.filter(r -> Dates.month(r.Date) == 6 && Dates.day(r.Date) == 15, solar_df)
    for row in eachrow(day_df)
        cf_dict[(Int(row.Bus_ID), Int(row.Hour))] = Float64(row.AC_Output_pu)
    end
    validate_linearized_solar(r10, cf_dict)
    validate_zero_cf_q(r10, cf_dict)
end

# ── Group 11: Solar CSV CF LACOTS nonlinear ───────────────────────────────────
println("\n=== Group 11: Solar CSV CF LACOTS nonlinear ===")
r11 = solve_ots(merge(base_rts(), Dict(
    :model                  => "LACOTS",
    :switching_method       => "thresholded",
    :threshold_pct          => 0.75,
    :solar_enabled          => true,
    :solar_cost_per_pu      => 5e7,
    :solar_data_path        => RTS_SOLAR,
    :linearized_solar_power => false,
    :infrastructure_budget  => 500e6,
)))
check("Solar nonlinear: :s present", haskey(r11, :s))
validate_nonlinear_solar(r11)

# ── Group 12: Solar + battery combined ───────────────────────────────────────
println("\n=== Group 12: Solar + battery combined (DCOTS) ===")
r12 = solve_ots(base_rts(Dict(
    :switching_method              => "thresholded",
    :threshold_pct                 => 0.75,
    :solar_enabled                 => true,
    :solar_cost_per_pu             => 5e7,
    :solar_capacity_factor_default => 0.3,
    :battery_enabled               => true,
    :battery_cost_per_pu           => 2e7,
    :infrastructure_budget         => 500e6,
)))
check("Solar+battery: :s and :x both present",
      haskey(r12, :s) && haskey(r12, :x))
solar_cost12   = get(r12, :solar_cost,   0.0)
battery_cost12 = get(r12, :battery_cost, 0.0)
check("Solar+battery: combined cost ≤ 500M",
      solar_cost12 + battery_cost12 <= 500e6 + 1e-3)

# ── Group 13: Hardening loadshed ──────────────────────────────────────────────
println("\n=== Group 13: Hardening loadshed ===")
r13 = solve_ots(base_rts(Dict(
    :hardening_enabled              => true,
    :hardening_effectiveness        => 1.0,
    :hardening_cost_per_mile        => 7e6,
    :hardening_enforce_energization => true,
    :infrastructure_budget          => 1e9,
)))
validate_hardening_results(r13,
    Dict(:hardening_enabled => true, :infrastructure_budget => 1e9,
         :hardening_enforce_energization => true),
    "hardening_loadshed")

# ── Group 14: Hardening wildfire ──────────────────────────────────────────────
println("\n=== Group 14: Hardening wildfire ===")
r14 = solve_ots(base_rts(Dict(
    :objective                      => "wildfire",
    :hardening_enabled              => true,
    :hardening_effectiveness        => 0.9,
    :hardening_cost_per_mile        => 7e6,
    :hardening_enforce_energization => true,
    :infrastructure_budget          => 5e8,
)))
validate_hardening_results(r14,
    Dict(:hardening_enabled => true, :infrastructure_budget => 5e8,
         :hardening_enforce_energization => true),
    "hardening_wildfire")

# ── Group 15: Hardening cost objective ────────────────────────────────────────
println("\n=== Group 15: Hardening cost objective ===")
r15 = solve_ots(base_rts(Dict(
    :objective                      => "cost",
    :voll                           => 10000.0,
    :hardening_enabled              => true,
    :hardening_effectiveness        => 1.0,
    :hardening_cost_per_mile        => 7e6,
    :hardening_enforce_energization => true,
)))
validate_hardening_results(r15,
    Dict(:hardening_enabled => true, :hardening_enforce_energization => true),
    "hardening_cost")

# ── Group 16: Hardening tradeoff ──────────────────────────────────────────────
println("\n=== Group 16: Hardening tradeoff ===")
r16 = solve_ots(base_rts(Dict(
    :objective                      => "tradeoff",
    :tradeoff_weight                => 0.7,
    :hardening_enabled              => true,
    :hardening_effectiveness        => 1.0,
    :hardening_cost_per_mile        => 7e6,
    :hardening_enforce_energization => true,
    :infrastructure_budget          => 1e9,
)))
validate_hardening_results(r16,
    Dict(:hardening_enabled => true, :infrastructure_budget => 1e9,
         :hardening_enforce_energization => true),
    "hardening_tradeoff")

# ── Group 17: Plotting ────────────────────────────────────────────────────────
println("\n=== Group 17: Plotting ===")
plot_dir = mktempdir()
r17 = solve_ots(base_rts(Dict(
    :switching_method              => "thresholded",
    :threshold_pct                 => 0.25,
    :hardening_enabled             => true,
    :hardening_cost_per_mile       => 7e6,
    :hardening_effectiveness       => 1.0,
    :solar_enabled                 => true,
    :solar_cost_per_pu             => 5e7,
    :solar_capacity_factor_default => 0.3,
    :battery_enabled               => true,
    :battery_cost_per_pu           => 2e7,
    :infrastructure_budget         => 150e6,
    :time_limit                    => 300.0,
)))
features = [:network_overview, :load_shed_timeseries, :cost_breakdown,
            :generation_dispatch, :battery_dispatch, :solar_generation]
plot_results(r17, features; output_dir=plot_dir, format="png")
for feat in features
    found = any(f -> startswith(f, string(feat)), readdir(plot_dir))
    check("Plotting: $feat file created", found)
end

# ── Group 18: Multi-network smoke test ────────────────────────────────────────
println("\n=== Group 18: Multi-network smoke test ===")
network_configs = [
    ("RTS",     24),
    ("CATS",    24),
    ("Texas2k", 24),
    ("Texas7k",  1),
    ("WECC10k",  1),
    ("WECC240",  1),
]
for (network, T) in network_configs
    print("  $network (T=$T) ... ")
    flush(stdout)
    r = solve_ots(Dict(
        :network          => network,
        :model            => "DCOTS",
        :objective        => "loadshed",
        :times            => [TEST_DATE],
        :switching_method => "thresholded",
        :threshold_pct    => 0.0,
        :T                => T,
        :data_dir         => DATA_DIR,
        :time_limit       => 180.0,
        :mip_gap          => 0.01,
    ))
    ok = r[:status] in [MOI.OPTIMAL, MOI.TIME_LIMIT]
    check("$network smoke test: solved without error", ok)
    println(ok ? "PASS" : "FAIL")
end

# ── Summary ───────────────────────────────────────────────────────────────────
println("\n" * "=" ^ 60)
if all_pass
    println("All checks PASSED.")
else
    println("Some checks FAILED — see [FAIL] lines above.")
end
println("=" ^ 60)
exit(all_pass ? 0 : 1)
