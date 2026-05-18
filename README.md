# GridPlanning.jl

[![CI](https://github.com/rpiansky3/GridPlanning.jl/actions/workflows/ci.yml/badge.svg)](https://github.com/rpiansky3/GridPlanning.jl/actions/workflows/ci.yml)

A Julia package for transmission grid planning on realistic power system networks. Provides DC and linearized AC formulations for co-optimizing line switching, line hardening, battery storage siting, and solar PV siting against load shedding, cost, and risk-exposure objectives. Applications include planning under severe-weather risk such as wildfires, with built-in support for USGS Fire Potential Index data.

## Table of Contents
- [Overview](#overview)
- [Installation](#installation)
- [Repository Structure](#repository-structure)
- [Available Data](#available-data)
- [Models and Methods](#models-and-methods)
- [Quick Start](#quick-start)
- [Tutorial](#tutorial)
- [Command-Line Interface](#command-line-interface)
- [Usage Guide](#usage-guide)
- [Results Dictionary](#results-dictionary)
- [Plotting](#plotting)
- [Examples](#examples)
- [Dependencies](#dependencies)
- [Testing](#testing)
- [Citation](#citation)
- [License](#license)
- [Contact](#contact)
- [Acknowledgments](#acknowledgments)

## Overview

This package provides a unified interface for transmission grid planning problems on realistic power system networks. Operational decisions (line switching) and capital investments (line hardening, battery storage siting, solar PV siting) are co-optimized under a single objective — load shedding, generation cost, risk exposure, or a weighted tradeoff. The per-line risk interface is hazard-agnostic; the package ships with built-in data loaders for severe-weather risk applications, currently wildfire risk via the USGS Fire Potential Index.

**Key Features:**
- **Two formulations**: DC Optimal Transmission Switching (DCOTS) and Linear AC Optimal Transmission Switching (LACOTS)
- **Multiple objective functions**: Load shedding minimization, risk-exposure minimization, generation cost minimization, and customizable tradeoffs
- **Two switching methods**: Optimal MIP-based and fast thresholded heuristic
- **Line hardening**: Optimize infrastructure investments (vegetation management, covered conductors, or undergrounding) to permanently reduce per-line risk exposure
- **Battery energy storage systems (BESS)**: Optimize battery installation and operation for load shedding mitigation
- **Solar PV installation**: Optimize solar capacity placement with hourly capacity factors and inverter reactive power support (LACOTS)
- **Hazard-agnostic risk interface**: Accept any per-line risk signal; built-in loader for USGS Fire Potential Index (wildfire) included
- **Multi-period optimization**: Solve for single days, specific date ranges, or entire months/years
- **Flexible network support**: Pre-configured for 6+ realistic power system test cases (RTS-GMLC, CATS, Texas7k, ACTIVSg2000/10k, WECC240)

## Installation

### Prerequisites
- Julia 1.10 or higher (LTS; 1.6+ is technically compatible but 1.10 is recommended)
- Gurobi optimizer with valid license ([academic licenses available](https://www.gurobi.com/academia/academic-program-and-licenses/))

### Setup

**Option A — install directly via Julia Pkg (no clone needed):**
```julia
using Pkg
Pkg.add(url="https://github.com/rpiansky3/GridPlanning.jl")
using GridPlanning
```

**Option B — clone and develop locally:**

1. Clone this repository:
```bash
git clone https://github.com/rpiansky3/GridPlanning.jl.git
cd GridPlanning.jl
```

2. Instantiate the package environment:
```bash
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

3. Test the installation:
```julia
julia --project=. -e 'using GridPlanning; println("OK")'
```

## Repository Structure

```
GridPlanning.jl/
├── src/
│   ├── GridPlanning.jl             # Main module and solve_ots() function
│   ├── preprocessing.jl            # Time parsing, data loading, load generation
│   ├── add_variables.jl            # Variable definitions for DCOTS and LACOTS
│   ├── add_constraints.jl          # Power flow and operational constraints
│   ├── add_objective.jl            # Objective function formulations
│   ├── base_OPS.jl                 # Core optimization solver
│   ├── save_results.jl             # Output formatting and serialization
│   ├── plotting.jl                 # plot_results() and all plot generation
│   ├── plotting_helpers.jl         # Shared plotting utilities and color maps
│   ├── solar_data.jl               # PVWatts solar capacity-factor fetcher
│   ├── population_assignment.jl    # Tract → bus radius assignment for census aggregation
│   └── census_data.jl              # Census ACS fetch + per-bus demographic aggregation
├── data/                           # Full dataset (gitignored — see test_data/ for GitHub subset)
│   ├── networks/                   # Power system test cases (.m format)
│   ├── CATS/                       # California Test System specific data
│   ├── USGS_FPI/                   # Wildfire risk data
│   ├── bus_lat_lons/               # Geographic coordinates for networks
│   ├── US_Shapefiles/              # US state and tract boundaries for visualization
│   ├── solar_data/                 # PVWatts hourly capacity factors per network
│   └── census_data/                # Per-bus Census ACS demographics
├── test_data/                      # June reference subset (June 2020; June 2021 for RTS)
│   ├── networks/                   # Same structure as data/
│   ├── CATS/                       # June-only CATS time-series
│   ├── USGS_FPI/                   # Wildfire risk data (June only)
│   ├── bus_lat_lons/
│   ├── US_Shapefiles/
│   └── solar_data/                 # Solar capacity factors (small networks only)
├── tutorial.ipynb                  # Jupyter notebook walkthrough
├── LICENSE                         # MIT license
├── Project.toml                    # Package dependencies
└── README.md                       # This file
```

## Available Data

### Included Reference Dataset

This repository ships with a **reference dataset (`test_data/`) limited to June 2020** (June 2021 for RTS) for all six networks. This subset is sufficient for testing, demos, and single-month analyses. For other time periods, use `fetch_wfpi_data.jl` to download WFPI risk data, or supply custom data via the `:risk_per_line` parameter.

The full dataset lives in `data/` (gitignored). To regenerate `test_data/` from `data/`, run:
```bash
julia scripts/generate_reference_data.jl
```

### Solar Capacity Factor Data

Solar capacity factor data (TMY hourly profiles from NREL PVWatts) is included in `test_data/solar_data/` for small networks only, due to GitHub's 100 MB file size limit:

| Network | Included in repo |
|---------|-----------------|
| RTS     | ✓ |
| WECC240 | ✓ |
| texas2k | ✓ |
| Texas7k | ✗ (157 MB) |
| CATS    | ✗ (196 MB) |
| WECC10k | ✗ (230 MB) |

To generate solar data locally for any network, run:
```bash
export NREL_API_KEY=your_key_here  # get a free key at https://developer.nlr.gov/signup/
julia --project=scripts scripts/generate_solar_data.jl --network Texas7k
```
This fetches TMY data from the NREL PVWatts API and writes to `data/solar_data/{Network}/solar_data.csv`. Then re-run `generate_reference_data.jl` to populate `test_data/solar_data/`.

### Census Demographic Data

Per-bus Census ACS 5-year demographics (total population, households, race, Hispanic/Latino ethnicity, poverty, household-income brackets, median income) are pulled via the Census Data API and aggregated from census tracts to load buses.

The pipeline runs in three stages:

1. **Tract selection.** Every census tract whose centroid lies within a per-bus radius (default 25 km) of *any* bus is selected. This union-of-disks filter keeps sparse networks (e.g. WECC240) from pulling tracts in the empty regions between distant buses.
2. **ACS fetch.** The Census Data API (`api.census.gov/data`, free) returns demographics for each selected tract. A free key is optional — anonymous access is capped at ~500 requests per day. Get one at <https://api.census.gov/data/key_signup.html>.
3. **Tract → bus aggregation.** A 3-pass radius algorithm assigns tract populations to load buses (guaranteeing every populated tract is covered and every load bus receives population), then tract-level counts are summed with weights to per-bus totals. `median_income` is population-weighted across assigned tracts.

Generate data for a network:
```bash
export CENSUS_API_KEY=your_key_here   # optional
julia --project=. scripts/generate_census_data.jl --network RTS
julia --project=. scripts/generate_census_data.jl --network WECC240 --radius-km 50
julia --project=. scripts/generate_census_data.jl --network RTS --weighting proportional
julia --project=. scripts/generate_census_data.jl --network RTS --acs-year 2021
```

Requires the national tract shapefile (~100 MB, gitignored):
```bash
curl -L -o data/US_Shapefiles/cb_2023_us_tract_500k.zip \
  https://www2.census.gov/geo/tiger/GENZ2023/shp/cb_2023_us_tract_500k.zip
unzip -o data/US_Shapefiles/cb_2023_us_tract_500k.zip -d data/US_Shapefiles/
```

Output: a single CSV per (network, ACS year) at `data/census_data/{Network}_census_{Year}.csv`:

| Column | Description |
|---|---|
| `Bus_ID` | Bus identifier matching the network case file |
| `total_pop` | Weighted sum of tract population (B01003_001E) |
| `num_households` | Weighted sum of households (B11001_001E) |
| `num_white`, `num_black`, `num_native`, `num_asian` | Race counts (B02001_002–005E) |
| `num_hispanic` | Hispanic/Latino count (B03003_003E) |
| `num_below_poverty`, `num_above_poverty` | Poverty counts (B17001_001/002E) |
| `num_low_income`, `num_middle_income`, `num_high_income` | Households with income <$35k / $35–100k / ≥$100k (B19001 brackets) |
| `median_income` | Population-weighted median household income ($) (B19013_001E) |

All `num_*` columns are absolute counts (`Σ weight × tract_count` over assigned tracts); derive percentages downstream as needed. Rows are emitted only for load buses (buses with non-zero active load).

**Weighting modes** (`--weighting`):

- `inverse` (default) — `w_i = (1/d_i) / Σ(1/d_j)`. Closer buses get larger shares.
- `proportional` — `w_i = d_i / Σ d_j`. Matches the original spec literally; farther buses get larger shares.

**Plot overlay** on `:network_overview`: pass `census_overlay=:median_income` (or `:pct_poverty`, `:pct_nonwhite`) to `plot_results` to color each load bus by the metric. The plot falls back gracefully with a warning if the CSV is absent.

Load results back into Julia with `load_census_data(network; acs_year=2022)`.

### Data Sources

**Full CATS Load Data:**
- The full California Test System load data file can be downloaded from the [CATS-CaliforniaTestSystem repository](https://github.com/WISPO-POP/CATS-CaliforniaTestSystem)
- The included reference dataset contains June hours only

**Full Wildfire Risk Data:**
- Wildfire risk data for additional time periods is available upon request
- Contact the repository maintainers for access

### Power System Networks

| Network Name | Buses | Generators | Lines | Aliases |
|-------------|-------|------------|-------|---------|
| RTS-GMLC | 73 | 158 | 120 | `"RTS"`, `"RTS_GMLC"` |
| California Test System | 8,870 | 3,892 | 10,823 | `"CATS"`, `"CaliforniaTestSystem"` |
| Texas 7k | 6,717 | 731 | 9,140 | `"Texas7k"` |
| ACTIVSg 2000 | 2,000 | 544 | 3,206 | `"Texas2k"`, `"ACTIVSg2000"` |
| ACTIVSg 10k | 10,000 | 2,485 | 12,706 | `"WECC10k"`, `"ACTIVSg10k"` |
| WECC 240 | 240 | 143 | 448 | `"WECC240"`, `"pserc240"` |

### Network Credits and Sources

- **California Test System (CATS)**: Obtained from the [CATS-CaliforniaTestSystem](https://github.com/WISPO-POP/CATS-CaliforniaTestSystem) repository by WISPO-POP
- **RTS-GMLC**: From the [RTS-GMLC](https://github.com/GridMod/RTS-GMLC) repository, developed by the Grid Modernization Lab Consortium
- **ACTIVSg Test Cases** (Texas2k, WECC10k): Synthetic test cases from Texas A&M University. See [ACTIVSg documentation](https://electricgrids.engr.tamu.edu/electric-grid-test-cases/)
- **Texas 7k**: Texas synthetic 7000-bus test case
- **WECC 240**: PSERC 240-bus test case from the [PGLib-OPF](https://github.com/power-grid-lib/pglib-opf) library

### Wildfire Risk Data

Wildfire risk data is automatically loaded from the USGS Fire Potential Index (FPI) based on the network and time specification.

> **Note:** The included dataset only covers **June 2020** (June 2021 for RTS). For other time periods, supply custom data via the `:risk_per_line` parameter or contact the maintainers for the full dataset.

**Standard Networks** (RTS, Texas7k, Texas2k, WECC10k, WECC240):
- Data stored per day in JLD2 format
- Location: `data/USGS_FPI/{network}/{year}/forecast_day_1/`
- File format: `FPI_{network}_fday1_year{year}_month{month}_day{day}.jld2`
- Contains: `Dict{Int,Float64}` mapping line ID to risk value

**CATS Network**:
- Data stored in annual CSV files
- Location: `data/USGS_FPI/CATS/{year}_risk.csv`
- Columns: `date_of_forecast`, `branch_id`, `max_wfpi`, `mean_wfpi`, `cum_wfpi`, etc.
- Select risk metric via `:risk_metric` parameter (default: `"cum_wfpi"`)

## Models and Methods

### Optimization Models

#### DCOTS (DC Optimal Transmission Switching)
- Uses linearized DC power flow approximation
- Decision variables: voltage angles, generation, power flows, load shedding, line switching
- Optional: line hardening decisions (y variables)
- Computationally efficient for large-scale problems
- Ignores reactive power and voltage magnitude constraints

#### LACOTS (Linear AC Optimal Transmission Switching)
- Uses linearized AC power flow
- Includes reactive power and voltage magnitude variables
- Optional: line hardening decisions (y variables)
- More accurate representation of AC power systems
- Can warm-start from DCOTS solution for faster convergence (includes z and y values)

### Solution Methods

#### Optimal Method (default)
- Solves a Mixed-Integer Programming (MIP) problem for line switching decisions
- Binary `z[d,l]` variables for each risky line switching decision
- If a `threshold` or `threshold_pct` is provided, adds a linear risk constraint: energized risk ≤ threshold × total_risk (hardening is credited toward the threshold)
- If no threshold is provided and the objective includes wildfire risk (e.g., `"wildfire"`, `"tradeoff"`), risk minimization is handled in the objective
- If hardening is enabled, binary `y[l]` variables are always added regardless of switching method
- **Pros**: Globally optimal switching decisions, optimality guarantees
- **Cons**: Slower solve times (seconds to minutes for large systems)

#### Thresholded Method
- Fast heuristic that pre-determines switching decisions before solving
- Sorts risky lines by wildfire risk and de-energizes the riskiest ones to meet the specified threshold (`threshold` or `threshold_pct` required)
- Switching variables are fixed scalars; the remaining problem is solved as an LP (or MIP if hardening is enabled)
- If hardening is enabled, binary `y[l]` variables are still solved optimally within the LP/MIP
- **Pros**: 2-10x faster solve times for large-scale studies
- **Cons**: Switching decisions are suboptimal; threshold parameter is required
- **Use cases**: Large-scale studies, Monte Carlo analysis, initial screening

### Objective Functions

| Objective | Description | Primary Term | Secondary Term |
|-----------|-------------|--------------|----------------|
| `"loadshed"` | Minimize load shedding | Total load shed | Small switching cost penalty |
| `"wildfire"` | Minimize wildfire risk | Normalized active risk | Small load shedding penalty |
| `"cost"` | Minimize operational cost | Generation cost + VOLL × load shed | N/A |
| `"tradeoff"` | Weighted combination | (1-w) × normalized load shed | w × normalized risk |

### Line Hardening

The package supports transmission line hardening as a wildfire risk mitigation strategy alongside operational switching decisions. The hardening decision represents a permanent physical intervention — vegetation management, covered conductors, or undergrounding — that reduces a line's wildfire risk contribution by a user-defined effectiveness factor. The default cost parameter (`$7M/mile`) reflects undergrounding; adjust `:hardening_cost_per_mile` to model other methods.

**Key Concepts:**
- **Decision variable y[l]**: Binary variable indicating whether line l is hardened (1) or not (0)
- **Risk mitigation**: Hardened lines have their wildfire risk reduced by an effectiveness factor (default: 100%)
- **Energization enforcement**: Hardened lines must remain energized (cannot be switched off)
- **Cost-based optimization**: Balances hardening cost against operational benefits

**Budget Handling:**
- **Non-cost objectives** (loadshed, wildfire, tradeoff): Budget is required (default: $1B if not specified)
- **Cost objective**: Budget is optional (default: unlimited). Hardening cost appears in objective function.

**Thresholded Method with Hardening:**
When using the thresholded method with hardening enabled, switching and hardening decisions are decoupled:
- Switching decisions (`z`) are pre-computed by sorting lines by risk and de-energizing the riskiest ones to meet the threshold
- Hardening decisions (`y`) remain binary optimization variables solved optimally by the LP/MIP solver
- Hardenable lines that were thresholded off use `y[l]` as their effective energization variable in power flow constraints — a hardened line is re-energized with zero wildfire risk contribution
- The shared infrastructure budget is enforced as a linear constraint over the binary `y` variables (and any battery/solar variables)

**Objective Modifications:**
- **loadshed**: Adds small penalty for not hardening: `+ 0.01 * Σ(1-y[l])`
- **wildfire**: Risk from hardened lines is reduced: `risk[l] * (1 - effectiveness * y[l])`
- **cost**: Adds hardening cost: `+ Σ(cost_per_mile * length[l] * y[l])`
- **tradeoff**: Uses modified risk calculation from wildfire objective

## Quick Start

The repository ships with a reference dataset in `test_data/` covering June 2020 for all six networks. Use `:data_dir => "test_data"` to run immediately after cloning — no additional data download required.

```julia
using GridPlanning

# Works out of the box using the included test_data/ reference dataset
opt_parameters = Dict(
    :network   => "RTS",
    :model     => "DCOTS",
    :objective => "loadshed",
    :times     => [(2020, 6, 15)],   # June 15, 2020 — available for all 6 networks
    :data_dir  => "test_data"
)

results = solve_ots(opt_parameters)

println("Solve time: $(results[:solve_time]) seconds")
println("Total load shed: $(results[:total_load_shed]) MW")
println("Risk reduction: $(results[:risk_reduction_pct])%")
println("Lines switched off: $(length(results[:switched_off_lines][1]))")
```

To verify all six networks load and solve correctly:

```bash
julia --project=. scripts/verify_reference_data.jl
```

> **Note:** `test_data/` covers June 2020 (June 15–16 for CATS; June 4–30 for RTS; full June for all others). For other dates or the full dataset, omit `:data_dir` (defaults to `"data/"`) and download wildfire risk data via `scripts/fetch_wfpi_data.jl`.

## Tutorial

A Jupyter notebook walkthrough is included at [`tutorial.ipynb`](tutorial.ipynb). It covers the core API end-to-end on the RTS network — basic solve, switching methods, hardening, battery and solar siting, the tradeoff curve, and plotting — using only the bundled `test_data/` so it runs out of the box after `Pkg.instantiate()` and a Gurobi license.

```bash
julia --project=. -e 'using IJulia; notebook(dir=".")'
```

Then open `tutorial.ipynb` from the Jupyter file browser.

## Command-Line Interface

For users who prefer working from the terminal, GridPlanning includes a command-line interface (CLI) via the `scripts/run_ots.jl` script.

### Basic CLI Usage

```bash
julia --project=. scripts/run_ots.jl --network RTS --objective loadshed --date 2021-07-15
```

### CLI Arguments

**Required Arguments:**
- `--network, -n` - Network name (RTS, CATS, Texas7k, Texas2k, WECC10k, WECC240)
- `--objective, -o` - Objective function (loadshed, wildfire, cost, tradeoff)

**Date Specification (choose one):**
- `--date, -d` - Single date (YYYY-MM-DD)
- `--dates` - Multiple dates comma-separated (YYYY-MM-DD,YYYY-MM-DD,...)
- `--month` - Full month (e.g., "June 2021")
- `--year, -y` - Full year (e.g., "2020")

**Model and Method:**
- `--model, -m` - Model type: DCOTS or LACOTS (default: DCOTS)
- `--method` - Solution method: optimal or thresholded (default: optimal)

**Method Parameters:**
- `--threshold` - Absolute risk threshold (required for thresholded; adds risk constraint for optimal)
- `--threshold-pct` - Percentage risk threshold, 0-1 (required for thresholded; adds risk constraint for optimal)

**Objective Parameters:**
- `--tradeoff-weight, -w` - Weight for tradeoff objective, 0-1 (default: 0.5)
- `--voll` - Value of lost load in USD/MWh for cost objective (default: 10000.0)

**CATS-Specific:**
- `--risk-metric` - Risk metric for CATS: max_wfpi, mean_wfpi, cum_wfpi (default: cum_wfpi)

**Solver Parameters:**
- `--time-limit, -t` - Solver time limit in seconds (default: 86400.0)
- `--mip-gap` - MIP optimality gap, e.g., 0.01 = 1% (default: 0.01)

**Output Options:**
- `--save, -s` - Save results to file (JLD2 or TXT based on extension)
- `--quiet, -q` - Suppress detailed output
- `--T` - Hours per day (default: 24)

**Hardening Parameters:**
- `--hardening` - Enable line hardening optimization (vegetation management, covered conductors, or undergrounding)
- `--hardening-effectiveness` - Risk reduction effectiveness, 0-1 (default: 1.0)
- `--hardening-cost-per-mile` - Hardening cost per mile in USD (default: $7M)
- `--hardening-budget` - Hardening budget in USD (default: $1B for non-cost objectives)
- `--hardening-no-enforce-energization` - Allow hardened lines to be de-energized

**Battery Parameters:**
- `--battery` - Enable battery energy storage installation
- `--battery-cost-per-pu` - Cost per p.u. (100MWh) in USD (default: $100M)
- `--battery-charge-efficiency` - Charging efficiency, 0-1 (default: 0.95)
- `--battery-discharge-efficiency` - Discharging efficiency, 0-1 (default: 0.95)
- `--battery-charge-rate` - Max charge rate as fraction of capacity (default: 1.0)
- `--battery-discharge-rate` - Max discharge rate as fraction of capacity (default: 1.0)
- `--battery-max-network` - Network-wide capacity limit in p.u. (default: unlimited)
- `--battery-max-per-node` - Per-node capacity limit in p.u. (default: 10000)
- `--battery-exclusive-operation` - Limit simultaneous charging and discharging
- `--battery-candidate-buses` - Comma-separated bus IDs or "load_buses"
- `--linearized-battery-power` - Linear (true) or nonlinear (false) reactive power for LACOTS (default: true)

**Solar Parameters:**
- `--solar` - Enable solar PV installation
- `--solar-cost-per-pu` - Cost per p.u. (100MW) in USD (default: $100M)
- `--solar-data-path` - Path to CSV with hourly capacity factors
- `--solar-capacity-factor-default` - Default capacity factor, 0-1 (default: 0.3)
- `--solar-max-network` - Network-wide capacity limit in p.u. (default: unlimited)
- `--solar-max-per-node` - Per-node capacity limit in p.u. (default: 10000)
- `--solar-candidate-buses` - Comma-separated bus IDs for solar candidates
- `--linearized-solar-power` - Linear (true) or nonlinear (false) inverter capability for LACOTS (default: true)

**Infrastructure Budget:**
- `--infrastructure-budget` - Shared budget for batteries + solar + hardening in USD (default: $1B for non-cost, unlimited for cost)

### CLI Examples

**Example 1: Basic single-day optimization**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective loadshed \
    --date 2021-07-15
```

**Example 2: Fast thresholded method**
```bash
julia --project=. scripts/run_ots.jl \
    --network Texas7k \
    --objective loadshed \
    --date 2021-06-11 \
    --method thresholded \
    --threshold-pct 0.5 \
    --time-limit 300 \
    --quiet
```

**Example 3: Tradeoff objective with custom weight**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective tradeoff \
    --date 2021-07-15 \
    --tradeoff-weight 0.7 \
    --method optimal
```

**Example 4: Multiple dates**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective wildfire \
    --dates "2021-07-15,2021-07-16,2021-07-17"
```

**Example 5: Full month optimization**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective loadshed \
    --month "July 2021" \
    --mip-gap 0.02
```

**Example 6: Save results to file**
```bash
julia --project=. scripts/run_ots.jl \
    --network Texas2k \
    --objective loadshed \
    --year "2020" \
    --method thresholded \
    --threshold-pct 0.4 \
    --save results/texas2k_2020.jld2
```

**Example 7: CATS network with custom risk metric**
```bash
julia --project=. scripts/run_ots.jl \
    --network CATS \
    --objective tradeoff \
    --date 2021-08-15 \
    --risk-metric max_wfpi \
    --tradeoff-weight 0.6
```

**Example 8: Cost minimization**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective cost \
    --date 2021-07-15 \
    --voll 10000 \
    --quiet
```

**Example 9: Line hardening optimization**
```bash
julia --project=. scripts/run_ots.jl \
    --network RTS \
    --objective loadshed \
    --date 2021-07-15 \
    --hardening \
    --hardening-budget 50000000 \
    --hardening-effectiveness 1.0 \
    --save results/rts_hardening.jld2
```

**Example 10: Thresholded method with hardening**
```bash
julia --project=. scripts/run_ots.jl \
    --network Texas7k \
    --objective loadshed \
    --dates "2021-06-11,2021-06-12,2021-06-13" \
    --method thresholded \
    --threshold-pct 0.5 \
    --hardening \
    --hardening-budget 100000000
```

### CLI Output

The CLI displays optimization progress and results in a formatted output:

**Detailed Output (default):**
```
======================================================================
WILDFIRE SWITCHING OPTIMIZATION
======================================================================

Network:   RTS
Model:     DCOTS
Objective: loadshed
Method:    optimal

Running optimization...

======================================================================
OPTIMIZATION RESULTS
======================================================================

Solution Status
   Status:          OPTIMAL
   Solve Time:      0.35 seconds
   Method:          optimal
   Objective Value: 125.4321

Load Shedding
   Total Load Shed: 125.43 MW

Wildfire Risk
   Total Risk:      1234.56
   Active Risk:     617.28
   Removed Risk:    617.28
   Risk Reduction:  50.0%

Line Switching
   Total Lines Switched Off: 15

🛡️  Line Hardening
   Lines Hardened:      8
   Hardening Cost:      $48.30M
   Risk Mitigated:      425.12
   Risk Mitigation:     34.4%

🔋 Battery Storage
   Buses Installed:     5
   Total Capacity:      250.0 MWh (2.5000 p.u.)
   Battery Cost:        $50.00M

☀️  Solar PV
   Buses Installed:     3
   Total Capacity:      150.0 MW (1.5000 p.u.)
   Solar Cost:          $75.00M
   Total Generation:    12.3456 p.u.·h

======================================================================
```

**Note:** The Line Hardening, Battery Storage, and Solar PV sections only appear when the respective features are enabled.

**Quiet Output (--quiet flag):**
```
Status: OPTIMAL | Time: 0.35s | Load Shed: 125.43 MW | Risk Reduction: 50.0%
```

## Usage Guide

### Basic API

The main function is `solve_ots(opt_parameters)` which takes a single dictionary and returns a results dictionary.

```julia
using GridPlanning
results = solve_ots(opt_parameters)
```

### Required Parameters

```julia
opt_parameters = Dict(
    :network => "RTS",                    # Network name (see Available Data)
    :model => "DCOTS",                    # "DCOTS" or "LACOTS"
    :objective => "tradeoff",             # "loadshed", "wildfire", "cost", "tradeoff"
    :times => [(2021, 7, 15)]             # Time specification (see below)
)
```

### Optional Parameters

```julia
# Solution method
:switching_method => "optimal"    # "optimal" (MIP) or "thresholded" (heuristic)

# Wildfire data
:risk_per_line => nothing         # Custom risk data: Dict{Int => Dict{Int => Float64}}
                                   # day => (line_id => risk_value). Auto-loaded if not provided
:risk_metric => "cum_wfpi"        # For CATS: "max_wfpi", "mean_wfpi", "cum_wfpi"

# Temporal parameters
:T => 24                          # Hours per day (default: 24)

# Objective-specific parameters
:tradeoff_weight => 0.5           # For "tradeoff": 0=loadshed only, 1=wildfire only
:voll => 10000.0                  # Value of Lost Load ($/MWh) for "cost" objective

# Threshold parameters
# - Required for switching_method="thresholded" (determines which lines are pre-de-energized)
# - Optional for switching_method="optimal": adds a risk constraint (energized risk ≤ threshold × total_risk)
#   Hardening is credited toward the constraint (hardened lines reduce active risk)
:threshold => nothing             # Absolute risk threshold (in risk units)
:threshold_pct => nothing         # Percentage threshold (0.8 = keep 80% of risk active, remove 20%)

# LACOTS warm start
:warm_start => nothing            # Dict from DCOTS results, or "auto" to run DCOTS first
:non_linear => false              # Use non-linear apparent power constraints

# Solver parameters
:time_limit => 86400.0            # Solver time limit (seconds, default: 24 hours)
:mip_gap => 0.01                  # MIP optimality gap (default: 1%)

# Output parameters
:output_format => "dict"          # "dict", "jld2", or "txt"
:output_path => nothing           # File path (required for jld2/txt formats)
:lp_str => ""                     # If provided, save model to LP file at this path
:log_str => ""                    # If provided, save Gurobi log to file at this path

# Auto-plotting (triggered at end of solve_ots)
:plots    => false,               # false/"none" = no plots; "all" = network_overview + timeseries;
                                  # "inv_only" = network_overview only; "timeseries_only" = timeseries only
:plot_dir => ""                   # Directory to save plots (default: current directory)
                                  # Created automatically if it does not exist

# Hardening parameters (models vegetation management, covered conductors, or undergrounding)
:hardening_enabled => false                # Enable line hardening optimization
:hardening_effectiveness => 1.0            # Risk reduction factor, 0-1 (1.0 = full mitigation)
:hardening_cost_per_mile => 7e6            # Cost per mile in USD (default: $7M)
:hardening_enforce_energization => true    # If hardened, must remain energized
:hardening_candidate_lines => nothing      # Vector{Int}: specific lines to consider (default: all risky lines)

# Battery energy storage system (BESS) parameters
:battery_enabled => false                  # Enable battery installation optimization
:battery_cost_per_pu => 1e8                # Cost per p.u. (100MWh) of battery capacity ($)
:battery_charge_efficiency => 0.95         # Charging efficiency (0-1)
:battery_discharge_efficiency => 0.95      # Discharging efficiency (0-1)
:battery_soc_carryover => 0.999958         # SOC decay between hours (~1%/week)
:battery_charge_rate => 1.0                # Max charge rate as fraction of capacity (p.u./hour)
:battery_discharge_rate => 1.0             # Max discharge rate as fraction of capacity (p.u./hour)
:battery_max_network => nothing            # Network-wide capacity limit (p.u., default: unlimited)
:battery_max_per_node => nothing           # Per-node capacity limit (p.u., default: 10000)
:battery_exclusive_operation => false      # Limit simultaneous charge/discharge
:battery_candidate_buses => nothing        # Vector{Int}, "load buses", or nothing (all buses)
:linearized_battery_power => true          # For LACOTS: linear (true) or nonlinear (false) reactive power

# Solar PV installation parameters
:solar_enabled => false                    # Enable solar installation optimization
:solar_cost_per_pu => 1e8                  # Cost per p.u. (100MW) of solar capacity ($)
:solar_data_path => nothing                # Path to CSV with hourly capacity factors
:solar_capacity_factor_default => 0.3      # Default CF if no data provided (0-1)
:solar_max_network => nothing              # Network-wide capacity limit (p.u., default: unlimited)
:solar_max_per_node => nothing             # Per-node capacity limit (p.u., default: 10000)
:solar_candidate_buses => nothing          # Vector{Int} or nothing (all buses)
:linearized_solar_power => true            # For LACOTS: linear (true) or nonlinear (false) inverter capability

# Shared infrastructure budget (batteries + solar + hardening)
:infrastructure_budget => nothing          # Budget in USD (default: $1B for non-cost objectives, unlimited for cost)
```

### Time Specification Formats

```julia
# Single day
:times => [(2021, 7, 15)]

# Multiple specific days
:times => [(2021, 7, 15), (2021, 7, 16), (2021, 7, 17)]

# Full year (all 365/366 days)
:times => "2020"

# Full month
:times => "June 2021"
:times => "Jun 2021"
```

The number of days `D` is automatically calculated, resulting in `D × T` time periods.

## Results Dictionary

The `solve_ots()` function returns a dictionary with the following keys:

### Optimization Status
- `:status` - Termination status (e.g., `OPTIMAL`, `TIME_LIMIT`)
- `:solve_time` - Solver runtime in seconds
- `:objective_value` - Final objective function value
- `:switching_method` - Solution method used (`"optimal"` or `"thresholded"`)

### Decision Variables
- `:z` - Line switching decisions `[D × risky_lines]` (1=energized, 0=de-energized)
- `:va` - Voltage angles `[D × T × buses]` (radians)
- `:p` - Real power flows `[D × T × branches]` (MW)
- `:g` or `:pg` - Real power generation `[D × T × generators]` (MW)
- `:load_shedding` or `:p_load_shedding` - Load shedding `[D × T × buses]` (MW)

**LACOTS only:**
- `:vm` - Voltage magnitudes `[D × T × buses]` (per unit)
- `:q` - Reactive power flows `[D × T × branches]` (MVAr)
- `:qg` - Reactive power generation `[D × T × generators]` (MVAr)
- `:q_load_shedding` - Reactive load shedding `[D × T × buses]` (MVAr)

### Summary Metrics
- `:total_load_shed` - Total load shedding across all periods (MW)
- `:total_risk` - Total possible wildfire risk (baseline)
- `:active_risk` - Wildfire risk from energized lines (accounts for hardening if enabled)
- `:removed_risk` - Wildfire risk eliminated by switching
- `:risk_reduction_pct` - Percentage of risk removed
- `:switched_off_lines` - Dict mapping day index to list of de-energized line IDs

**Hardening Results (if hardening enabled):**
- `:y` - Line hardening decisions `[hardenable_lines]` (1=hardened, 0=not hardened)
- `:hardened_lines` - Vector of hardened line IDs
- `:hardening_cost` - Total hardening cost in USD
- `:mitigated_risk` - Wildfire risk mitigated by hardening

**Battery Results (if battery enabled):**
- `:x` - Battery capacity decisions `[battery_locs]` (p.u., where 1 p.u. = 100 MWh)
- `:soc` - State of charge `[D × (0:T) × battery_locs]` (p.u.)
- `:p_charge` - Active power charging `[D × T × battery_locs]` (p.u.)
- `:p_discharge` - Active power discharging `[D × T × battery_locs]` (p.u.)
- `:q_charge` - Reactive power charging (LACOTS only, p.u.)
- `:q_discharge` - Reactive power discharging (LACOTS only, p.u.)
- `:batteries_installed` - Vector of bus IDs with installed capacity ≥ 0.01 p.u.
- `:total_battery_capacity` - Sum of all installed capacity (p.u.)
- `:battery_cost` - Total battery installation cost in USD

**Solar Results (if solar enabled):**
- `:s` - Solar capacity decisions `[solar_locs]` (p.u., where 1 p.u. = 100 MW)
- `:p_solar` - Active power generation `[D × T × solar_locs]` (p.u.)
- `:q_solar` - Reactive power injection (LACOTS only, p.u., bidirectional)
- `:solar_installed` - Vector of bus IDs with installed capacity ≥ 0.01 p.u.
- `:total_solar_capacity` - Sum of all installed capacity (p.u.)
- `:solar_cost` - Total solar installation cost in USD
- `:total_solar_generation` - Total active power generated (p.u.·h)
- `:total_solar_q_injection` - Total reactive power injected (LACOTS only, p.u.·h)

**Notes:**
- For the thresholded method, `:z` values are pre-computed fixed scalars (0 or 1), not optimization variables
- `:y` values are always binary optimization variables when hardening is enabled, regardless of switching method
- When hardening is enabled, `:active_risk` accounts for risk reduction from hardened lines
- Battery capacity `:x[n]` is a continuous variable (p.u.); buses with capacity < 0.01 p.u. are considered uninstalled
- Solar capacity `:s[n]` is a continuous variable (p.u.); buses with capacity < 0.01 p.u. are considered uninstalled

## Plotting

```julia
plot_results(results_input, features::Vector{Symbol};
             format::String="pdf",
             output_dir::String=".",
             day::Union{Nothing,Int}=nothing,
             infrastructure_off::Bool=false,
             ls_off::Bool=false,
             plot_dir::String="",
             kwargs...)
```

**Arguments:**
- `results_input`: Dict from `solve_ots()`, String path to `.jld2`, or `Vector{Dict}` for `:tradeoff_curve`
- `features`: vector of plot symbols to generate (see below)
- `format`: output format — `"pdf"` (default), `"png"`, `"svg"`, `"eps"`
- `output_dir`: directory to write output files
- `plot_dir`: alias for `output_dir`; takes precedence over `output_dir` if non-empty
- `day`: `nothing` (aggregate) or `Int` (day-specific) for the network overview
- `infrastructure_off`: suppress hardened line overlays, battery markers, and solar markers on the network overview
- `ls_off`: suppress load shed bubbles on the network overview
- `census_overlay`: `nothing` (default) or a `Symbol` (`:median_income`, `:pct_poverty`, `:pct_nonwhite`) — color each load bus on `:network_overview` by the metric; requires `data/census_data/{Network}_census_{Year}.csv`. See [Census Demographic Data](#census-demographic-data).

**Feature symbols:**

| Symbol | Description |
|--------|-------------|
| `:network_overview` | Geographic plot: risk-colored lines, de-energized lines, hardened lines, battery/solar markers, load shed bubbles |
| `:load_shed_timeseries` | Time series of load shedding across all periods |
| `:battery_dispatch` | Per-bus battery charge/discharge/SOC dispatch |
| `:solar_generation` | Per-bus solar active (and reactive, LACOTS) generation |
| `:generation_dispatch` | Generator dispatch over time |
| `:tradeoff_curve` | Load shed vs. risk tradeoff curve (requires `Vector{Dict}` input) |
| `:cost_breakdown` | Bar chart of cost components |

**Examples:**

```julia
# Full network overview with all layers
plot_results(results, [:network_overview, :battery_dispatch]; format="pdf", output_dir="figures/")

# Network overview without infrastructure or load shed overlays
plot_results(results, [:network_overview]; infrastructure_off=true, ls_off=true, output_dir="figures/")

# Load results from file and plot
plot_results("run.jld2", [:load_shed_timeseries, :solar_generation]; output_dir="figures/")

# Tradeoff curve from multiple solves
results_list = [solve_ots(merge(p, Dict(:tradeoff_weight => w))) for w in 0:0.1:1]
plot_results(results_list, [:tradeoff_curve]; format="pdf", output_dir="figures/")
```

## Examples

### Example 1: Basic DCOTS with Tradeoff Objective

```julia
using GridPlanning

opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "tradeoff",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :tradeoff_weight => 0.7,  # Prioritize wildfire risk reduction
    :time_limit => 300.0
)

results = solve_ots(opt_parameters)

# Access results
println("Optimized in $(results[:solve_time]) seconds")
println("$(results[:risk_reduction_pct])% of wildfire risk removed")
println("$(results[:total_load_shed]) MW of load shed")
```

### Example 2: LACOTS with DCOTS Warm Start

```julia
# Automatically runs DCOTS first, then uses solution to warm-start LACOTS
opt_parameters = Dict(
    :network => "RTS",
    :model => "LACOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :warm_start => "auto"
)

results = solve_ots(opt_parameters)
```

### Example 3: Fast Thresholded Method

```julia
# Remove 50% of wildfire risk using fast heuristic
opt_parameters = Dict(
    :network => "Texas7k",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 11), (2020, 6, 12), (2020, 6, 13)],
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.5,  # De-energize lines to remove 50% of risk
    :time_limit => 300.0
)

results = solve_ots(opt_parameters)

# Compare performance vs optimal method
println("Thresholded solve time: $(results[:solve_time])s")
println("Load shed: $(results[:total_load_shed]) MW")
```

### Example 4: Multi-Period Optimization

```julia
# Optimize for entire month
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "wildfire",
    :times => "June 2020",  # All days in June
    :data_dir => "test_data",
    :T => 24,
    :mip_gap => 0.02
)

results = solve_ots(opt_parameters)

# Analyze daily switching patterns
for (day_idx, lines) in results[:switched_off_lines]
    println("Day $day_idx: $(length(lines)) lines de-energized")
end
```

### Example 5: CATS Network with Custom Risk Metric

```julia
opt_parameters = Dict(
    :network => "CATS",
    :model => "DCOTS",
    :objective => "tradeoff",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :risk_metric => "max_wfpi",  # Use maximum WFPI instead of cumulative
    :tradeoff_weight => 0.6
)

results = solve_ots(opt_parameters)
```

### Example 6: Cost Minimization

```julia
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "cost",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :voll => 10000.0,  # $10,000/MWh value of lost load
    :threshold_pct => 0.3  # Still enforce some risk reduction
)

results = solve_ots(opt_parameters)

println("Total cost: \$$(results[:objective_value])")
```

### Example 7: Save Results to File

```julia
# Save results as JLD2 file
opt_parameters = Dict(
    :network => "Texas2k",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => "June 2020",
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.4,
    :output_format => "jld2",
    :output_path => "results/texas2k_june2020_results.jld2"
)

results = solve_ots(opt_parameters)

# Load results later
using JLD2
loaded_results = load("results/texas2k_june2020_results.jld2")
```

### Example 8: Export Model and Solver Logs

```julia
# Save the optimization model formulation and Gurobi solver log
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "tradeoff",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :tradeoff_weight => 0.5,
    :lp_str => "models/rts_dcots_tradeoff.lp",  # Save model to LP file
    :log_str => "logs/rts_dcots_solve.log"      # Save Gurobi log to file
)

results = solve_ots(opt_parameters)

# The LP file contains the full model formulation:
# - Decision variables, objective function, all constraints
# The log file contains Gurobi's detailed solver output:
# - Presolve reductions, barrier/simplex iterations, MIP progress
# - Useful for debugging, performance analysis, and verification
```

### Example 9: Comparison Study

```julia
# Compare optimal vs thresholded methods
function compare_methods(network, date, threshold_pct)
    # Optimal method
    opt_params_optimal = Dict(
        :network => network,
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [date],
        :data_dir => "test_data",
        :switching_method => "optimal",
        :threshold_pct => threshold_pct
    )
    results_optimal = solve_ots(opt_params_optimal)

    # Thresholded method
    opt_params_threshold = Dict(
        :network => network,
        :model => "DCOTS",
        :objective => "loadshed",
        :times => [date],
        :data_dir => "test_data",
        :switching_method => "thresholded",
        :threshold_pct => threshold_pct
    )
    results_threshold = solve_ots(opt_params_threshold)

    # Compare
    println("\nComparison for $network on $date:")
    println("Optimal    - Time: $(results_optimal[:solve_time])s, Load shed: $(results_optimal[:total_load_shed]) MW")
    println("Thresholded - Time: $(results_threshold[:solve_time])s, Load shed: $(results_threshold[:total_load_shed]) MW")
    println("Speedup: $(results_optimal[:solve_time] / results_threshold[:solve_time])x")
    println("Load shed increase: $(results_threshold[:total_load_shed] - results_optimal[:total_load_shed]) MW")
end

compare_methods("RTS", (2020, 6, 15), 0.5)
```

### Example 10: Line Hardening with Loadshed Objective

```julia
# Optimize line hardening to reduce wildfire risk while minimizing load shedding
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :hardening_enabled => true,
    :infrastructure_budget => 50e6,  # $50M shared budget
    :hardening_cost_per_mile => 7e6,  # $7M per mile
    :hardening_effectiveness => 1.0,  # 100% risk mitigation
    :hardening_enforce_energization => true
)

results = solve_ots(opt_parameters)

# Analyze hardening results
println("Lines hardened: $(length(results[:hardened_lines]))")
println("Hardening cost: \$$(results[:hardening_cost]/1e6)M")
println("Risk mitigated by hardening: $(results[:mitigated_risk])")
println("Remaining active risk: $(results[:active_risk])")
println("Total risk reduction: $(results[:risk_reduction_pct])%")

# View which lines were hardened
for line_id in results[:hardened_lines]
    println("  Line $line_id: hardened (y=$( results[:y][line_id]))")
end
```

### Example 11: Cost Minimization with Hardening

```julia
# Optimize hardening and operations together to minimize total cost
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "cost",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :voll => 10000.0,
    :hardening_enabled => true,
    :hardening_cost_per_mile => 7e6
    # No budget limit - optimizer decides based on cost-benefit analysis
)

results = solve_ots(opt_parameters)

println("Total cost: \$$(results[:objective_value])")
println("Hardening cost: \$$(results[:hardening_cost]/1e6)M")
println("Generation + load shed cost: \$$(results[:objective_value] - results[:hardening_cost])")
```

### Example 12: Thresholded Switching with Optimal Hardening

```julia
# Switching decisions pre-computed (thresholded), hardening solved optimally (MIP)
# Hardenable lines that were thresholded off can be re-energized by hardening them
opt_parameters = Dict(
    :network => "Texas7k",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 11), (2020, 6, 12)],
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.5,  # Pre-de-energize top-50%-risk lines
    :hardening_enabled => true,
    :infrastructure_budget => 100e6,  # $100M shared budget
    :hardening_effectiveness => 0.9   # 90% risk reduction when hardened
)

results = solve_ots(opt_parameters)

# Compare hardening vs switching for risk mitigation
println("Risk mitigated by hardening: $(results[:mitigated_risk])")
println("Risk removed by switching: $(results[:removed_risk])")
println("Total risk reduction: $(results[:risk_reduction_pct])%")
println("Solve time: $(results[:solve_time])s")
```

### Example 13: Battery Installation on CATS Network

```julia
# Install batteries on the California Test System during a high wildfire risk day
# Verified result: 29 buses, ~1517 MWh installed, $303M cost, 0 MW load shed
opt_parameters = Dict(
    :network => "CATS",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 21)],
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.75,          # De-energize lines to remove 75% of risk
    :battery_enabled => true,
    :battery_cost_per_pu => 2e7,     # $20M per 100 MWh
    :infrastructure_budget => 500e6, # $500M shared budget
    :time_limit => 3600.0
)

results = solve_ots(opt_parameters)

# Confirm batteries were installed
println("Buses with batteries: $(length(results[:batteries_installed]))")
println("Total capacity: $(round(results[:total_battery_capacity]*100, digits=1)) MWh")
println("Battery cost: \$$(round(results[:battery_cost]/1e6, digits=1))M")
println("Load shed: $(results[:total_load_shed]) MW")

# Inspect 24-hour dispatch for a specific bus
bus = results[:batteries_installed][1]
capacity = results[:x][bus]
println("\nDispatch at bus $bus ($(round(capacity*100, digits=1)) MWh):")
println("Hour | Charge (p.u.) | Discharge (p.u.) | SOC (%)")
for t in 1:24
    charge    = results[:p_charge][(1, t, bus)]
    discharge = results[:p_discharge][(1, t, bus)]
    soc_pct   = 100 * results[:soc][(1, t, bus)] / capacity
    println("  $t  |   $(round(charge, digits=4))   |   $(round(discharge, digits=4))   |  $(round(soc_pct, digits=1))%")
end
```

**Notes on this example:**
- CATS is a large network (8,870 buses, 10,823 lines) — expect ~4 minute solve time
- On a single high-risk day, batteries start fully charged and purely discharge to cover load shed from de-energized lines (no charging needed within the day)
- The `time_limit` of 3600s is recommended for CATS; smaller networks solve much faster

### Example 14: Custom Wildfire Risk Data

You can bypass automatic data loading by providing your own wildfire risk data via the `:risk_per_line` parameter. This is useful for custom risk models, sensitivity analysis, or external data sources.

```julia
using GridPlanning

# Define custom risk: Dict{day_index => Dict{line_id => risk_value}}
custom_risk = Dict{Int, Dict{Int, Float64}}(
    1 => Dict(5 => 0.8, 12 => 1.2, 23 => 0.5, 45 => 0.9),  # Day 1
    2 => Dict(5 => 0.9, 12 => 1.1, 23 => 0.4),              # Day 2
    3 => Dict(8 => 0.7, 23 => 0.6, 45 => 1.0)               # Day 3
)

opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "tradeoff",
    :times => [(2020, 6, 15), (2020, 6, 16), (2020, 6, 17)],
    :data_dir => "test_data",
    :risk_per_line => custom_risk,
    :tradeoff_weight => 0.5
)

results = solve_ots(opt_parameters)

# Output includes validation:
# ✓ risk_per_line validation passed:
#   - 3 days of data
#   - 11 total line-day risk entries
#   - Min/Max risky lines per day: 3/4
# ✓ Using user-provided risk_per_line data

println("Active risk: $(results[:active_risk])")
println("Risk reduction: $(results[:risk_reduction_pct])%")
```

**Notes:**
- The outer key is the day index (1 to D), matching the order of `:times`
- The inner dict maps line IDs to risk values — only lines with nonzero risk need entries
- The package validates the structure and reports statistics when custom data is provided

### Example 15: Combined Infrastructure Optimization

Jointly optimize solar PV, battery storage, and line hardening under a shared infrastructure budget.

```julia
using GridPlanning

opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.75,
    # Solar
    :solar_enabled => true,
    :solar_cost_per_pu => 5e7,                                        # $50M per 100 MW
    :solar_data_path => "test_data/solar_data/RTS/solar_data.csv",
    # Battery
    :battery_enabled => true,
    :battery_cost_per_pu => 2e7,     # $20M per 100 MWh
    # Hardening
    :hardening_enabled => true,
    :hardening_cost_per_mile => 7e6,
    # Shared budget for all three
    :infrastructure_budget => 500e6  # $500M
)

results = solve_ots(opt_parameters)

# The optimizer allocates the shared budget across all three investments
println("Solar:     \$$(round(results[:solar_cost]/1e6, digits=1))M — $(length(results[:solar_installed])) buses")
println("Batteries: \$$(round(results[:battery_cost]/1e6, digits=1))M — $(length(results[:batteries_installed])) buses")
println("Hardening: \$$(round(results[:hardening_cost]/1e6, digits=1))M — $(length(results[:hardened_lines])) lines")
total_infra = results[:solar_cost] + results[:battery_cost] + results[:hardening_cost]
println("Total:     \$$(round(total_infra/1e6, digits=1))M / \$500M budget")
println("Load shed: $(results[:total_load_shed]) MW")
```

### Example 16: Auto-Plotting via opt_parameters

Trigger plotting automatically at the end of `solve_ots()` using the `:plots` and `:plot_dir` parameters, without calling `plot_results()` separately.

```julia
using GridPlanning

# "all" generates network_overview + relevant timeseries plots
opt_parameters = Dict(
    :network => "RTS",
    :model => "DCOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :battery_enabled => true,
    :battery_cost_per_pu => 2e7,
    :infrastructure_budget => 500e6,
    :plots => "all",                    # Auto-plot after solve
    :plot_dir => "figures/rts_run1"     # Directory created automatically if needed
)

results = solve_ots(opt_parameters)
# Plots saved to figures/rts_run1/ automatically

# Other :plots options:
#   false or "none"       — no plots (default)
#   "all"                 — network_overview + all applicable timeseries
#   "inv_only"            — network_overview only
#   "timeseries_only"     — timeseries plots only (load_shed, battery_dispatch, etc.)
```

### Example 17: Solar PV Installation with Reactive Power Support

Solar PV installation planning with real solar irradiance data and inverter reactive power capability in the LACOTS model.

```julia
using GridPlanning

# LACOTS solar with reactive power support
opt_parameters = Dict(
    :network => "RTS",
    :model => "LACOTS",
    :objective => "loadshed",
    :times => [(2020, 6, 15)],
    :data_dir => "test_data",
    :switching_method => "thresholded",
    :threshold_pct => 0.75,
    :solar_enabled => true,
    :solar_cost_per_pu => 5e7,                                       # $50M per 100 MW
    :solar_data_path => "test_data/solar_data/RTS/solar_data.csv",   # Hourly capacity factors
    :infrastructure_budget => 500e6,
    :linearized_solar_power => true    # Rectangular inverter capability: |Q| ≤ cf × S
    # Alternative: linearized_solar_power => false  for circular: P² + Q² ≤ S²
)

results = solve_ots(opt_parameters)

println("Solar installed: $(length(results[:solar_installed])) buses")
println("Total capacity: $(round(results[:total_solar_capacity]*100, digits=1)) MW")
println("Total P generation: $(round(results[:total_solar_generation], digits=2)) p.u.·h")
println("Total Q injection: $(round(results[:total_solar_q_injection], digits=2)) p.u.·h")
println("Solar cost: \$$(round(results[:solar_cost]/1e6, digits=1))M")

# Show hourly dispatch for an installed bus
bus = results[:solar_installed][1]
cap = results[:s][bus]
println("\nBus $bus ($(round(cap*100, digits=1)) MW) hourly P/Q:")
for t in 1:24
    p = round(results[:p_solar][(1, t, bus)], digits=4)
    q = round(results[:q_solar][(1, t, bus)], digits=4)
    println("  Hour $t: P=$p, Q=$q")
end
```

**Notes on this example:**
- Solar capacity factors are loaded from CSV with columns `Bus_ID, Hour, AC_Output_pu, DC_Output_pu`
- AC output (post-inverter) is used as the capacity factor — the correct value for grid-side modeling
- `q_solar` is bidirectional: positive = injection (capacitive), negative = absorption (inductive)
- At night (cf=0), `q_solar` is forced to zero (inverter offline)
- The linearized mode bounds Q by `cf × s[n]`, while nonlinear allows Q up to `s[n]` when P is low

## Dependencies

This package requires the following Julia packages:

- **PowerModels.jl** - Power system network parsing and modeling
- **JuMP.jl** - Mathematical optimization modeling
- **Gurobi.jl** - MIP solver (requires commercial or academic license)
- **CSV.jl** - CSV file I/O
- **DataFrames.jl** - Tabular data manipulation
- **JLD2.jl** - Binary data serialization
- **Dates.jl** - Date and time handling
- **Plots.jl** - Plot generation
- **Shapefile.jl** - Shapefile parsing for geographic network plots
- **GeoInterface.jl** - Geographic geometry interface
- **ArgParse.jl** - Command-line argument parsing (CLI)
- **DBFTables.jl** - DBF file reading (shapefile attributes)
- **HTTP.jl** - HTTP requests (solar data fetching)
- **JSON.jl** - JSON parsing
- **Logging.jl** - Logging utilities
- **Printf.jl** - Formatted string output

All dependencies are specified in `Project.toml` and will be installed automatically via `Pkg.instantiate()`.

## Testing

### CI tests (no Gurobi required)

The CI test suite runs automatically on every push and pull request via GitHub Actions.

To run locally:

```julia
julia --project=. test/runtests.jl
```

Or via `Pkg.test()`:

```julia
using Pkg
Pkg.test("GridPlanning")
```

These tests cover package loading, reference data file existence, CSV column structure, and parameter validation. They do not invoke the Gurobi solver.

### Full test suite (requires Gurobi license)

The full test suite exercises all model features using the June 2020 reference data in `test_data/`.

```julia
julia --project=. test/runtests_full.jl
```

This runs 18 test groups covering DCOTS, LACOTS, battery planning, solar planning, line hardening, plotting, and a multi-network smoke test across all 6 supported networks.

## Citation

If you use this package in your research, please cite:

```bibtex
@software{GridPlanning_jl_2025,
  author = {Piansky, Ryan},
  title = {GridPlanning.jl: Wildfire-Informed Transmission Switching Optimization},
  year = {2025},
  url = {https://github.com/rpiansky3/GridPlanning.jl}
}
```

## License

This package is released under the [MIT License](LICENSE).

## Contact

For questions, bug reports, or feature requests, please open an issue on the [GitHub repository](https://github.com/rpiansky3/GridPlanning.jl/issues).

## Acknowledgments

This package builds upon optimal transmission switching formulations for wildfire risk mitigation, incorporating both DC and linearized AC power flow models.
