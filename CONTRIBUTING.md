# Contributing to GridPlanning.jl

## Reporting bugs

Open an issue and include:
- Julia version (`julia --version`)
- Gurobi version
- Minimal reproducing example
- Full error message / stack trace

## Requesting features

Open an issue describing the use case. See the open roadmap issues for features already planned.

## Submitting a pull request

1. Fork the repo and create a branch from `main`.
2. Make changes. If adding functionality, add a test in `test/runtests.jl`.
3. Verify the test suite passes (Gurobi required for optimization tests):
   ```bash
   julia --project=. test/runtests.jl
   ```
4. Open a pull request against `main` with a description of the change.

## Dev environment

```bash
git clone https://github.com/rpiansky3/GridPlanning.jl.git
cd GridPlanning.jl
julia --project=. -e 'using Pkg; Pkg.instantiate()'
```

The `test/runtests.jl` suite runs without Gurobi (skips solver-dependent tests). The full suite in `test/runtests_full.jl` requires a valid Gurobi license.

## Notes

- Match the style of existing Julia code in `src/`.
- Comments should explain *why*, not *what*.
- `data/` (full dataset) is not tracked. Tests use `test_data/` (June reference subset, tracked).
