# Results and analysis

```sh
python 4-analyses/1-code/plot_light_comparisons.py
```

This reads the current STICS CSV and per-plant ArchimedLight CSVs directly,
joins by USM/algorithm/species/date, and writes current figures and tables to
`../results/`. `--results`, `--stics`, `--scenes` and `--output` override the defaults.
No manifest or old dataset is required. Ordinary missing-data, calendar and
numeric checks remain part of reading results.

`analyses_light_IC_Archimed.ipynb` is the general comparison notebook.
Oriane's scientific analyses are retained as directly runnable notebooks:

- `analyses_oriane_original_095.ipynb`: original statistical formulas/normalisation;
- `analyses_oriane_physical_100.ipynb`: incident-PAR normalisation;
- `analyses_oriane_relay_extension_original_095.ipynb` and
  `analyses_oriane_relay_extension_physical_100.ipynb`: relay-crop extensions.

All use the corrected current data, through `oriane_input_adapter.py` and
`oriane_analysis_metrics.py`. Open/run all cells with the analysis Python
environment (the existing `.venv` in `2-outputs/oriane_notebook_rerun_2026-11-10`
contains the required notebook/seaborn/sklearn dependencies). Existing figures,
scientific CSVs, executed notebooks and HTML results are retained there.

STICS native RAINT is interception/depletion; ArchimedLight reports absorption.
Both use total cell area. Zero incoming PAR gives an undefined fraction;
STICS' nonpositive-radiation floor is labelled separately, not silently normalised.
The approved `laimax` convention is retained.
