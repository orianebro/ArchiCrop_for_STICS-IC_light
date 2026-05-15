# Objective: Run stics simulations of sole crops and their equivalent intercropping systems, with Beer and 2.5D formalisms, to compare with 3D simulations from ArchiCrop+Caribu.
# Output from this script are (inputs for ArchiCrop+Caribu for each simulation):
# 1. Dynamic outputs from STICS of LAI (laimax, laisen(n)), crop height (hauteur), thermal time corrected by stresses (somupvtsem), intercepted radiation (raint), incoming/transmitted radiation (trg(n) from each crop),
#  fraction of absorbed PAR (fapar), phenology (ilevs, iamfs, ilaxs), actual density (densite)
# 2. Inputs from STICS (from the meteo file) incoming radiation: trg(n) (this is for Caribu)
# 3. Parameters:
#   1. from tec file: interrow distance (plant-plant / species-species), row orientation, nrows per strip
#   2. from plant file: leaf lifespan (lifespanF) and ratio of lifespan between juvenile stage and exponential phase (ratiodurvieI)

library(SticsRPacks)

workspace <- normalizePath("0-data/workspace_v11_gen")
usms <- get_usms_list(file.path(workspace, "usms.xml"))
output_path <- file.path("2-outputs", "usms_txt_intercrops")
javastics_path <- "/Users/rvezy/Documents/dev/stics/JavaSTICS-v11.0.0-rc1"

gen_usms_xml2txt(
  # javastics = javastics_path,
  workspace = workspace,
  out_dir = output_path,
  parallel = TRUE
)

sim_options <- stics_wrapper_options(
  javastics = javastics_path,
  workspace = output_path,
  parallel = TRUE
)

sim_run <- stics_wrapper(
  sim_options,
  # param_values = NULL, # Update parameters from here directly, e.g. hauteur_threshold, or code_transrad?
  # var = NULL,
  # dates = NULL,
  # situation = "usm_1"
)

beer_params <- c(codetransrad = 1, codetradtec = 2)
radiative_transfer_params <- c(
  codetransrad = 2, # This is for activating the radiative transfer model in STICS (Beer or 2.5D)
  codetradtec = 1 # This is for activating the planting structure
)

sim_run_beer <- stics_wrapper(
  sim_options,
  param_values = beer_params,
)

sim_run_2.5D <- stics_wrapper(
  sim_options,
  param_values = radiative_transfer_params,
)

p <- plot(sim_run_beer$sim_list, type = "dynamic", all_situations = TRUE)
p$usm_1

sim_beer <- CroPlotR::bind_rows(sim_run_beer$sim_list)
sim_2.5D <- CroPlotR::bind_rows(sim_run_2.5D$sim_list)

sim_beer$algorithm <- "Beer"
sim_2.5D$algorithm <- "2.5D"

# Concatenate the two dataframes:
sim_all <- merge(sim_beer, sim_2.5D, all = TRUE)

write.csv(
  sim_all,
  file.path("2-outputs", "simulations_stics.csv"),
  row.names = FALSE
)

#! TODO:
# 1. check the plant files parameters + tec files too
# 2. Parameterize plant height ~ development for both maize and sorghum
# 3. Check the outputs of the simulations
