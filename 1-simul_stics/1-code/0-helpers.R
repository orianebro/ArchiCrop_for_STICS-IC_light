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
