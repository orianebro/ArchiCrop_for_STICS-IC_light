"""Generate compact ArchiCrop scenes from current STICS outputs.

One centred template per species/day, regular plant placements and fixed
periodic domains respecting the configured whole-field density tolerance.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from concurrent.futures import ProcessPoolExecutor, as_completed
import contextlib
import copy
import csv
from dataclasses import asdict, is_dataclass
from datetime import datetime, timezone
from fractions import Fraction
import gc
import gzip
import hashlib
import importlib.util
import importlib
import io
import json
import math
import multiprocessing
import os
from pathlib import Path
import random
import shutil
import sys
import time
from types import SimpleNamespace


REPO = Path(__file__).resolve().parents[2]
LIGHT = REPO / "3-3D_light_inter"
RAW = REPO / "1-simul_stics/2-outputs/simulations_stics_intercrops.csv"
DOE = REPO / "1-simul_stics/2-outputs/doe.csv"
WORKSPACE = REPO / "1-simul_stics/0-data/workspace_v11_gen"
DOMAIN_REFERENCE = REPO / "3-3D_light_inter/0-data/full_archicrop_code_shape2_2026-11-10/domains.csv"
ARCHITECTURE = REPO / "2-generate_scenes" / "0-data" / "archi_dict.py"
ARCHICROP = Path("/Users/rvezy/Documents/dev/ArchiCrop")
SPECIES = ("wheat", "maize", "sorghum")
REPORTS = LIGHT / "2-results" / "scene_generation"
OUTPUT = REPO / "3-3D_light_inter/0-data/full_archicrop_code_shape2_2026-11-10"
LEAF_AREA_CONTRACT = "STICS.laimax reference area, with prescribed senescent stock; explicitly retained by user"


def json_default(value):
    if isinstance(value, Path):
        return str(value)
    if isinstance(value, Fraction):
        return str(value)
    if hasattr(value, "item"):
        return value.item()
    raise TypeError(type(value).__name__)


def json_bytes(value):
    return (json.dumps(value, indent=2, default=json_default, allow_nan=False) + "\n").encode()


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".partial")
    temporary.write_bytes(json_bytes(value))
    temporary.replace(path)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def file_record(path):
    path = Path(path).resolve()
    hasher = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024*1024), b""):
            hasher.update(block)
    return {"path": str(path), "sha256": hasher.hexdigest(), "bytes": path.stat().st_size}


def load_file(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def write_csv(path, columns, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=columns, lineterminator="\n")
        writer.writeheader()
        writer.writerows(rows)


def source_rows(usms, algorithms, source_csv=RAW):
    records = defaultdict(dict)
    with source_csv.open(newline="") as stream:
        for row in csv.DictReader(stream):
            if not row["situation"].startswith("usm_"):
                continue
            usm = int(row["situation"].split("_")[-1])
            if usm not in usms or row["algorithm"] not in algorithms or row["Plant"] not in SPECIES:
                continue
            key = (usm, row["algorithm"], row["Plant"])
            if row["Date"] in records[key]:
                raise ValueError(f"Duplicate full calendar date {key}/{row['Date']}")
            records[key][row["Date"]] = row
    return records


def design_for(usm, doe=DOE):
    with doe.open(newline="") as stream:
        rows = list(csv.DictReader(stream))
    row = rows[usm-1]
    source_species = (row["species_principal"], row["species_secondary"])
    names = {"wheat": "wheat", "maize_temp": "maize", "maize_trop": "maize", "sorghum": "sorghum"}
    species = tuple(names[s] for s in source_species)
    counts = {"wheat": {"high": 14, "middle": 10, "low": 6, "one": 1},
              "maize": {"high": 6, "middle": 4, "low": 2, "one": 1},
              "sorghum": {"high": 6, "middle": 4, "low": 2, "one": 1}}
    distances = {"wheat": {"middle": "0.125"}, "maize_temp": {"middle": "0.75"},
                 "maize_trop": {"high": "0.8", "middle": "0.4", "low": "0.2"},
                 "sorghum": {"high": "0.8", "middle": "0.4", "low": "0.2"}}
    result = {"rows": (counts[species[0]][row["n_rows_principal"]], counts[species[1]][row["n_rows_secondary"]]),
            "interrow": (distances[source_species[0]][row["interrow_distance_principal"]],
                         distances[source_species[1]][row["interrow_distance_secondary"]]),
            "species": species, "source_species": source_species,
            "orientation": row["row_orientation"], "raw": row}
    if row["design"] == "intercrop mixed":
        if result["interrow"][0] != result["interrow"][1]:
            raise ValueError("Mixed-row treatments require the same sowing inter-row distance")
        result["rows"] = (2, 2)
        result["shared_width"] = str(2*Fraction(result["interrow"][0]))
    return result


def crop_is_active(row):
    return float(row["hauteur"]) > 0 and float(row["laisen_n"]) < float(row["laimax"])


def calendar_dates(raw, usm, algorithm, species_names):
    return sorted(set().union(*(set(raw.get((usm, algorithm, s), {})) for s in species_names)))


def daily_density(raw, usm, algorithm, species, date):
    row = raw.get((usm, algorithm, species), {}).get(date)
    return row["densite"] if row is not None else "0"


def mixed_series_geometry(period, design):
    """Two shared rows with alternating species phases, preserving mixed design."""
    spacing = Fraction(design["interrow"][0])
    frames = {}
    for key, source in period.frames.items():
        counts = source.plants_per_row
        phases = []
        for row in range(2):
            first = Fraction(1 if row == 0 else 3, 4)
            second = Fraction(3 if row == 0 else 1, 4)
            if counts[0] and counts[1]:
                occupied = {(Fraction(i)+first)/counts[0] for i in range(counts[0])}
                increment = Fraction(1, 2*(counts[0]+1)*(counts[1]+1)+1)
                while any((Fraction(i)+second)/counts[1] in occupied for i in range(counts[1])):
                    second = (second+increment) % 1
            phases.append((first, second))
        positions, indices = [], []
        for species_index, count in enumerate(counts):
            for row in range(2):
                transverse = float((Fraction(row)+Fraction(1, 2))*spacing)
                for plant in range(count):
                    longitudinal = float((Fraction(plant)+phases[row][species_index])/count)*period.length_m
                    x, y = (longitudinal, transverse) if design["orientation"] == "N-S" else (transverse, longitudinal)
                    positions.append((x, y, 0.0)); indices.append(species_index)
        if len(set(positions)) != len(positions):
            raise AssertionError("Mixed geometry has coincident roots")
        bounds = ((0.0, 0.0), (period.length_m, period.width_m) if design["orientation"] == "N-S" else (period.width_m, period.length_m))
        metadata = asdict(source) if is_dataclass(source) else vars(source).copy()
        metadata.update(positions_m=tuple(positions), species_indices=tuple(indices),
                        rows=(2, 2), interrow_m=tuple(map(float, design["interrow"])),
                        intrarow_m=tuple(period.length_m/k if k else None for k in counts),
                        width_m=period.width_m, length_m=period.length_m, area_m2=period.area_m2,
                        bounds_m=bounds, orientation=design["orientation"], design_geometry="mixed_shared_rows",
                        mixed_row_phases=tuple(tuple(map(float, values)) for values in phases))
        frames[key] = SimpleNamespace(**metadata)
    evidence = {name: getattr(period, name) for name in ("minimal_length_rational", "length_rational", "feasible_interval_rational", "search_iterations", "unique_constraints")}
    return SimpleNamespace(width_m=period.width_m, length_m=period.length_m, area_m2=period.area_m2,
                           bounds_m=next(iter(frames.values())).bounds_m, frames=frames,
                           design_geometry="mixed_shared_rows", **evidence)


def build_seasonal_layouts(args, raw, planner_module):
    """Use all calendar dates and both algorithms to choose one fixed domain."""
    series = {}
    for usm in args.usms:
        design = design_for(usm, args.doe)
        targets = {}
        for algorithm in sorted(set(args.algorithms) | {"2.5D", "Beer"}):
            for date in calendar_dates(raw, usm, algorithm, design["species"]):
                targets[(algorithm, date)] = tuple(daily_density(raw, usm, algorithm, s, date) for s in design["species"])
        if design["raw"]["design"] == "intercrop mixed":
            period = planner_module.periodic_density_series_period(design["shared_width"], design["rows"], targets,
                        relative_density_tolerance=args.relative_density_tolerance,
                        maximum_length=args.maximum_cell_length, max_total_plants=args.max_total_plants)
            if period.no_active_cell:
                raise ValueError(f"USM {usm}: all source densities are zero; there is no uniquely smallest positive periodic domain")
            series[usm] = mixed_series_geometry(period, design)
        else:
            series[usm] = planner_module.periodic_strip_series_layout(*design["interrow"], targets, *design["rows"],
                                  orientation=design["orientation"],
                                  relative_density_tolerance=args.relative_density_tolerance,
                                  maximum_length=args.maximum_cell_length, max_total_plants=args.max_total_plants)
            if series[usm].no_active_cell:
                raise ValueError(f"USM {usm}: all source densities are zero; there is no uniquely smallest positive periodic domain")
    return series


def layout_metadata(layout):
    result = asdict(layout) if is_dataclass(layout) else vars(layout).copy()
    result.pop("positions_m")
    result.pop("species_indices")
    result["domain_m"] = [*layout.bounds_m[0], *layout.bounds_m[1]]
    if result.get("design_geometry") == "mixed_shared_rows":
        result["shared_row_centres_m"] = [(row+0.5)*layout.interrow_m[0] for row in range(2)]
    else:
        result["strip_interfaces_m"] = [sum(layout.interrow_m)/2]*2
    result["period_contract"] = "Smallest fixed seasonal period valid for all raw daily STICS densities and both algorithms within the approved per-species relative density threshold"
    return result


def seasonal_search_metadata(args, series):
    evidence = {name: getattr(series, name, None) for name in ("minimal_length_rational", "length_rational", "feasible_interval_rational", "search_iterations", "unique_constraints")}
    return {"policy": "Smallest fixed seasonal longitudinal period at bounded per-species relative density error",
            "constraint_source": "Every raw daily STICS density across both selected algorithms; zero only for source zero or missing species record",
            "minimum_cell_length_m": 0.0, "maximum_cell_length_m": args.maximum_cell_length,
            "relative_density_tolerance": args.relative_density_tolerance,
            "max_total_plants": args.max_total_plants, "constraint_frames": len(series.frames),
            "selected_length_m": series.length_m, "width_m": series.width_m,
            "fixed_domain_m": [*series.bounds_m[0], *series.bounds_m[1]],
            "solver": "ArchiCrop periodic_density_series_period exact rational allowed-length interval intersection", **evidence}


def plan_cases(args, raw, series):
    cases = []
    for usm in args.usms:
        design = design_for(usm, args.doe)
        for algorithm in args.algorithms:
            species_names = design["species"]
            dates = calendar_dates(raw, usm, algorithm, species_names)
            phases = {}
            species_info = {}
            for species in species_names:
                values = raw.get((usm, algorithm, species), {})
                active = [r for _, r in sorted(values.items()) if crop_is_active(r)]
                species_info[species] = {"raw_dates": len(values), "active_dates": len(active),
                                         "first_active": active[0]["Date"] if active else None,
                                         "last_active": active[-1]["Date"] if active else None,
                                         "density_phases": dict(Counter(r["densite"] for r in values.values()))}
            for date in dates:
                densities = tuple(daily_density(raw, usm, algorithm, s, date) for s in species_names)
                layout = series[usm].frames[(algorithm, date)]
                phase_key = (densities, tuple(layout.plants_per_row))
                if phase_key not in phases:
                    phases[phase_key] = layout_metadata(layout) | {"source_density_strings": densities, "dates": []}
                phases[phase_key]["dates"].append(date)
            cases.append({"usm": usm, "algorithm": algorithm, "calendar_dates": len(dates),
                          "first_date": dates[0], "last_date": dates[-1], "species": species_info,
                          "layout_phases": list(phases.values()),
                          "fixed_seasonal_domain_m": [*series[usm].bounds_m[0], *series[usm].bounds_m[1]],
                          "fixed_seasonal_length_m": series[usm].length_m,
                          "seasonal_search": seasonal_search_metadata(args, series[usm])})
    return {"schema": "archicrop.fresh_growth_plan", "cases": cases,
            "relative_density_tolerance": args.relative_density_tolerance,
            "maximum_cell_length_m": args.maximum_cell_length, "max_total_plants": args.max_total_plants,
            "free_disk_bytes": shutil.disk_usage(REPO).free,
            "source_csv": file_record(args.source_csv), "architecture": file_record(args.architecture),
            "historical_geometry_read": False,
            "notes": ["Actual growth covers the complete chronological dynamics returned by the corrected IC reader.",
                      "Every raw STICS calendar date receives an explicit scene manifest, including empty canopy dates.",
                      "Each USM has one smallest fixed domain valid across all selected dates and both algorithms at the approved per-species relative tolerance.",
                      "All raw STICS density targets are retained irrespective of canopy visibility; geometry_present distinguishes absent aerial geometry from logical planting roots.",
                      "Full OBJ.gz mode stores baked vertex coordinates. Templates mode retains every new geometry and placement for materialization."]}


def parse_obj(path):
    vertices, texture, normals, body = [], [], [], []
    material_files = []
    face_count = 0
    for line in Path(path).read_text().splitlines():
        parts = line.split()
        if not parts or parts[0].startswith("#"):
            continue
        command = parts[0]
        if command == "v":
            vertices.append(tuple(map(float, parts[1:4])))
        elif command == "vt":
            texture.append(line)
        elif command == "vn":
            normals.append(line)
        elif command == "mtllib":
            material_files.extend(parts[1:])
        else:
            if command == "f":
                face_count += len(parts)-3
            body.append(parts)
    return {"vertices": vertices, "texture": texture, "normals": normals,
            "body": body, "materials": material_files, "triangles": face_count}


def positive_index(token, size):
    value = int(token)
    return value if value > 0 else size+1+value


def translated_obj_lines(template, plant_id, species, position_m, offsets):
    """Stream a single freshly exported template at an absolute root location."""
    translation = [float(v)*100 for v in position_m]
    for point in template["vertices"]:
        yield "v " + " ".join(format(value+delta, ".9f") for value, delta in zip(point, translation)) + "\n"
    for line in template["texture"] + template["normals"]:
        yield line + "\n"
    sizes = (len(template["vertices"]), len(template["texture"]), len(template["normals"]))
    for parts in template["body"]:
        command = parts[0]
        if command == "o":
            yield f"o plant_{plant_id}_{species}_{parts[1]}\n"
        elif command == "usemtl":
            yield f"usemtl {species}_{parts[1]}\n"
        elif command == "f":
            tokens = []
            for raw_index in parts[1:]:
                values = raw_index.split("/")
                tokens.append("/".join(str(positive_index(v, sizes[k])+offsets[k]) if v else ""
                                       for k, v in enumerate(values)))
            yield "f " + " ".join(tokens) + "\n"
        elif command in ("g", "s"):
            yield " ".join(parts) + "\n"


def prepare_template_writer(template, species):
    """Cache constant topology using standard per-plant negative OBJ indices."""
    marker = "__ARCHICROP_PLANT_ID__"
    body = []
    sizes = (len(template["vertices"]), len(template["texture"]), len(template["normals"]))
    for parts in template["body"]:
        command = parts[0]
        if command == "o":
            body.append(f"o plant_{marker}_{species}_{parts[1]}\n")
        elif command == "usemtl":
            body.append(f"usemtl {species}_{parts[1]}\n")
        elif command == "f":
            tokens = []
            for raw_index in parts[1:]:
                values = raw_index.split("/")
                tokens.append("/".join(str(positive_index(v, sizes[k])-sizes[k]-1) if v else ""
                                       for k, v in enumerate(values)))
            body.append("f " + " ".join(tokens) + "\n")
        elif command in ("g", "s"):
            body.append(" ".join(parts) + "\n")
    return {"marker": marker,
            "body": "".join(line+"\n" for line in template["texture"]+template["normals"]) + "".join(body),
            "coordinates": tuple(tuple(p[axis] for p in template["vertices"]) for axis in range(3)),
            "coordinate_cache": ({}, {}, {})}


def translated_obj_chunk(prepared, plant_id, position_m):
    columns = []
    for axis, position in enumerate(position_m):
        translation = float(position)*100
        cache = prepared["coordinate_cache"][axis]
        if translation not in cache:
            cache[translation] = tuple(format(value+translation, ".9f") for value in prepared["coordinates"][axis])
        columns.append(cache[translation])
    vertices = "".join("v " + x + " " + y + " " + z + "\n" for x, y, z in zip(*columns))
    return vertices + prepared["body"].replace(prepared["marker"], str(plant_id))


def organ_templates(template):
    """Reindex each organ locally, preserving triangle coordinates and materials."""
    if template["texture"] or template["normals"]:
        raise ValueError("Organ-major writer requires the normalless/UV-free PlantGL export; use --obj-order plant-major for other OBJ assets")
    organs, current, material = [], None, None
    for parts in template["body"]:
        if parts[0] == "usemtl":
            material = parts
            if current is not None:
                current.append(parts)
        elif parts[0] == "o":
            if current is not None:
                organs.append(current)
            current = ([material] if material else []) + [parts]
        elif current is not None:
            current.append(parts)
    if current is not None:
        organs.append(current)
    output = []
    for body in organs:
        indices = sorted({positive_index(value.split("/")[0], len(template["vertices"]))
                          for parts in body if parts[0] == "f" for value in parts[1:]})
        mapping = {value: i+1 for i, value in enumerate(indices)}
        rebuilt = []
        triangles = 0
        for parts in body:
            if parts[0] == "f":
                rebuilt.append(["f"] + [str(mapping[positive_index(value, len(template["vertices"]))]) for value in parts[1:]])
                triangles += len(parts)-3
            else:
                rebuilt.append(parts)
        output.append({"vertices": [template["vertices"][i-1] for i in indices],
                       "texture": [], "normals": [], "body": rebuilt, "triangles": triangles})
    return output


def merged_materials(template_paths):
    output = []
    for species, obj_path in template_paths.items():
        template = parse_obj(obj_path)
        for name in template["materials"]:
            for line in (Path(obj_path).parent / name).read_text().splitlines():
                parts = line.split()
                if parts and parts[0] == "newmtl":
                    output.append(f"newmtl {species}_{parts[1]}\n")
                else:
                    output.append(line + "\n")
    return "".join(output)


class HashingWriter:
    def __init__(self, file):
        self.file, self.hasher = file, hashlib.sha256()
    def write(self, data):
        self.hasher.update(data)
        return self.file.write(data)
    def flush(self):
        return self.file.flush()


def require_disk_space(path, minimum_free_gib):
    available = shutil.disk_usage(path).free
    if available < minimum_free_gib*2**30:
        raise OSError(f"Free disk {available/2**30:.2f} GiB is below the explicit {minimum_free_gib:g} GiB reserve; resume after freeing space")


def bake_scene_obj(output, template_paths, placements, compresslevel=1, minimum_free_gib=20,
                   order="organ-major"):
    """Write one complete baked scene without holding the whole stand in RAM."""
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    require_disk_space(output.parent, minimum_free_gib)
    mtl = output.with_suffix("").with_suffix(".mtl")
    mtl.write_text(merged_materials(template_paths))
    templates = {s: parse_obj(path) for s, path in template_paths.items()}
    by_species = defaultdict(list)
    for row in placements:
        by_species[row["species"]].append(row)
    batches = []
    for species, template in templates.items():
        pieces = organ_templates(template) if order == "organ-major" else [template]
        for piece in pieces:
            batches.append((species, piece))
    offsets, counts, nplants = [0, 0, 0], Counter(), 0
    temporary = output.with_name(output.name + ".partial")
    started = time.monotonic()
    with temporary.open("wb") as raw:
        writer = HashingWriter(raw)
        with gzip.GzipFile(fileobj=writer, filename="", mode="wb", compresslevel=compresslevel, mtime=0) as compressed:
            with io.TextIOWrapper(compressed, encoding="utf8", newline="\n") as stream:
                stream.write("# Fresh ArchiCrop growth; root placements baked in cm\n")
                stream.write(f"mtllib {mtl.name}\n")
                for species, piece in batches:
                    prepared = prepare_template_writer(piece, species)
                    for row in by_species[species]:
                        position = tuple(float(row[k]) for k in ("x_m", "y_m", "z_m"))
                        stream.write(translated_obj_chunk(prepared, row["plant_id"], position))
                        offsets = [offsets[0]+len(piece["vertices"]), offsets[1]+len(piece["texture"]), offsets[2]+len(piece["normals"])]
                    counts["triangles"] += piece["triangles"]*len(by_species[species])
        compressed_hash = writer.hasher.hexdigest()
    temporary.replace(output)
    counts.update({species: len(rows) for species, rows in by_species.items()})
    nplants = sum(len(rows) for rows in by_species.values())
    return {"obj_gz": output.name, "obj_gz_sha256": compressed_hash, "compressed_bytes": output.stat().st_size,
            "mtl": file_record(mtl), "seconds": time.monotonic()-started,
            "vertices": offsets[0], "plants": nplants, "counts": dict(counts),
            "coordinate_units": "cm", "root_translations_baked": True,
            "face_index_contract": "Standard negative OBJ indices, relative to vertices/UVs/normals already written when each face is read",
            "object_order": order,
            "object_name_contract": "plant_<plant_id>_<species>_<original organ name>"}


def export_plant(graph, destination, build_scene, save_mtg, *, senescence=True):
    destination.parent.mkdir(parents=True, exist_ok=True)
    scene, _ = build_scene(graph, position=(0, 0, 0), senescence=senescence)
    with contextlib.redirect_stdout(io.StringIO()):
        save_mtg(graph, scene, destination.with_suffix(".mtg"), destination.with_suffix(".obj"))
    files = {ext: file_record(destination.with_suffix("."+ext)) for ext in ("obj", "mtg")}
    for material in parse_obj(destination.with_suffix(".obj"))["materials"]:
        files.setdefault("materials", []).append(file_record(destination.parent/material))
    files["vertices"] = len(parse_obj(destination.with_suffix(".obj"))["vertices"])
    return files


def link_or_copy(source, destination):
    if destination.exists():
        destination.unlink()
    try:
        os.link(source, destination)
    except OSError:
        shutil.copyfile(source, destination)


def write_layout(folder, layout, available, species_names):
    metadata = layout_metadata(layout)
    folder.mkdir(parents=True, exist_ok=True)
    bounds = metadata["domain_m"]
    write_csv(folder/"domain.csv", ["xmin", "ymin", "xmax", "ymax", "orientation"],
              [dict(zip(("xmin", "ymin", "xmax", "ymax"), bounds)) | {"orientation": layout.orientation}])
    rows, cursor = [], Counter()
    for plant_id, (point, species_index) in enumerate(zip(layout.positions_m, layout.species_indices), 1):
        species = species_names[species_index]
        ordinal = cursor[species]
        cursor[species] += 1
        rows.append({"plant_id": plant_id, "species": species, "template_id": species,
                     "row": ordinal//layout.plants_per_row[species_index]+1,
                     "along_index": ordinal%layout.plants_per_row[species_index]+1,
                     "x_m": point[0], "y_m": point[1], "z_m": point[2],
                     "geometry_present": species in available})
    write_csv(folder/"placements.csv", ["plant_id", "species", "template_id", "row", "along_index", "x_m", "y_m", "z_m", "geometry_present"], rows)
    metadata["available_geometry_species"] = list(available)
    metadata["logical_plant_counts"] = {s: sum(row["species"] == s for row in rows) for s in species_names}
    metadata["aboveground_plant_counts"] = {s: sum(row["species"] == s and row["geometry_present"] for row in rows) for s in species_names}
    atomic_json(folder/"layout.json", metadata)
    return metadata


def source_provenance(args, usm):
    design = design_for(usm, args.doe)
    files = [Path(__file__), args.source_csv, args.doe, args.architecture, args.domains_reference]
    for species in design["source_species"]:
        files.extend([args.workspace/f"{species}_{usm}_tec.xml", plant_xml(species, args.workspace)])
    files += sorted((args.archicrop/"src"/"openalea"/"archicrop").glob("*.py"))
    return {str(path): file_record(path) for path in files}


def plant_xml(source_species, workspace=WORKSPACE):
    name = {"wheat": "wheat_relay_plt.xml", "maize_temp": "maize_relay_plt.xml",
            "sorghum": "sorgho_trop_plt.xml", "maize_trop": "corn_LI_step2_BEOU_plt.xml"}[source_species]
    return workspace/"plant"/name


def run_case(args, usm, algorithm, raw, dynamics, series):
    from openalea.archicrop.simulation import define_archicrop_parameters_IC, compute_pot_growth, simulate_plant_growth_IC
    from openalea.archicrop.growth import ForcingCapacityError
    from openalea.archicrop.display import build_scene
    from openalea.archicrop.export_mtg import save_mtg
    import numpy as np
    design = design_for(usm, args.doe)
    species_names = design["species"]
    architecture = load_file(args.architecture, f"article_architecture_{usm}_{algorithm.replace('.', '_')}")
    preset_names = {"wheat": args.wheat_preset, "maize": args.maize_preset, "sorghum": args.sorghum_preset}
    presets = {s: copy.deepcopy(getattr(architecture, preset_names[s])) for s in species_names}
    if "wheat" in presets and args.wheat_phyllochron_range is not None:
        presets["wheat"]["phyllochron"] = list(args.wheat_phyllochron_range)
    for species, preset in presets.items():
        if not dynamics.get(f"usm_{usm}", {}).get(algorithm, {}).get(species):
            continue
        for name in ("phyllochron", "rmax", "skew"):
            if not isinstance(preset[name], (tuple, list)):
                raise ValueError(f"{species} preset {name}={preset[name]!r} is scalar; the current viability selector requires an explicit bounded range. Supply an approved architecture preset/range; it is not inferred.")
    provenance = source_provenance(args, usm)
    fingerprint = digest(json_bytes({"files": provenance, "presets": presets,
                                     "seed": args.seed, "factors": [args.pot_factor_lai, args.pot_factor_height],
                                     "relative_density_tolerance": args.relative_density_tolerance,
                                     "maximum_cell_length_m": args.maximum_cell_length, "max_total_plants": args.max_total_plants,
                                     "fixed_domain_m": [*series.bounds_m[0], *series.bounds_m[1]],
                                     "layout_design": design["raw"]["design"],
                                     "leaf_area_contract": LEAF_AREA_CONTRACT}))
    folder = args.output/f"usm_{usm}_{algorithm}"
    state_file = folder/"case.json"
    if folder.exists() and not state_file.exists() and any(folder.iterdir()):
        raise ValueError(f"Refusing to overwrite an unrecognized existing case folder {folder}")
    if state_file.exists():
        previous = json.loads(state_file.read_text())
        if previous.get("fingerprint") != fingerprint:
            if not args.restart:
                raise ValueError(f"Inputs or code changed for {folder}; --restart explicitly regenerates this recognized case")
            if previous.get("schema") != "archicrop.fresh_growth_case":
                raise ValueError("Refusing to replace an unrecognized output")
            shutil.rmtree(folder)
        elif previous.get("growth_complete"):
            print(f"RESUME fresh growth already complete: USM {usm} {algorithm}", flush=True)
            materialize_case(args, folder)
            return json.loads(state_file.read_text())
    folder.mkdir(parents=True, exist_ok=True)
    require_disk_space(folder, args.min_free_gib)
    state = {"schema": "archicrop.fresh_growth_case", "schema_version": 1,
             "usm": usm, "algorithm": algorithm, "fingerprint": fingerprint,
             "provenance": provenance, "architecture_presets": presets,
             "seasonal_search": seasonal_search_metadata(args, series),
             "python": sys.version, "executable": sys.executable, "historical_geometry_read": False,
             "leaf_area_contract": LEAF_AREA_CONTRACT,
             "growth_column_definitions": {
                 "potential_height_cm": "Legacy alias of potential_summed_stem_length_cm; includes secondary axes, not the main-axis height",
                 "realized_summed_stem_length_cm": "Sum over main axis and tillers; not a height",
                 "realized_main_axis_height_cm": "Main-axis stem length, compared with STICS hauteur * 100"},
             "growth_complete": False, "all_scene_obj_complete": False,
             "started_utc": datetime.now(timezone.utc).isoformat()}
    atomic_json(state_file, state)
    graph_date_counts, export_records, growth_rows = {}, {}, []
    for species_index, species in enumerate(species_names):
        seed = args.seed+usm*10+species_index
        random.seed(seed); np.random.seed(seed)
        daily = dynamics.get(f"usm_{usm}", {}).get(algorithm, {}).get(species, {})
        if not daily:
            graph_date_counts[species] = 0
            export_records[species] = {}
            atomic_json(folder/f"dynamics_{species}.json", {})
            atomic_json(folder/f"exports_{species}.json", {})
            atomic_json(folder/f"parameters_{species}.json", {"status": "no active crop trajectory in source dynamics", "growth_executed": False})
            continue
        dates = [v["Date"] for v in daily.values()]
        daily_by_date = {value["Date"]: value for value in daily.values()}
        if dates != sorted(dates) or len(set(dates)) != len(dates) or list(daily) != list(range(1, len(daily)+1)):
            raise ValueError("IC reader must return unique chronological dates and contiguous step keys")
        atomic_json(folder/f"dynamics_{species}.json", daily)
        print(f"FIT USM {usm} {algorithm} {species}: {len(daily)} chronological steps", flush=True)
        fitting_diagnostics = {}
        parameters, _ = define_archicrop_parameters_IC(
            archi_params=copy.deepcopy(presets[species]),
            tec_file=str(args.workspace/f"{design['source_species'][species_index]}_{usm}_tec.xml"),
            plant_file=str(plant_xml(design["source_species"][species_index], args.workspace)),
            d_outputs=daily, pot_factor_lai=args.pot_factor_lai, pot_factor_height=args.pot_factor_height,
            fitting_diagnostics=fitting_diagnostics, all_viable_shapes=True)
        fit_record = {"all_viable_parameters": parameters, "fitting_constraints": fitting_diagnostics,
                      "random_seed": seed, "status": "fit_completed_trajectory_not_yet_qualified"}
        atomic_json(folder/f"parameters_{species}.json", fit_record)
        if not parameters:
            raise ValueError(f"No viable parameters for USM {usm} {algorithm} {species}; no unapproved fallback is used")
        rejected_candidates = []
        for selected in sorted(parameters):
            chosen = {selected: parameters[selected]}
            random.seed(seed); np.random.seed(seed)
            potential_la, potential_h, potential_graph = compute_pot_growth(chosen, daily)
            random.seed(seed); np.random.seed(seed)
            try:
                realized_la, realized_h, graphs = simulate_plant_growth_IC(chosen, daily)
            except ForcingCapacityError as error:
                rejected_candidates.append({"id": selected, "reason": str(error)})
                print(f"REJECT FIT USM {usm} {algorithm} {species} candidate {selected}: {error}", flush=True)
                del potential_graph
                gc.collect()
            else:
                break
        else:
            atomic_json(folder/f"parameters_{species}.json", fit_record | {
                "status": "trajectory_reconstruction_failed",
                "rejected_capacity_candidates": rejected_candidates})
            raise ValueError(f"None of {len(parameters)} viable bounded fits can reconstruct the full daily trajectory for USM {usm} {algorithm} {species}: {rejected_candidates}")
        atomic_json(folder/f"parameters_{species}.json", fit_record | {
                    "selected_id": selected,
                    "status": "complete_daily_trajectory_qualified",
                    "selection": "First viable fit with sufficient already-born organ capacity for all daily stocks, in deterministic parameter-ID order; only explicit capacity failures may advance to another approved fit",
                    "rejected_capacity_candidates": rejected_candidates,
                    "random_seed": seed})
        export_plant(potential_graph[selected], folder/"potential"/species, build_scene, save_mtg, senescence=False)
        graph_date_counts[species] = len(graphs[selected])
        export_records[species] = {}
        reconciliation_records = {}
        for index, (date, graph) in enumerate(sorted(graphs[selected].items())):
            record = export_plant(graph, folder/"plants"/date/species, build_scene, save_mtg)
            export_records[species][date] = record
            forcing = daily_by_date[date]
            main_axis_height = sum(value for vid, value in graph.property("visible_length").items()
                                   if graph.label(vid).startswith("Stem") and graph.order(vid) == 0)
            total_area = sum(graph.property("visible_leaf_area").values())
            senescent_area = sum(graph.property("senescent_area").values())
            diagnostics = graph.properties().get("forcing_reconciliation", {}).get(graph.root, {})
            normalization = list(graph.properties().get("leaf_width_normalization", {}).values())
            reconciliation_records[date] = {"forcing": diagnostics,
                "leaf_width_normalization_min": min(normalization) if normalization else None,
                "leaf_width_normalization_max": max(normalization) if normalization else None}
            growth_rows.append({"species": species, "date": date,
                                "potential_leaf_area_cm2": potential_la[selected][index],
                                "potential_height_cm": potential_h[selected][index],
                                "potential_summed_stem_length_cm": potential_h[selected][index],
                                "realized_green_leaf_area_cm2": realized_la[selected][date],
                                "realized_summed_stem_length_cm": realized_h[selected][date],
                                "realized_reference_leaf_area_cm2": total_area,
                                "realized_senescent_leaf_area_cm2": senescent_area,
                                "realized_main_axis_height_cm": main_axis_height,
                                "target_reference_leaf_area_cm2": forcing["Plant leaf area"],
                                "target_senescent_leaf_area_cm2": forcing["Plant senescent leaf area"],
                                "target_main_axis_height_cm": forcing["Plant height"],
                                "vertices": record["vertices"]})
            if index % 40 == 0:
                require_disk_space(folder, args.min_free_gib)
                print(f"EXPORT PLANT USM {usm} {algorithm} {species}: {index+1}/{len(graphs[selected])} {date}", flush=True)
        atomic_json(folder/f"exports_{species}.json", export_records[species])
        atomic_json(folder/f"reconciliation_{species}.json", reconciliation_records)
        del potential_graph, graphs
        gc.collect()
    growth_columns = ["species", "date", "potential_leaf_area_cm2", "potential_height_cm", "potential_summed_stem_length_cm",
                      "realized_green_leaf_area_cm2", "realized_summed_stem_length_cm",
                      "realized_reference_leaf_area_cm2", "realized_senescent_leaf_area_cm2",
                      "realized_main_axis_height_cm", "target_reference_leaf_area_cm2",
                      "target_senescent_leaf_area_cm2", "target_main_axis_height_cm", "vertices"]
    write_csv(folder/"growth.csv", growth_columns, growth_rows)
    dates = calendar_dates(raw, usm, algorithm, species_names)
    layouts, index_rows = {}, []
    for date in dates:
        densities = tuple(daily_density(raw, usm, algorithm, s, date) for s in species_names)
        available = tuple(s for s in species_names if export_records[s].get(date, {}).get("vertices", 0) > 0)
        layout = series.frames[(algorithm, date)]
        key = digest(json_bytes([densities, available, layout.plants_per_row]))[:20]
        layout_folder = folder/"layouts"/key
        if key not in layouts:
            layouts[key] = write_layout(layout_folder, layout, available, species_names)
        scene_folder = folder/"scenes"/date
        scene_folder.mkdir(parents=True, exist_ok=True)
        for name in ("placements.csv", "domain.csv"):
            link_or_copy(layout_folder/name, scene_folder/name)
        template_rows = [{"template_id": s, "species": s,
                          **{ext: str(Path("../..")/"plants"/date/f"{s}.{ext}") for ext in ("obj", "mtg", "mtl")}}
                         for s in available]
        write_csv(scene_folder/"templates.csv", ["template_id", "species", "obj", "mtg", "mtl"], template_rows)
        manifest = {"schema": "archicrop.fresh_growth_periodic_scene", "schema_version": 1,
                    "usm": usm, "algorithm": algorithm, "date": date,
                    "layout": layouts[key], "domain_m": layouts[key]["domain_m"],
                    "source_density_strings": dict(zip(species_names, densities)),
                    "relative_density_tolerance": args.relative_density_tolerance,
                    "design": design["raw"]["design"],
                    "available_geometry_species": available, "empty_canopy": not available,
                    "geometry_source": "Fresh ArchiCrop potential generation + complete chronological constrained growth + PlantGL export",
                    "geometry_units": "cm", "placement_units": "m", "historical_geometry_read": False,
                    "leaf_area_contract": LEAF_AREA_CONTRACT,
                    "templates": template_rows, "fingerprint": fingerprint}
        atomic_json(scene_folder/"scene.json", manifest)
        index_rows.append({"date": date, "scene": str(scene_folder.relative_to(folder)),
                           "available_geometry_species": available, "empty_canopy": not available,
                           "layout_id": key, "domain_m": manifest["domain_m"]})
    atomic_json(folder/"index.json", {"schema": "archicrop.fresh_growth_series", "scenes": index_rows})
    state.update(growth_complete=True, calendar_dates=len(dates),
                 growth_graph_dates=graph_date_counts,
                 nonempty_scene_dates=sum(not r["empty_canopy"] for r in index_rows),
                 complete_utc=datetime.now(timezone.utc).isoformat())
    atomic_json(state_file, state)
    materialize_case(args, folder)
    return json.loads(state_file.read_text())


def materialize_case(args, folder):
    index = json.loads((folder/"index.json").read_text())["scenes"]
    selected_dates = None if args.output_mode == "full-obj-gz" else set(args.bake_dates)
    if selected_dates is not None and not selected_dates:
        return
    for scene_index, row in enumerate(index):
        if selected_dates is not None and row["date"] not in selected_dates:
            continue
        scene_folder = folder/row["scene"]
        receipt = scene_folder/"full_scene_export.json"
        output = scene_folder/"full_scene.obj.gz"
        if receipt.exists() and output.exists():
            record = json.loads(receipt.read_text())
            if (output.stat().st_size == record["compressed_bytes"] and
                    file_record(output)["sha256"] == record["obj_gz_sha256"]):
                continue
            raise ValueError(f"Incomplete or modified materialized scene {output}")
        with (scene_folder/"templates.csv").open() as stream:
            templates = {r["species"]: scene_folder/r["obj"] for r in csv.DictReader(stream)}
        with (scene_folder/"placements.csv").open() as stream:
            placements = (r for r in csv.DictReader(stream) if r.get("geometry_present", "True").lower() == "true")
            record = bake_scene_obj(output, templates, placements, args.compresslevel, args.min_free_gib, args.obj_order)
        atomic_json(receipt, record)
        print(f"BAKED {folder.name} {row['date']}: {record['plants']} plants, {record['compressed_bytes']/2**20:.2f} MiB, {record['seconds']:.1f}s ({scene_index+1}/{len(index)})", flush=True)
    state_path = folder/"case.json"
    state = json.loads(state_path.read_text())
    if args.output_mode == "full-obj-gz":
        state["all_scene_obj_complete"] = all((folder/r["scene"]/"full_scene_export.json").exists() for r in index)
    state["output_mode"] = args.output_mode
    atomic_json(state_path, state)


def corrected_domains(args, series):
    """Publish domains solely inside this experiment, preserving its reference."""
    live = args.domains_reference
    with live.open(newline="") as stream:
        old_rows = list(csv.DictReader(stream))
    rows = {int(row["usms"].split("_")[-1]): row for row in old_rows}
    for usm, layout in series.items():
        lower, upper = layout.bounds_m
        rows[usm] = dict(zip(("usms", "x_first_corner", "y_first_corner", "x_last_corner", "y_last_corner"),
                            (f"usm_{usm}", *(format(value*100, ".17g") for value in (*lower, *upper)))))
    columns = ["usms", "x_first_corner", "y_first_corner", "x_last_corner", "y_last_corner"]
    output = args.output/"domains.csv"
    write_csv(output, columns, [rows[key] for key in sorted(rows)])



def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--usms", type=int, nargs="+", default=list(range(1, 64)), help="USM numbers; defaults to all 63")
    parser.add_argument("--algorithms", nargs="+", default=["2.5D", "Beer"])
    parser.add_argument("--archicrop", type=Path, default=ARCHICROP)
    parser.add_argument("--architecture", type=Path, default=ARCHITECTURE)
    parser.add_argument("--source-csv", type=Path, default=RAW)
    parser.add_argument("--workspace", type=Path, default=WORKSPACE,
                        help="Immutable XML reference used for STICS input generation")
    parser.add_argument("--doe", type=Path, default=DOE)
    parser.add_argument("--domains-reference", type=Path, default=DOMAIN_REFERENCE)
    parser.add_argument("--wheat-preset", default="archi_wheat")
    parser.add_argument("--maize-preset", default="archi_maize")
    parser.add_argument("--sorghum-preset", default="archi_sorghum")
    parser.add_argument("--wheat-phyllochron-range", type=float, nargs=2, default=[40.0, 160.0])
    parser.add_argument("--pot-factor-lai", type=float, default=5)
    parser.add_argument("--pot-factor-height", type=float, default=10)
    parser.add_argument("--relative-density-tolerance", default="0.03")
    parser.add_argument("--maximum-cell-length", type=float, default=10.0, help="Fail when no seasonal cell fits this length limit in metres")
    parser.add_argument("--max-total-plants", type=int, default=10000)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--reports", type=Path, default=REPORTS)
    parser.add_argument("--plan", action="store_true")
    parser.add_argument("--output-mode", choices=["full-obj-gz", "templates"], default="templates")
    parser.add_argument("--bake-dates", nargs="*", default=[])
    parser.add_argument("--compresslevel", type=int, choices=range(1, 10), default=1)
    parser.add_argument("--min-free-gib", type=float, default=20)
    parser.add_argument("--obj-order", choices=["organ-major", "plant-major"], default="organ-major")
    parser.add_argument("--restart", action="store_true")
    parser.add_argument("--workers", type=int, default=1, help="Independent case processes; 4 is suitable for a full run")
    return parser.parse_args()


def main():
    args = arguments()
    for name in ("source_csv", "workspace", "doe", "domains_reference"):
        setattr(args, name, getattr(args, name).resolve(strict=True))
    sys.path.insert(0, str(args.archicrop/"src"))
    planner = importlib.import_module("openalea.archicrop.periodic_layout")
    raw = source_rows(args.usms, sorted(set(args.algorithms) | {"2.5D", "Beer"}), args.source_csv)
    series = build_seasonal_layouts(args, raw, planner)
    plan = plan_cases(args, raw, series)
    args.reports.mkdir(parents=True, exist_ok=True)
    print(json.dumps({"planned_cases": len(plan["cases"]), "calendar_scenes": sum(c["calendar_dates"] for c in plan["cases"]),
                      "free_disk_GiB": plan["free_disk_bytes"]/2**30}), flush=True)
    if args.plan:
        return
    if not (1 <= args.compresslevel <= 9):
        raise ValueError("Invalid gzip compression level")
    if args.min_free_gib < 0:
        raise ValueError("Disk reserve must be nonnegative")
    if args.workers < 1:
        raise ValueError("Worker count must be positive")
    if args.output.resolve().is_relative_to((LIGHT/"0-data"/"mtg_obj").resolve()):
        raise ValueError("Historical geometry directory cannot be an output")
    from openalea.archicrop.stics_io import read_csv_file_IC
    selected_rows = [row for key in sorted(raw) for _, row in sorted(raw[key].items())]
    selected_csv = args.reports/"selected_stics_rows.csv"
    write_csv(selected_csv, list(selected_rows[0]), selected_rows)
    dynamics = read_csv_file_IC(str(selected_csv))
    jobs = [(usm, algorithm) for usm in args.usms for algorithm in args.algorithms]
    results, failures = [], []
    def job_args(usm, algorithm):
        case_raw = {key: values for key, values in raw.items() if key[0] == usm and key[1] == algorithm}
        case_dynamics = {f"usm_{usm}": {algorithm: dynamics.get(f"usm_{usm}", {}).get(algorithm, {})}}
        return args, usm, algorithm, case_raw, case_dynamics, series[usm]
    if args.workers == 1:
        for usm, algorithm in jobs:
            try:
                results.append(run_case(*job_args(usm, algorithm)))
            except Exception as error:
                failures.append({"usm": usm, "algorithm": algorithm, "error": repr(error)})
                print(f"FAILED USM {usm} {algorithm}: {error}", flush=True)
    else:
        with ProcessPoolExecutor(max_workers=args.workers, mp_context=multiprocessing.get_context("spawn")) as executor:
            pending = {executor.submit(run_case, *job_args(usm, algorithm)): (usm, algorithm) for usm, algorithm in jobs}
            for future in as_completed(pending):
                usm, algorithm = pending[future]
                try:
                    results.append(future.result())
                    print(f"COMPLETE USM {usm} {algorithm}: {len(results)}/{len(jobs)}", flush=True)
                except Exception as error:
                    failures.append({"usm": usm, "algorithm": algorithm, "error": repr(error)})
                    print(f"FAILED USM {usm} {algorithm}: {error}", flush=True)
    if failures:
        raise RuntimeError(f"{len(failures)} cases failed; complete cases are retained and resumable. See the error messages above")
    corrected_domains(args, series)


if __name__ == "__main__":
    main()
