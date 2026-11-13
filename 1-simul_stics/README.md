# STICS simulations

1. `1-code/1-design_of_experiment.R` defines the DOE.
2. `1-code/2-create_stics_simulations.R` creates the XML inputs.
3. `1-code/3.1-stics_simulations_monocrops.R` handles sole-crop simulations.
4. `1-code/3.2-stics_simulations_intercrops.R` runs Beer and 2.5D and exports
   `2-outputs/simulations_stics_intercrops.csv`, the current forcing for ArchiCrop.

From the project root:

```sh
Rscript 1-simul_stics/1-code/3.2-stics_simulations_intercrops.R
```

Use `--run-root PATH` for a new native-output directory if today's folder
already exists. Each algorithm has separate native outputs. `intercrop_native_export.R`
reads native values and backfills observed phenology only within each species;
zero means the event was not observed. Export retains `laimax`, `laisen_n` and
daily realised `densite`, expressed over the whole field. The source and generated
Pactol plant XML use `code_shape=2`. No historical-output comparison is performed.
