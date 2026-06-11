# Purpose: Create the stics simulations for the different treatments defined in the design of experiment

# Read the design of experiment defined in 1-design_of_experiment.R
df_doe <- read.csv("2-outputs/doe.csv")
df_doe$interrow_stics <- NA
df_doe$sowing_density <- NA

# Define the original workspace and the generated workspaces for the simulations
original_workspace <- "0-data/workspace_v11"
generated_workspace <- "0-data/workspace_v11_gen"

# Mapping parameters to values:
row_orientation_values <- c(
  "N-S" = 0,
  "E-W" = pi / 2
)

interrow_distance_per_species <- list(
  "sorghum" = c(
    "high" = 0.9,
    "middle" = 0.6,
    "low" = 0.3
  ),
  "maize_trop" = c(
    "high" = 0.9,
    "middle" = 0.6,
    "low" = 0.3
  ),
  "maize_temp" = c(
    "high" = 0.9,
    "middle" = 0.6,
    "low" = 0.3
  ),
  "wheat" = c(
    "high" = 0.4,
    "middle" = 0.2,
    "low" = 0.1
  )
)

n_rows_per_species <- list(
  "sorghum" = c(
    "one" = 1, # For non-strip, this is just one row
    "high" = 6,
    "middle" = 4,
    "low" = 2
  ),
  "maize_trop" = c(
    "one" = 1,
    "high" = 6,
    "middle" = 4,
    "low" = 2
  ),
  "maize_temp" = c(
    "one" = 1,
    "high" = 6,
    "middle" = 4,
    "low" = 2
  ),
  "wheat" = c(
    "one" = 1,
    "high" = 12,
    "middle" = 6,
    "low" = 2
  )
)

intrarow_distance_per_species <- list(
  "sorghum" = c(
    "high" = 0.4,
    "middle" = 0.3, # ~5.5 plants per m2 with 0.6m interrow distance, gives 0.3m intrarow distance
    "low" = 0.2
  ),
  "maize_trop" = c(
    "high" = 0.4,
    "middle" = 0.3,
    "low" = 0.2
  ),
  "maize_temp" = c(
    "high" = 0.4,
    "middle" = 0.3,
    "low" = 0.2
  ),
  "wheat" = c(
    "high" = 0.1,
    "middle" = 0.07,
    "low" = 0.04
  )
)

sowing_date <- 177
sowing_delay <- c("same" = 0, "later" = 20)

## Create the tec files

variety_code_per_species <- c(
  sorghum = 1, # We only have one variety
  maize_trop = 20, # MANT, from the tec file we are using as reference
  maize_temp = 4,
  wheat = 1
)

# Reference tec files from the sole crops:
tec_ref <- c(
  sorghum = file.path("0-data", "workspace_v11", "02NT18SorgV2D1_tec.xml"),
  maize_trop = file.path("0-data", "workspace_v11", "maize_monocrop_tec.xml"),
  maize_temp = file.path("0-data", "workspace_v11", "maize_monocrop_tec.xml"),
  wheat = file.path("0-data", "workspace_v11", "wheat_monocrop_tec.xml")
)

#! start loop over the rows of the design of experiment here
for (doe_row in 1:nrow(df_doe)) {
  # doe_row <- 1
  sim = df_doe[doe_row, ] # This is just to test the code on one row of the design of experiment, we will then loop over all rows

  row_orientation <- row_orientation_values[sim$row_orientation]
  design <- sim$design
  species <- c(
    principal = sim$species_principal,
    secondary = sim$species_secondary
  )

  interrow_distance <- c(
    interrow_distance_per_species[[species["principal"]]][
      sim$interrow_distance_principal
    ],
    interrow_distance_per_species[[species["secondary"]]][
      sim$interrow_distance_secondary
    ]
  )
  names(interrow_distance) <- species

  is_strip <- ifelse(design == "intercrop strips", TRUE, FALSE)

  n_rows <- c(
    n_rows_per_species[[species["principal"]]][sim$n_rows_principal],
    n_rows_per_species[[species["secondary"]]][sim$n_rows_secondary]
  )
  names(n_rows) <- species

  sowing_date_latest_crop <- sim$sowing_date_latest_crop
  intrarow_distance <- sim$intrarow_distance

  for (i in species) {
    # i <- species[1]
    tec_file <- tec_ref[i]
    new_tec_file <-
      file.path(
        generated_workspace,
        paste0(i, "_", doe_row, "_tec.xml")
      )
    file.copy(tec_file, new_tec_file, overwrite = TRUE)

    SticsRFiles::set_param_xml(
      new_tec_file,
      "orientrang",
      row_orientation,
      overwrite = TRUE
    )

    SticsRFiles::set_param_xml(
      new_tec_file,
      "variete",
      variety_code_per_species[i], # MANT
      overwrite = TRUE
    )

    if (design == "intercrop mixed") {
      # For the mixed design, we need take the interrow distance as is (see vezy et al. 2023, Fig 2)
      df_doe$interrow_stics[doe_row] <- interrow_distance[i]
    } else {
      # For the other designs, we compute it:
      df_doe$interrow_stics[doe_row] <-
        (n_rows[1] - 1) *
        interrow_distance[1] +
        (n_rows[2] - 1) * interrow_distance[2] +
        2 * max(interrow_distance)
    }

    SticsRFiles::set_param_xml(
      new_tec_file,
      "interrang",
      df_doe$interrow_stics[doe_row],
      overwrite = TRUE
    )

    if (is_strip) {
      SticsRFiles::set_param_xml(
        new_tec_file,
        "code_strip",
        1,
        overwrite = TRUE
      )

      SticsRFiles::set_param_xml(
        new_tec_file,
        "nrow",
        n_rows[i],
        overwrite = TRUE
      )
    }

    intrarow_distance_value <-
      intrarow_distance_per_species[[species["principal"]]][intrarow_distance]

    df_doe$sowing_density[doe_row] <- 1 /
      (interrow_distance[i] * intrarow_distance_value)

    SticsRFiles::set_param_xml(
      new_tec_file,
      "densitesem",
      df_doe$sowing_density[doe_row],
      overwrite = TRUE
    )

    if (i == species["secondary"]) {
      SticsRFiles::set_param_xml(
        new_tec_file,
        "iplt0",
        sowing_date + sowing_delay[sim$sowing_date_latest_crop],
        overwrite = TRUE
      )
    } else {
      SticsRFiles::set_param_xml(
        new_tec_file,
        "iplt0",
        sowing_date,
        overwrite = TRUE
      )
    }
  }
}

# Copy ini file:
file.copy(
  file.path(original_workspace, "inter-sorghum-maize_ini.xml"),
  file.path(generated_workspace, "inter-sorghum-maize_ini.xml"),
  overwrite = TRUE
)

# copy plant files:
dir.create(file.path(generated_workspace, "plant"), showWarnings = FALSE)

plt_files <- c(
  sorghum = "sorgho_trop_plt.xml",
  maize_trop = "corn_LI_step2_MANT_plt.xml"
)

file.copy(
  file.path(original_workspace, "plant", plt_files["sorghum"]),
  file.path(generated_workspace, "plant", plt_files["sorghum"]),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "plant", plt_files["maize_trop"]),
  file.path(generated_workspace, "plant", plt_files["maize_trop"]),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "param_gen.xml"),
  file.path(generated_workspace, "param_gen.xml"),
  overwrite = TRUE
)
# Do we update hauteur_threshold? If not, the secondary crop may die in the early stages due to overestimated competition for light

file.copy(
  file.path(original_workspace, "param_newform.xml"),
  file.path(generated_workspace, "param_newform.xml"),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "sols.xml"),
  file.path(generated_workspace, "sols.xml"),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "StationNtarla_inter_sta.xml"),
  file.path(generated_workspace, "StationNtarla_inter_sta.xml"),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "var.mod"),
  file.path(generated_workspace, "var.mod"),
  overwrite = TRUE
)
# SticsRFiles::gen_varmod()

file.copy(
  file.path(original_workspace, "ntarla_corr.2018"),
  file.path(generated_workspace, "ntarla_corr.2018"),
  overwrite = TRUE
)

# Create the usms in the usms.xml file, each named after the doe row, and linking to the tec file needed.

usms_param_df <- data.frame(
  usm = paste0("usm_", 1:nrow(df_doe)),
  datedebut = 135,
  datefin = 365,
  finit = "inter-sorghum-maize_ini.xml",
  nomsol = "02V2D1",
  fstation = "StationNtarla_inter_sta.xml",
  fclim1 = "ntarla_corr.2018",
  fclim2 = "ntarla_corr.2018",
  culturean = 1,
  nbplantes = 2,
  codesimul = 0,
  fplt_1 = plt_files[df_doe$species_principal],
  fplt_2 = plt_files[df_doe$species_secondary],
  ftec_1 = paste0(df_doe$species_principal, "_", 1:nrow(df_doe), "_tec.xml"),
  ftec_2 = paste0(df_doe$species_secondary, "_", 1:nrow(df_doe), "_tec.xml")
)

SticsRFiles::gen_usms_xml(
  file.path(generated_workspace, "usms.xml"),
  param_df = usms_param_df
)

SticsRFiles::upgrade_usms_xml_10_11(
  file.path(generated_workspace, "usms.xml"),
  generated_workspace,
  overwrite = TRUE
)

write.csv(df_doe, "2-outputs/doe_realized.csv", row.names = FALSE)
