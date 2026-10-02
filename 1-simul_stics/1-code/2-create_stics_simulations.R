# Purpose: Create the stics simulations for the different treatments defined in the design of experiment

# Read the design of experiment defined in 1-design_of_experiment.R
df_doe <- read.csv("2-outputs/doe.csv")
df_doe$interrow_stics_1 <- NA
df_doe$interrow_stics_2 <- NA
df_doe$sowing_density_1 <- NA
df_doe$sowing_density_2 <- NA

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
    "high" = 0.8,
    "middle" = 0.4,
    "low" = 0.2
  ),
  "maize_trop" = c(
    "high" = 0.8,
    "middle" = 0.4,
    "low" = 0.2
  ),
  "maize_temp" = c(
    "middle" = 0.75
  ),
  "wheat" = c(
    "middle" = 0.125
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
    "high" = 6,
    "middle" = 4,
    "low" = 2
  ),
  "wheat" = c(
    "high" = 14,
    "middle" = 10,
    "low" = 6
  )
)

intrarow_distance_per_species <- list(
  "sorghum" = c(
    "middle" = 0.4
  ),
  "maize_trop" = c(
    "middle" = 0.4
  ),
  "maize_temp" = c(
    "middle" = 0.222
  ),
  "wheat" = c(
    "middle" = 0.074
  )
)

sowing_delay <- c("same" = 0, "later" = 20)

sowing_date_per_species <- c(
  sorghum = 177,
  maize_trop = 177,
  wheat = 298, # 25 october, year 1
  maize_temp = 473 # 18 april, year 2
)

## Create the tec files
variety_code_per_species <- c(
  sorghum = 1, # We only have one variety
  maize_trop = 17, # BEOU, from the tec file we are using as reference
  maize_temp = 2, # Pactol
  wheat = 1 # Arminda
)

# Reference tec files from the sole crops:
tec_ref <- c(
  sorghum = file.path("0-data", "workspace_v11", "02NT18SorgV2D1_tec.xml"),
  maize_trop = file.path("0-data", "workspace_v11", "maize_monocrop_tec.xml"),
  maize_temp = file.path(
    "0-data",
    "workspace_v11",
    "maize_relay_monocrop_tec.xml"
  ),
  wheat = file.path("0-data", "workspace_v11", "wheat_relay_monocrop_tec.xml")
)

#! start loop over the rows of the design of experiment here
for (doe_row in 1:nrow(df_doe)) {
  # doe_row <- 46
  sim <- df_doe[doe_row, ] # This is just to test the code on one row of the design of experiment, we will then loop over all rows

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
  intrarow_distance <- sim$intrarow_distance #! should be by species no?

  interrow_stics <- c(NA, NA)
  names(interrow_stics) <- species
  sowing_density <- c(NA, NA)
  names(sowing_density) <- species

  for (i in species) {
    # i <- species[2]
    tec_file <- tec_ref[i]
    new_tec_file <-
      file.path(
        generated_workspace,
        paste0(i, "_", doe_row, "_tec.xml")
      )
    file.copy(tec_file, new_tec_file, overwrite = TRUE)

    # Emergence is not observed for the generated treatments. Let STICS
    # calculate it from soil and weather for both crops.
    SticsRFiles::set_param_xml(
      new_tec_file,
      "codestade",
      2,
      overwrite = TRUE
    )
    SticsRFiles::set_param_xml(
      new_tec_file,
      "ilev",
      999,
      overwrite = TRUE
    )

    SticsRFiles::set_param_xml(
      new_tec_file,
      "orientrang",
      row_orientation,
      overwrite = TRUE
    )

    SticsRFiles::set_param_xml(
      new_tec_file,
      "variete",
      variety_code_per_species[i],
      overwrite = TRUE
    )

    intrarow_distance_value <-
      intrarow_distance_per_species[[i]][
        intrarow_distance
      ]

    if (design == "intercrop mixed") {
      # For the mixed design, we need take the interrow distance as is (see vezy et al. 2023, Fig 2)
      interrow_stics[i] <- interrow_distance[i] # this is just the interrow of the sowing machine
      sowing_density[i] <- 1 / (interrow_distance[i] * intrarow_distance_value)
    } else if (design == "intercrop alternate") {
      if (interrow_distance[1] != interrow_distance[2]) {
        stop(
          "For the alternate design, the interrow distance must be the same for both species. Please check your design of experiment."
        )
      }
      interrow_stics[i] <- interrow_distance[1] * 2 # in alternate design, we provide it between two rows of the same species.
      # This is a particular case of the equation given for the strips
      sowing_density[i] <- 1 / (interrow_stics[i] * intrarow_distance_value)
    } else if (design == "intercrop strips") {
      interrow_stics[i] <- n_rows[1] *
        interrow_distance[1] +
        n_rows[2] * interrow_distance[2]
      # interrow_stics can be viewed as the total width of the intercrop scene
      sowing_density[i] <-
        1 / ((interrow_stics[i] / n_rows[i]) * intrarow_distance_value)
    } else {
      stop("Design not recognized. Please check your design of experiment.")
    }

    SticsRFiles::set_param_xml(
      new_tec_file,
      "interrang",
      interrow_stics[i],
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

    SticsRFiles::set_param_xml(
      new_tec_file,
      "densitesem",
      sowing_density[i],
      overwrite = TRUE
    )

    if (i == species["secondary"]) {
      SticsRFiles::set_param_xml(
        new_tec_file,
        "iplt0",
        sowing_date_per_species[i] + sowing_delay[sim$sowing_date_latest_crop],
        overwrite = TRUE
      )
    } else {
      SticsRFiles::set_param_xml(
        new_tec_file,
        "iplt0",
        sowing_date_per_species[i],
        overwrite = TRUE
      )
    }
  }

  df_doe$interrow_stics_1[doe_row] <- interrow_stics[1]
  df_doe$interrow_stics_2[doe_row] <- interrow_stics[2]
  df_doe$sowing_density_1[doe_row] <- sowing_density[1]
  df_doe$sowing_density_2[doe_row] <- sowing_density[2]
}

# Copy ini files:
file.copy(
  file.path(original_workspace, "inter-sorghum-maize_ini.xml"),
  file.path(generated_workspace, "inter-sorghum-maize_ini.xml"),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "relay_Auzeville_2plants_ini.xml"),
  file.path(generated_workspace, "relay_Auzeville_2plants_ini.xml"),
  overwrite = TRUE
)

# copy plant files:
dir.create(file.path(generated_workspace, "plant"), showWarnings = FALSE)

plt_files <- c(
  sorghum = "sorgho_trop_plt.xml",
  maize_trop = "corn_LI_step2_BEOU_plt.xml",
  maize_temp = "maize_relay_plt.xml",
  wheat = "wheat_relay_plt.xml"
)

for (i in names(plt_files)) {
  if (!file.exists(file.path(original_workspace, "plant", plt_files[i]))) {
    stop(paste0(
      "Plant file for ",
      i,
      " does not exist in the original workspace."
    ))
  }

  file.copy(
    file.path(original_workspace, "plant", plt_files[i]),
    file.path(generated_workspace, "plant", plt_files[i]),
    overwrite = TRUE
  )
}

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
  file.path(original_workspace, "Auzeville_relay_sta.xml"),
  file.path(generated_workspace, "Auzeville_relay_sta.xml"),
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

file.copy(
  file.path(original_workspace, "auzevilj.2006"),
  file.path(generated_workspace, "auzevilj.2006"),
  overwrite = TRUE
)

file.copy(
  file.path(original_workspace, "auzevilj.2007"),
  file.path(generated_workspace, "auzevilj.2007"),
  overwrite = TRUE
)

# Create the usms in the usms.xml file, each named after the doe row, and linking to the tec file needed.

usms_param_df <- data.frame(
  usm = paste0("usm_", 1:nrow(df_doe)),
  datedebut = ifelse(df_doe$species_id == "sorghum-maize_trop", 135, 268),
  datefin = ifelse(df_doe$species_id == "sorghum-maize_trop", 365, 730),
  finit = ifelse(
    df_doe$species_id == "sorghum-maize_trop",
    "inter-sorghum-maize_ini.xml",
    "relay_Auzeville_2plants_ini.xml"
  ),
  nomsol = ifelse(
    df_doe$species_id == "sorghum-maize_trop",
    "02V2D1",
    "Auzeville_relay_2006_2007"
  ),
  fstation = ifelse(
    df_doe$species_id == "sorghum-maize_trop",
    "StationNtarla_inter_sta.xml",
    "Auzeville_relay_sta.xml"
  ),
  fclim1 = ifelse(
    df_doe$species_id == "sorghum-maize_trop",
    "ntarla_corr.2018",
    "auzevilj.2006"
  ),
  fclim2 = ifelse(
    df_doe$species_id == "sorghum-maize_trop",
    "ntarla_corr.2018",
    "auzevilj.2007"
  ),
  culturean = ifelse(df_doe$species_id == "sorghum-maize_trop", 1, 2),
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

SticsRFiles:::upgrade_usms_xml_10_11(
  file.path(generated_workspace, "usms.xml"),
  generated_workspace,
  overwrite = TRUE
)

write.csv(df_doe, "2-outputs/doe_realized.csv", row.names = FALSE)
