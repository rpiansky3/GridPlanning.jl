# test/test_population_assignment.jl
# Unit + integration tests for the 3-pass population assignment pipeline.
#
# Unit tests are self-contained (no external data). The integration test is
# gated on the presence of the TIGER tract shapefile and is skipped with
# @info otherwise.

using Test
using DataFrames
using GridPlanning

const _hav = GridPlanning.haversine_m
const _centroid = GridPlanning.tract_centroid
const _assign = GridPlanning.assign_population

@testset "haversine_m" begin
    @test _hav(0.0, 0.0, 0.0, 0.0) ≈ 0.0 atol=1e-6
    # 1 deg lon at the equator ≈ 111.195 km with R=6,371 km mean Earth radius
    @test isapprox(_hav(0.0, 0.0, 0.0, 1.0), 111_195.0; rtol=1e-3)
    # Symmetric
    @test _hav(40.0, -100.0, 41.0, -99.0) ≈ _hav(41.0, -99.0, 40.0, -100.0)
end

@testset "tract_centroid: unit square" begin
    # Points are [lon, lat] per GeoInterface convention
    ring = [[0.0, 0.0], [1.0, 0.0], [1.0, 1.0], [0.0, 1.0], [0.0, 0.0]]
    lat, lon = _centroid(ring)
    @test lat ≈ 0.5 atol=1e-9
    @test lon ≈ 0.5 atol=1e-9
end

@testset "tract_centroid: degenerate ring falls back to vertex mean" begin
    ring = [[0.0, 0.0], [1.0, 0.0], [0.0, 0.0]]
    lat, lon = _centroid(ring)
    @test isfinite(lat) && isfinite(lon)
end

@testset "assign_population: trivial 1-to-1" begin
    tracts = [
        (geoid="A", centroid_lat=0.0, centroid_lng=0.0,    total_pop=100.0),
        (geoid="B", centroid_lat=0.0, centroid_lng=1.0,    total_pop=200.0),
    ]
    buses = [
        (bus_id=1, lat=0.0, lng=0.0),
        (bus_id=2, lat=0.0, lng=1.0),
    ]
    rows = _assign(tracts, buses; weighting=:inverse)
    # Each tract should be assigned to exactly one bus (distance 0 wins)
    @test length(rows) == 2
    byt = Dict(r.tract_geoid => r for r in rows)
    @test byt["A"].bus_id == 1
    @test byt["B"].bus_id == 2
    @test byt["A"].weight ≈ 1.0 && byt["B"].weight ≈ 1.0
    @test byt["A"].assigned_population ≈ 100.0
    @test byt["B"].assigned_population ≈ 200.0
end

@testset "assign_population: inverse vs proportional weighting" begin
    # One tract, two buses. Place them so distances are in a known ratio.
    # Bus 1 ~10 km east, bus 2 ~30 km east (both in tract radius after
    # pass 1+2 because pass 2 bumps r_c up to include the farther bus).
    tracts = [(geoid="T1", centroid_lat=0.0, centroid_lng=0.0, total_pop=1000.0)]
    # 1 deg lon at equator ≈ 111.32 km, so ~0.0898 deg ≈ 10 km, 0.2694 ≈ 30 km
    buses = [
        (bus_id=1, lat=0.0, lng=10_000 / 111_320.0),
        (bus_id=2, lat=0.0, lng=30_000 / 111_320.0),
    ]

    inv_rows = _assign(tracts, buses; weighting=:inverse)
    @test length(inv_rows) == 2
    w = Dict(r.bus_id => r.weight for r in inv_rows)
    # Inverse: closer bus gets bigger weight; weights 0.75 / 0.25
    @test w[1] > w[2]
    @test isapprox(w[1], 0.75; atol=1e-3)
    @test isapprox(w[2], 0.25; atol=1e-3)
    @test isapprox(w[1] + w[2], 1.0; atol=1e-9)

    prop_rows = _assign(tracts, buses; weighting=:proportional)
    wp = Dict(r.bus_id => r.weight for r in prop_rows)
    # Proportional (spec): farther bus gets bigger weight; 0.25 / 0.75
    @test wp[1] < wp[2]
    @test isapprox(wp[1], 0.25; atol=1e-3)
    @test isapprox(wp[2], 0.75; atol=1e-3)
end

@testset "assign_population: pass 2 covers orphan bus" begin
    # Two tracts near origin; a far third bus that is closest to neither
    # tract's nearest-bus choice. Pass 2 must expand one tract's radius so
    # the far bus ends up assigned.
    tracts = [
        (geoid="A", centroid_lat=0.0, centroid_lng=0.0,  total_pop=500.0),
        (geoid="B", centroid_lat=0.0, centroid_lng=0.01, total_pop=500.0),
    ]
    buses = [
        (bus_id=1, lat=0.0, lng=0.0),    # nearest to A
        (bus_id=2, lat=0.0, lng=0.01),   # nearest to B
        (bus_id=3, lat=0.0, lng=1.0),    # far — must be picked up by pass 2
    ]
    rows = _assign(tracts, buses; weighting=:inverse)
    covered = Set(r.bus_id for r in rows)
    @test 1 in covered && 2 in covered && 3 in covered

    # Weights sum to 1 per tract
    for g in ("A", "B")
        s = sum(r.weight for r in rows if r.tract_geoid == g)
        @test isapprox(s, 1.0; atol=1e-9)
    end
end

@testset "assign_population: invariants on random grid" begin
    # Deterministic seed-free grid — 5 tracts, 3 buses; check invariants.
    tracts = [
        (geoid="T$i", centroid_lat=0.01 * i, centroid_lng=0.01 * (i - 2), total_pop=100.0 * i)
        for i in 1:5
    ]
    buses = [
        (bus_id=1, lat=0.0,  lng=0.0),
        (bus_id=2, lat=0.03, lng=0.02),
        (bus_id=3, lat=0.05, lng=-0.01),
    ]
    rows = _assign(tracts, buses; weighting=:inverse)

    # Every tract appears at least once
    tract_set = Set(r.tract_geoid for r in rows)
    @test tract_set == Set("T$i" for i in 1:5)
    # Every bus appears at least once
    bus_set = Set(r.bus_id for r in rows)
    @test bus_set == Set([1, 2, 3])
    # Weights sum to 1.0 per tract
    for g in ("T1","T2","T3","T4","T5")
        s = sum(r.weight for r in rows if r.tract_geoid == g)
        @test isapprox(s, 1.0; atol=1e-9)
    end
    # Assigned populations sum per tract equals total_pop
    for i in 1:5
        g = "T$i"
        s = sum(r.assigned_population for r in rows if r.tract_geoid == g)
        @test isapprox(s, 100.0 * i; atol=1e-6)
    end
end

@testset "assign_population: empty inputs" begin
    @test isempty(_assign(NamedTuple[], [(bus_id=1, lat=0.0, lng=0.0)]))
    @test isempty(_assign([(geoid="A", centroid_lat=0.0, centroid_lng=0.0, total_pop=1.0)],
                          NamedTuple[]))
end

@testset "aggregate_tract_to_bus" begin
    # Two tracts, two buses. T1 is assigned entirely to bus 1 (weight 1.0);
    # T2 is split 0.7/0.3 between buses 1 and 2. Count fields should sum as
    # (weight × tract_count); median_income is population-weighted.
    tract_rows = [
        (geoid="T1", centroid_lat=0.0, centroid_lng=0.0,
         total_pop=100.0, num_households=40.0, num_white=60.0, num_black=10.0,
         num_native=5.0, num_asian=5.0, num_hispanic=20.0,
         num_below_poverty=15.0, num_above_poverty=85.0,
         num_low_income=10.0, num_middle_income=20.0, num_high_income=10.0,
         median_income=50_000.0),
        (geoid="T2", centroid_lat=0.0, centroid_lng=0.0,
         total_pop=200.0, num_households=80.0, num_white=100.0, num_black=50.0,
         num_native=10.0, num_asian=40.0, num_hispanic=50.0,
         num_below_poverty=60.0, num_above_poverty=140.0,
         num_low_income=30.0, num_middle_income=40.0, num_high_income=10.0,
         median_income=30_000.0),
    ]
    assignments = [
        (tract_geoid="T1", bus_id=1, weight=1.0, distance_m=0.0, assigned_population=100.0),
        (tract_geoid="T2", bus_id=1, weight=0.7, distance_m=0.0, assigned_population=140.0),
        (tract_geoid="T2", bus_id=2, weight=0.3, distance_m=0.0, assigned_population=60.0),
    ]
    rows = GridPlanning.aggregate_tract_to_bus(tract_rows, assignments)
    @test length(rows) == 2
    byb = Dict(r.Bus_ID => r for r in rows)

    @test byb[1].total_pop ≈ 240.0
    @test byb[1].num_white ≈ 60.0 + 0.7 * 100.0
    @test byb[1].num_below_poverty ≈ 15.0 + 0.7 * 60.0
    # Population-weighted median: (100×50_000 + 140×30_000) / 240
    @test byb[1].median_income ≈ (100 * 50_000 + 140 * 30_000) / 240

    @test byb[2].total_pop ≈ 60.0
    @test byb[2].median_income ≈ 30_000.0
end

# ── Integration test (gated on shapefile presence) ───────────────────────────
@testset "RTS integration (requires shapefile)" begin
    shp = joinpath(PROJECT_ROOT, "data", "US_Shapefiles", "cb_2023_us_tract_500k.shp")
    if !isfile(shp)
        @info "Skipping RTS integration test — shapefile not available at $shp"
    else
        tmp = mktempdir()
        out_path = joinpath(tmp, "RTS_census_2022.csv")
        try
            get_network_census("RTS";
                               radius_m=25_000.0,
                               output_path=out_path,
                               data_dir="test_data")
        catch e
            @warn "Integration end-to-end failed (likely no CENSUS_API_KEY / network): $e"
        end

        if isfile(out_path)
            df = CSV.read(out_path, DataFrame; types=Dict(:Bus_ID=>Int))
            @test nrow(df) > 0

            lb = GridPlanning.load_buses_with_load("RTS"; data_dir="test_data")
            @test !isempty(lb)
            assigned = Set(df.Bus_ID)
            # Every load bus appears at least once
            @test all(b in assigned for b in lb)

            # All absolute counts are non-negative
            for col in (:total_pop, :num_households, :num_white, :num_black,
                        :num_native, :num_asian, :num_hispanic,
                        :num_below_poverty, :num_above_poverty,
                        :num_low_income, :num_middle_income, :num_high_income)
                @test all(df[!, col] .>= -1e-9)
            end
        else
            @info "Integration output not produced (Census API unavailable?). Skipping invariants."
        end
    end
end
