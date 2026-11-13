# ArchiCrop scenes

`1-code/generate_wheat_maize_scenes.py` is the production generator for all 63 USMs
and both STICS algorithms. It reads the normal STICS forcing CSV, DOE, generated
XML workspace and project `0-data/archi_dict.py` presets.

```sh
python 2-generate_scenes/1-code/generate_wheat_maize_scenes.py --plan
python 2-generate_scenes/1-code/generate_wheat_maize_scenes.py --workers 4 --restart
```

Run with Python containing the installed ArchiCrop checkout. `--plan` only
computes the layouts. `--restart` explicitly replaces recognised generated cases
when inputs/code change. Use `--output PATH --reports PATH` for another output
location. Defaults select the current corrected dataset in `3-3D_light_inter/0-data/`.

One centred OBJ/MTG template per species/day is combined with per-plant positions
and a domain CSV. `index.json`, `scene.json` and `case.json` are operational scene
and growth metadata, not audit prerequisites. Keep them with the geometry.

The smallest common fixed seasonal cell respects a default 3% density tolerance
per species over total cell area. DOE rows, widths, interrow spacing and
orientation are retained. Wheat uses the approved phyllochron range 40–160;
leaf stocks use daily `laimax` and `laisen_n` reconstructions.
