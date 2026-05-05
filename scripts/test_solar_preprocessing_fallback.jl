# Test that load_solar_capacity_factors falls back to month+day matching
# when the exact year in times_array doesn't match the CSV reference year (2019).
using GridPlanning
using CSV, DataFrames, Dates

println("TEST: Solar preprocessing month+day fallback")
all_pass = true

# Build a minimal solar CSV with 2019 dates
# Two buses (1, 2), hours 1..24 for June 1 only
rows = NamedTuple{(:Bus_ID, :Date, :Hour, :AC_Output_pu, :DC_Output_pu), Tuple{Int,Date,Int,Float64,Float64}}[]
for bus in [1, 2]
    for h in 1:24
        push!(rows, (Bus_ID=bus, Date=Date(2019, 6, 1), Hour=h,
                     AC_Output_pu=h == 12 ? 0.5 : 0.0, DC_Output_pu=0.0))
    end
end
df = DataFrame(rows)

tmp = tempname() * ".csv"
CSV.write(tmp, df)

# Call load_solar_capacity_factors directly with a 2020 date
# It should fall back to the 2019 data via month+day matching
solar_locs = [1, 2]
times_array = [(2020, 6, 1)]
T = 24
opt_params = Dict(
    :solar_data_path => tmp,
    :solar_capacity_factor_default => 0.0,
)

solar_cf = GridPlanning.load_solar_capacity_factors(opt_params, solar_locs, times_array, T)

# Hour 12 should have CF=0.5 (from the 2019 data matched by month+day)
cf_noon_bus1 = get(solar_cf, (1, 12, 1), -1.0)
if cf_noon_bus1 ≈ 0.5
    println("PASS: month+day fallback returns correct CF for 2020-06-01 from 2019 data")
else
    println("FAIL: expected 0.5 at (day=1, hour=12, bus=1), got $cf_noon_bus1")
    all_pass = false
end

# Hour 1 should have CF=0.0
cf_early_bus1 = get(solar_cf, (1, 1, 1), -1.0)
if cf_early_bus1 ≈ 0.0
    println("PASS: non-solar hour returns 0.0")
else
    println("FAIL: expected 0.0 at (day=1, hour=1, bus=1), got $cf_early_bus1")
    all_pass = false
end

rm(tmp)
println(all_pass ? "\nAll tests PASSED" : "\nSome tests FAILED")
exit(all_pass ? 0 : 1)
