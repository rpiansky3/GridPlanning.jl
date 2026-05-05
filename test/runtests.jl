# test/runtests.jl
# CI test suite — no Gurobi license required.
# Run via: julia --project=. test/runtests.jl  OR  Pkg.test()
#
# These tests exercise only pre-solver code paths:
#   - Package loading (Gurobi_jll supplies runtime; license only needed for optimize!)
#   - test_data/ file existence
#   - CSV column structure
#   - Parameter validation errors (thrown before build_and_solve_model)
#
# Full test suite (requires Gurobi license): julia --project=. test/runtests_full.jl

using Test
using CSV
using DataFrames
using GridPlanning

const PROJECT_ROOT = dirname(@__DIR__)
const TEST_DATA    = joinpath(PROJECT_ROOT, "test_data")

# ── 1. Package load ───────────────────────────────────────────────────────────
@testset "Package loads" begin
    @test GridPlanning.solve_ots isa Function
    @test GridPlanning.plot_results isa Function
end

# ── 2. Network files ──────────────────────────────────────────────────────────
@testset "Reference data: network files" begin
    nets = [
        "RTS_GMLC.m",
        "CaliforniaTestSystem.m",
        "Texas7k_20210804.m",
        "case_ACTIVSg2000.m",
        "case_ACTIVSg10k.m",
        "pglib_opf_case240_pserc.m",
    ]
    for f in nets
        path = joinpath(TEST_DATA, "networks", f)
        @test isfile(path)
    end
end

# ── 3. WFPI risk data ─────────────────────────────────────────────────────────
@testset "Reference data: WFPI files" begin
    # CSV-based networks
    @test isfile(joinpath(TEST_DATA, "USGS_FPI", "RTS",  "2020_risk.csv"))
    @test isfile(joinpath(TEST_DATA, "USGS_FPI", "CATS", "2020_risk.csv"))

    # JLD2-based networks — spot-check June 15
    jld2_files = [
        joinpath(TEST_DATA, "USGS_FPI", "Texas7k",  "2020", "forecast_day_1", "FPI_Texas7k_fday1_year2020_month6_day15.jld2"),
        joinpath(TEST_DATA, "USGS_FPI", "texas2k",  "2020", "forecast_day_1", "FPI_Texas2k_fday1_year2020_month6_day15.jld2"),
        joinpath(TEST_DATA, "USGS_FPI", "WECC10k",  "2020", "forecast_day_1", "FPI_WECC10k_fday1_year2020_month6_day15.jld2"),
        joinpath(TEST_DATA, "USGS_FPI", "WECC240",  "2020", "forecast_day_1", "FPI_WECC240_fday1_year2020_month6_day15.jld2"),
    ]
    for f in jld2_files
        @test isfile(f)
    end
end

# ── 4. Solar data ─────────────────────────────────────────────────────────────
# Note: CATS, Texas7k, WECC10k solar CSVs are 200+ MB and not tracked in git;
# only the three smaller networks are included in test_data/.
@testset "Reference data: solar CSV files" begin
    solar_dirs = ["RTS", "texas2k", "WECC240"]
    for d in solar_dirs
        path = joinpath(TEST_DATA, "solar_data", d, "solar_data.csv")
        @test isfile(path)
    end
end

# ── 5. CATS support files ─────────────────────────────────────────────────────
@testset "Reference data: CATS support files" begin
    cats_files = [
        "CATS_buses.csv",
        "CATS_gens.csv",
        "HourlyProduction2019.csv",
        "Load_Agg_Post_Assignment_v3_latest.csv",
        "cats_metadata.json",
    ]
    for f in cats_files
        @test isfile(joinpath(TEST_DATA, "CATS", f))
    end
end

# ── 6. Bus coordinate files ───────────────────────────────────────────────────
@testset "Reference data: bus coordinate files" begin
    coord_files = [
        "RTS_GMLC_bus.csv",
        "CATS_bus.csv",
        "Texas7k_lat_long.csv",
        "Texas2k_lat_long.csv",
        "WECC10k_lat_long.csv",
        "wecc_lat_lon_good.csv",
    ]
    for f in coord_files
        @test isfile(joinpath(TEST_DATA, "bus_lat_lons", f))
    end
end

# ── 7. CSV column structure ───────────────────────────────────────────────────
@testset "CSV column structure" begin
    # RTS risk CSV has expected columns (date_of_risk, branch_id, risk metrics)
    rts_risk = CSV.read(joinpath(TEST_DATA, "USGS_FPI", "RTS", "2020_risk.csv"), DataFrame)
    @test "date_of_risk" in names(rts_risk)
    @test "branch_id" in names(rts_risk)
    @test any(occursin.(r"wfpi"i, names(rts_risk)))

    # Solar CSV has Bus_ID and Hour columns
    rts_solar = CSV.read(joinpath(TEST_DATA, "solar_data", "RTS", "solar_data.csv"), DataFrame)
    col_names = names(rts_solar)
    @test any(occursin.(r"bus"i, col_names))
    @test any(occursin.(r"hour"i, col_names))
    @test any(occursin.(r"ac_output|capacity_factor|cf"i, col_names))
end

# ── 8. Parameter validation (pre-solver errors) ───────────────────────────────
@testset "Parameter validation" begin
    # Missing required key
    @test_throws ErrorException solve_ots(Dict(
        :model => "DCOTS", :objective => "loadshed", :times => [(2020, 6, 15)]
    ))

    # Invalid model type
    @test_throws ErrorException solve_ots(Dict(
        :network => "RTS", :model => "BADMODEL",
        :objective => "loadshed", :times => [(2020, 6, 15)]
    ))

    # Invalid objective
    @test_throws ErrorException solve_ots(Dict(
        :network => "RTS", :model => "DCOTS",
        :objective => "invalid_obj", :times => [(2020, 6, 15)]
    ))

    # Invalid switching_method
    @test_throws ErrorException solve_ots(Dict(
        :network => "RTS", :model => "DCOTS", :objective => "loadshed",
        :times => [(2020, 6, 15)], :switching_method => "random"
    ))

    # Negative battery_cost_per_pu — caught in preprocess() before optimizer
    @test_throws ErrorException solve_ots(Dict(
        :network => "RTS", :model => "DCOTS", :objective => "loadshed",
        :times => [(2020, 6, 15)], :data_dir => "test_data",
        :battery_enabled => true, :battery_cost_per_pu => -1.0,
        :infrastructure_budget => 1e9,
    ))

    # solar_capacity_factor_default outside [0,1] — caught in preprocess()
    @test_throws ErrorException solve_ots(Dict(
        :network => "RTS", :model => "DCOTS", :objective => "loadshed",
        :times => [(2020, 6, 15)], :data_dir => "test_data",
        :solar_enabled => true, :solar_capacity_factor_default => 1.5,
        :infrastructure_budget => 1e9,
    ))
end

include("test_population_assignment.jl")
