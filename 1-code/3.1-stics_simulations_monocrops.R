# Objective: Run stics simulations of sole crops and their equivalent intercropping systems, with Beer and 2.5D formalisms, to compare with 3D simulations from ArchiCrop+Caribu.
# Output from this script are (inputs for ArchiCrop+Caribu for each simulation):
# 1. Dynamic outputs from STICS of LAI (laimax, laisen(n)), crop height (hauteur), thermal time corrected by stresses (somupvtsem), intercepted radiation (raint), incoming/transmitted radiation (trg(n) from each crop),
#  fraction of absorbed PAR (fapar), phenology (ilevs, iamfs, ilaxs), actual density (densite)
# 2. Inputs from STICS (from the meteo file) incoming radiation: trg(n) (this is for Caribu)
# 3. Parameters:
#   1. from tec file: interrow distance (plant-plant / species-species), row orientation, nrows per strip
#   2. from plant file: leaf lifespan (lifespanF) and ratio of lifespan between juvenile stage and exponential phase (ratiodurvieI)

library(SticsRPacks)
library(ggplot2)

workspace <- normalizePath("0-data/workspace_v11")
usms <- get_usms_list(file.path(workspace, "usms.xml"))
output_path <- file.path("2-outputs", "usms_txt_monocrops")
javastics_path <- "/Users/rvezy/Documents/dev/stics/JavaSTICS-v11.0.0-rc1"

# usms <- SticsRFiles::get_usms_list(file.path(workspace, "usms.xml"))
sim_options <- stics_wrapper_options(
  javastics = javastics_path,
  workspace = output_path,
  parallel = TRUE
)

# Activate Beer or 2.5D in the plant and tec files:
activate_light <- function(workspace, algorithm = c("Beer", "2.5D")) {
  files_in_usms <- SticsRFiles::get_files_list(workspace)
  files_usm <- lapply(files_in_usms, function(files_usm) {
    # If the file ends with "_plt.xml", it's a plant file, and if it ends with "_tec.xml", it's a tec file.
    # In this case we return their paths:
    files <- files_usm$paths
    plant_paths <- files[grepl("_plt.xml", files)]
    tec_paths <- files[grepl("_tec.xml", files)]

    list(plant = plant_paths, tec = tec_paths)
  })

  if (algorithm == "Beer") {
    params <- list(codetransrad = 1, codetradtec = 2)
  } else if (algorithm == "2.5D") {
    params <- list(codetransrad = 2, codetradtec = 1)
  } else {
    stop("Algorithm must be either 'Beer' or '2.5D'")
  }

  lapply(files_usm, function(usm_f) {
    # Update the parameters in the tec files:
    for (tec_path in usm_f$tec) {
      SticsRFiles::set_param_xml(
        tec_path,
        "codetradtec",
        params$codetradtec,
        overwrite = TRUE
      )
    }
    # Update the parameters in the plant files:
    for (plant_path in usm_f$plant) {
      SticsRFiles::set_param_xml(
        plant_path,
        "codetransrad",
        params$codetransrad,
        overwrite = TRUE
      )
    }
  })
}

# Run Beer simulations:
activate_light(workspace = workspace, algorithm = "Beer")
gen_usms_xml2txt(
  workspace = workspace,
  out_dir = output_path,
  parallel = TRUE,
  usm = c("sorghum_monocrop", "maize_BEOU_monocrop")
)
sim_run_beer <- stics_wrapper(sim_options)

# Run 2.5D simulations:
activate_light(workspace = workspace, algorithm = "2.5D")
gen_usms_xml2txt(
  workspace = workspace,
  out_dir = output_path,
  parallel = TRUE,
  usm = c("sorghum_monocrop", "maize_BEOU_monocrop")
)

sim_run_2.5D <- stics_wrapper(sim_options)

p <- plot(
  Beer = sim_run_beer$sim_list,
  "2.5D" = sim_run_2.5D$sim_list,
  type = "dynamic",
  all_situations = TRUE,
  var = c(
    "laimax",
    "hauteur",
    "somupvtsem",
    "laisen_n",
    "raint",
    "trg_n"
  )
)
p[["maize_BEOU_monocrop"]]
p[["sorghum_monocrop"]]

ggsave(
  p[["maize_BEOU_monocrop"]],
  filename = file.path("2-outputs", "simulations_stics_monocrops_maize.png"),
  width = 12,
  height = 6
)
ggsave(
  p[["sorghum_monocrop"]],
  filename = file.path("2-outputs", "simulations_stics_monocrops_sorghum.png"),
  width = 12,
  height = 6
)

sim_beer <- CroPlotR::bind_rows(sim_run_beer$sim_list)
sim_2.5D <- CroPlotR::bind_rows(sim_run_2.5D$sim_list)

sim_beer$algorithm <- "Beer"
sim_2.5D$algorithm <- "2.5D"

# Concatenate the two dataframes:
sim_all <- merge(sim_beer, sim_2.5D, all = TRUE)

write.csv(
  sim_all,
  file.path("2-outputs", "simulations_stics_monocrops.csv"),
  row.names = FALSE
)

#! TODO:
# 1. check why hauteur is impacted, we should have chosen the height~dev relationship so it shouldn't change
# 2. Truly parameterize plant height ~ development for both maize and sorghum
# 3. Check the outputs of the simulations
