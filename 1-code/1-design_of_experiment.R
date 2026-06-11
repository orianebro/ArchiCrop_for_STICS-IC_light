# Objective: Define all information for running simulations of sole crops and their equivalent intercropping systems, with STICS (Beer and 2.5D formalisms), or ArchiCrop+Caribu.
# Output from this script are:
# 1. Table with: species simulated (principal and secondary), design name (sole crop, intercrop mixed, intercrop alternate, intercrop strips), row orientation, interrow distance, sowing date for latest crop,
# 2. Table for mapping true vs stics interrow designs; because stics make some simplifications and defines interrow as inter-same species (see vezy et al. (2023) fig. 2)

species <- c("sorghum", "maize_trop")
designs <- c(
  # "sole crop",
  "intercrop mixed",
  "intercrop alternate",
  "intercrop strips"
)

row_orientations <- c("N-S", "E-W") # 0 and pi/2 for stics

# For the intercropping designs, we will have variations in interrow distance, number of rows per strip, or intrarow_distance depending on the design. We will have 3 levels of variation for each of these factors (high, middle, low).
interrow_distance = c("high", "middle", "low") # This is only for "intercrop alternate" design where we will have 3 levels of interrow distance
n_rows = c("high", "middle", "low") # This is only for the strip design. For stics, this is the number of rows per strip (for intercropping)
intrarow_distance <- c("high", "middle", "low") # This is only for the intercrop mixed design
sowing_date_latest_crop <- c("same", "later") # This is for activating relay strips

# df_doe <- expand.grid(
#   species = species,
#   design = designs,
#   row_orientations = row_orientations,
#   variation = interrow_distance # High, middle, low for either interrow distance, number of rows per strip, or intrarow_distance depending on the design
# )

df_doe <- data.frame()
for (i in designs) {
  if (i == "intercrop alternate") {
    for (j in row_orientations) {
      for (k in interrow_distance) {
        df_doe <- rbind(
          df_doe,
          data.frame(
            species_id = paste(species, collapse = "-"),
            species_principal = species[1],
            species_secondary = species[2],
            design = i,
            row_orientation = j,
            interrow_distance_principal = k,
            interrow_distance_secondary = k,
            n_rows_principal = "one",
            n_rows_secondary = "one",
            intrarow_distance = "middle",
            sowing_date_latest_crop = "same" # This is not relevant for the alternate design
          )
        )
      }
    }
  } else if (i == "intercrop strips") {
    for (j in row_orientations) {
      for (k in n_rows) {
        for (l in n_rows) {
          for (m in sowing_date_latest_crop) {
            df_doe <- rbind(
              df_doe,
              data.frame(
                species_id = paste(species, collapse = "-"),
                species_principal = species[1],
                species_secondary = species[2],
                design = i,
                row_orientation = j,
                interrow_distance_principal = "middle",
                interrow_distance_secondary = "middle",
                n_rows_principal = k,
                n_rows_secondary = l,
                intrarow_distance = "middle",
                sowing_date_latest_crop = m
              )
            )
          }
        }
      }
    }
  } else if (i == "intercrop mixed") {
    for (k in intrarow_distance) {
      df_doe <- rbind(
        df_doe,
        data.frame(
          species_id = paste(species, collapse = "-"),
          species_principal = species[1],
          species_secondary = species[2],
          design = i,
          row_orientation = "N-S", # This is not relevant for the mixed design, but we need to put something for stics
          interrow_distance_principal = "middle",
          interrow_distance_secondary = "middle",
          n_rows_principal = "one", # this is 1 row, no strip
          n_rows_secondary = "one", # this is 1 row, no strip
          intrarow_distance = k,
          sowing_date_latest_crop = "same" # This is not relevant for the mixed design, but we need to put something for stics
        )
      )
    }
  }
}

df_doe

write.csv(df_doe, "2-outputs/doe.csv", row.names = FALSE)
