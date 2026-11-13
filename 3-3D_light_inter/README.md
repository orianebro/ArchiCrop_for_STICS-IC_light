# ArchimedLight

Use a Kaimon Julia session activated here, with `mt=true`.

```julia
include("1-code/run_simulations.jl")
index = compact_simulation_index(usms=collect(1:63)) # 126 cases, 37,458 dates; no RT
```

The original runner now defaults to the current corrected scenes and results.
Including it defines functions only. To explicitly run all simulations:

```julia
run_light_batch()  # expensive; replaces current result CSVs
```

To select cases or preserve existing results:

```julia
run_light_batch(usms=[48,52], output_dir="2-results/my_run")
```

`source` can select another compact dataset. `crop_visuals.jl` imports/assembles
scenes and provides figures/videos; `stics_weather.jl` reads shared weather.
The light calculation itself is unchanged. Settings remain 46 sky sectors, 1 cm
pixels, toricity/scattering enabled, 10 min radiation integration, no NIR.

Each case writes ordinary `fapar_usm_N_ALGORITHM.csv` results; the batch also
writes `fapar_per_species.csv`. No audit file is required to run or read them.
Incident PAR is counted once per whole cell/date, not summed over plants.
