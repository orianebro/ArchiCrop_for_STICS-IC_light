from __future__ import annotations

import math
import sys
import time as t
from pathlib import Path
import csv

import pandas as pd

sys.path.append('../0-data')
from archi_dict import archi_sorghum_IC as archi_1
from archi_dict import archi_maize_IC as archi_2

from openalea.archicrop.n_demand import compute_n_demand
from openalea.archicrop.simulation import define_archicrop_parameters_IC, simulate_plant_growth_IC
from openalea.archicrop.stics_io import read_csv_file_IC

if __name__ == '__main__':

    path = "../../1-simul_stics/0-data/workspace_v11_gen/"

    plant_1 = "sorghum"
    plant_2 = "maize"

    id_sim = range(1,46) 
    id_usm = [f"usm_{i}" for i in id_sim]

    # Define the inputs for the simulation
    plant_file_1="../../1-simul_stics/0-data/workspace_v11_gen/plant/sorgho_trop_plt.xml"
    plant_file_2="../../1-simul_stics/0-data/workspace_v11_gen/plant/corn_LI_step2_BEOU_plt.xml"

    tec_files_1 = []
    tec_files_2 = []
    for i in id_sim:
        tec_files_1.append(path + f"{plant_1}_{i}_tec.xml")
        tec_files_2.append(path + f"{plant_2}_{i}_tec.xml")

    file_csv = "../../1-simul_stics/2-outputs/simulations_stics_intercrops.csv"

    d_outputs = read_csv_file_IC(file_csv)

    pot_factor_lai = 5
    pot_factor_height = 10

    save_scenes = True
    conv_coef = 100 # Conversion coefficient from meters to centimeters

    results = []

    for i, (usm, t1, t2) in enumerate(zip(id_usm, tec_files_1, tec_files_2)):

        # usm = f"usm_{i+1}"

        for algo in ["Beer", "2.5D"]:
            for plant, archi, plant_file, tec_file in zip([plant_1, plant_2], 
                                                          [archi_1, archi_2], 
                                                          [plant_file_1, plant_file_2], 
                                                          [t1, t2]):

                dates = [value["Date"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                plant_la = [value["Plant leaf area"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                d_la = [value["Leaf area increment"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_n_demand = [value["N demand"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_DM = [value["DM"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_DM_veg = [value["DM veg"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_DM_leaf = [value["DM leaf"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_DM_stem = [value["DM stem"] for value in d_outputs[usm][algo][plant].values() if value is not None]
                crop_bbch = [value["BBCH stage"] for value in d_outputs[usm][algo][plant].values() if value is not None]

                param_set, density = define_archicrop_parameters_IC(archi_params = archi, 
                                                        tec_file = tec_file, 
                                                        plant_file = plant_file, 
                                                        d_outputs = d_outputs[usm][algo][plant],
                                                        pot_factor_lai = pot_factor_lai,
                                                        pot_factor_height = pot_factor_height)

                realized_la, realized_h, mtgs = simulate_plant_growth_IC(
                    param_sets=param_set,
                    daily_dynamics=d_outputs[usm][algo][plant],
                )

                for k in param_set.keys():
                
                    plant_n_demand, plant_n_content, plant_leaf_mass, plant_stem_mass = compute_n_demand(
                        mtgs[k][dates[-1]],
                        dates,
                    )

                    for date, pla, dla, crop_n, crop_dm, crop_dm_veg, crop_dm_leaf, crop_dm_stem, bbch in zip(dates, plant_la, d_la, crop_n_demand, crop_DM, crop_DM_veg, crop_DM_leaf, crop_DM_stem, crop_bbch):
                        results.append({
                            "usm": usm,
                            "algo": algo,
                            "plant": plant,
                            "date": date,
                            "plant_leaf_area": pla,
                            "d_leaf_area": dla,
                            "nb_phy": param_set[k]["nb_phy"],
                            "nb_tillers": param_set[k]["nb_tillers"],
                            "diam_base": param_set[k]["diam_base"],
                            "SLA": param_set[k]["SLA"],
                            "N_conc_leaf": param_set[k]["N_conc_leaf"],
                            "vol_mass": param_set[k]["vol_mass"],
                            "N_conc_stem": param_set[k]["N_conc_stem"],
                            "density": density,
                            "leaf_area": realized_la[k][date],
                            "height": realized_h[k][date],
                            "plant_n_demand": plant_n_demand[date],
                            "plant_n_content": plant_n_content[date],
                            "plant_leaf_mass": plant_leaf_mass[date],
                            "plant_stem_mass": plant_stem_mass[date],
                            "crop_n_demand": crop_n,
                            "crop_DM": crop_dm,
                            "crop_DM_veg": crop_dm_veg,
                            "crop_DM_leaf": crop_dm_leaf,
                            "crop_DM_stem": crop_dm_stem,
                            "BBCH": bbch
                        })

    results_df = pd.DataFrame(results, columns=[
        "usm",
        "algo",
        "plant",
        "date",
        "plant_leaf_area",
        "d_leaf_area",
        "nb_phy",
        "nb_tillers",
        "diam_base",
        "SLA",
        "N_conc_leaf",
        "vol_mass",
        "N_conc_stem",
        "density",
        "leaf_area",
        "height",
        "plant_n_demand",
        "plant_n_content",
        "plant_leaf_mass",
        "plant_stem_mass",
        "crop_n_demand",
        "crop_DM",
        "crop_DM_veg",
        "crop_DM_leaf",
        "crop_DM_stem",
        "BBCH"
    ])

    # Save the results to a CSV file
    results_df.to_csv("../../4-analyses/0-data/n_demand_IC_results.csv", index=False)


