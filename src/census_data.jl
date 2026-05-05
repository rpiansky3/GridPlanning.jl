"""
ACS 5-year HTTP layer for the census pipeline.

This file owns the Census Data API plumbing (variables, batched fetch, value
coercion, null-sentinel handling) that the tract→bus aggregator in
`population_assignment.jl` drives. There is no per-bus geocoding path —
demographics are pulled at tract level and then aggregated to buses.
"""

using Printf

# ACS 5-year variables pulled for every tract.
#   B01003_001E — total population
#   B02001_0{01..05}E — race universe + white/black/native/asian alone
#   B03003_{001,003}E — ethnicity universe + Hispanic/Latino
#   B11001_001E — total households
#   B17001_{001,002}E — poverty universe + below poverty
#   B19001_0{01..17}E — households by income bracket (total + 16 buckets)
#   B19013_001E — median household income
const ACS_VARIABLES = [
    "B01003_001E",
    "B02001_001E", "B02001_002E", "B02001_003E", "B02001_004E", "B02001_005E",
    "B03003_001E", "B03003_003E",
    "B11001_001E",
    "B17001_001E", "B17001_002E",
    "B19001_001E", "B19001_002E", "B19001_003E", "B19001_004E", "B19001_005E",
    "B19001_006E", "B19001_007E", "B19001_008E", "B19001_009E", "B19001_010E",
    "B19001_011E", "B19001_012E", "B19001_013E", "B19001_014E", "B19001_015E",
    "B19001_016E", "B19001_017E",
    "B19013_001E",
]

# B19001 bracket mapping to low/middle/high buckets (Texas7k reference split):
#   low    = <$35k        : B19001_002..B19001_007 (6 brackets)
#   middle = $35k–$100k   : B19001_008..B19001_013 (6 brackets)
#   high   = ≥$100k       : B19001_014..B19001_017 (4 brackets)
const B19001_LOW    = ["B19001_00$(i)E" for i in 2:7]
const B19001_MIDDLE = ["B19001_00$(i)E" for i in 8:9] ∪ ["B19001_0$(i)E" for i in 10:13]
const B19001_HIGH   = ["B19001_0$(i)E" for i in 14:17]

const CENSUS_NULL_SENTINELS = (-666666666, -999999999, -888888888, -222222222,
                                -333333333, -555555555)

"""
    fetch_acs_data(tract_keys, variables, year, api_key) -> Dict{(state,county,tract) => Dict{var => Any}}

One HTTP GET per (state, county) group, chunked if a county has many tracts
(Census's API front-end imposes a ~8 KB URL length cap).
"""
function fetch_acs_data(tract_keys, variables::Vector{String}, year::Int, api_key::String)
    result = Dict{Tuple{String,String,String}, Dict{String, Any}}()
    by_county = Dict{Tuple{String,String}, Vector{String}}()
    for (s, c, t) in tract_keys
        push!(get!(by_county, (s, c), String[]), t)
    end

    base_url = "https://api.census.gov/data/$(year)/acs/acs5"
    # 6-digit tract codes + commas ≈ 7 B each → 400 tracts ≈ 2.8 KB for the
    # `for=tract:...` param, leaving ample headroom under the ~8 KB URL cap.
    chunk_size = 400
    fetched_groups = 0

    for ((state, county), tracts) in by_county
        unique_tracts = unique(tracts)
        county_ok = false
        for chunk_start in 1:chunk_size:length(unique_tracts)
            chunk = unique_tracts[chunk_start:min(chunk_start + chunk_size - 1, end)]
            tract_list = join(chunk, ",")
            q = Dict{String,Any}(
                "get"  => join(variables, ","),
                "for"  => "tract:$tract_list",
                "in"   => "state:$state county:$county",
            )
            isempty(api_key) || (q["key"] = api_key)

            try
                resp = HTTP.get(base_url; query=q, readtimeout=60, retry=false)
                if resp.status != 200
                    @warn "ACS fetch failed for state=$state county=$county chunk=$chunk_start status=$(resp.status)"
                    continue
                end
                rows = JSON.parse(String(resp.body))
                isempty(rows) && continue
                header = rows[1]
                for r in rows[2:end]
                    rec = Dict{String, Any}(zip(header, r))
                    t = rec["tract"]
                    result[(state, county, t)] = rec
                end
                county_ok = true
                sleep(0.1)
            catch e
                @warn "ACS request errored for state=$state county=$county chunk=$chunk_start: $e"
            end
        end

        county_ok && (fetched_groups += 1)
        if fetched_groups > 0 && fetched_groups % 10 == 0
            println("  ACS: fetched $fetched_groups / $(length(by_county)) county groups...")
        end
    end

    println("ACS: $(length(result)) tracts retrieved across $fetched_groups county requests.")
    return result
end

_to_float(x) = x === nothing || (x isa AbstractString && isempty(x)) ? missing :
    begin
        v = try parse(Float64, String(x)) catch; missing end
        v === missing && return missing
        any(isapprox(v, s; atol=1.0) for s in CENSUS_NULL_SENTINELS) ? missing : v
    end

_maybe_float(x) = ismissing(x) ? missing : Float64(x)
_fmt(x) = ismissing(x) ? "" : (x isa Integer ? string(x) : @sprintf("%.6f", x))

"""Sum a set of ACS variables from a raw record; return missing if all are missing."""
function _bracket_sum(raw::Dict, keys::Vector{String})
    total = 0.0; any_val = false
    for k in keys
        v = _to_float(get(raw, k, nothing))
        ismissing(v) && continue
        total += v; any_val = true
    end
    return any_val ? total : missing
end

"""
    get_census_network_name(network_name) -> String

Map network name aliases to canonical directory-friendly name
(mirrors `get_solar_network_name`).
"""
function get_census_network_name(network_name::String)
    mapping = Dict(
        "RTS" => "RTS", "RTS_GMLC" => "RTS",
        "Texas7k" => "Texas7k",
        "Texas2k" => "texas2k", "ACTIVSg2000" => "texas2k",
        "WECC10k" => "WECC10k", "ACTIVSg10k" => "WECC10k",
        "WECC240" => "WECC240", "pserc240" => "WECC240",
        "CATS" => "CATS",
    )
    return get(mapping, network_name, network_name)
end
