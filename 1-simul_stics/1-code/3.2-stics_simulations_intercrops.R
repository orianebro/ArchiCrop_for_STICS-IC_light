# Reproducible Beer/2.5D outputs for ArchiCrop. Each algorithm has an isolated
# XML workspace and a retained native-output directory. LAImax remains the
# accepted forcing convention; phenological dates come from native files and
# are backfilled within each species only.

run_stics_intercrops <- function(project_root, run_root = NULL,
                                cores = 4L,
                                usms = paste0("usm_", 1:63),
                                algorithms = c("Beer", "2.5D"),
                                publish = TRUE, plots = FALSE,
                                stics_exe = Sys.getenv("STICS_EXE", unset = "")) {
  project_root <- normalizePath(project_root, mustWork = TRUE)
  code <- file.path(project_root, "1-simul_stics", "1-code")
  source(file.path(code, "0-helpers.R"), local = TRUE)
  source(file.path(code, "intercrop_native_export.R"), local = TRUE)
  if (is.null(run_root)) run_root <- file.path(project_root, "1-simul_stics", "2-outputs",
                                               paste0("stics_intercrops_", Sys.Date()))
  dir.create(run_root, recursive = TRUE, showWarnings = FALSE)
  run_root <- normalizePath(run_root, mustWork = TRUE)
  if (!nzchar(stics_exe)) {
    home <- Sys.getenv("JAVASTICS_HOME", unset = "/Users/rvezy/Documents/dev/stics/JavaSTICS-v11.0.0-rc2")
    stics_exe <- file.path(home, "bin", if (Sys.info()[["sysname"]] == "Darwin") "stics_modulo_mac" else "stics_modulo")
  }
  stics_exe <- normalizePath(stics_exe, mustWork = TRUE)
  workspace <- normalizePath(file.path(project_root, "1-simul_stics", "0-data", "workspace_v11_gen"))
  canonical <- file.path(project_root, "1-simul_stics", "2-outputs", "simulations_stics_intercrops.csv")
  columns <- if (file.exists(canonical)) names(read.csv(canonical, nrows = 0)) else NULL
  if (publish && (!setequal(usms, paste0("usm_", 1:63)) ||
                  !setequal(algorithms, c("Beer", "2.5D")))) {
    stop("A partial run cannot replace the canonical forcing; use --no-publish")
  }
  if (!all(algorithms %in% c("Beer", "2.5D")) || cores < 1) stop("Invalid run options")
  read_native_option <- function(folder, filename, name) {
    text <- trimws(readLines(file.path(folder, filename), warn = FALSE))
    index <- which(text == name)
    if (length(index) != 1L) stop("Ambiguous native option ", name)
    as.numeric(text[index + 1L])
  }
  output <- list()
  for (algorithm in algorithms) {
    native <- file.path(run_root, algorithm)
      if (dir.exists(native) && length(list.files(native, all.files = TRUE, no.. = TRUE))) {
        stop("Refusing to replace already existing outputs: ", native)
      }
      xml_copy <- copy_stics_workspace(workspace, file.path(run_root, paste0("xml_", algorithm)))
      activate_light(xml_copy, algorithm)
      dir.create(native, recursive = TRUE, showWarnings = FALSE)
      message("Converting isolated ", algorithm, " XML inputs for ", length(usms), " USMs")
      SticsRFiles::gen_usms_xml2txt(workspace = xml_copy, out_dir = native, usm = usms,
                                  parallel = FALSE, verbose = FALSE)
      message("Running STICS for ", algorithm)
      results <- parallel::mclapply(usms, function(usm) {
        previous <- setwd(file.path(native, usm))
        on.exit(setwd(previous), add = TRUE)
        status <- system2(stics_exe, stdout = "stics_run_stdout.log", stderr = "stics_run_stderr.log")
        list(usm = usm, status = status)
      }, mc.cores = as.integer(cores), mc.preschedule = TRUE)
      if (any(vapply(results, function(x) is.null(x$status) || x$status != 0L, logical(1)))) {
        stop("STICS model execution failed; inspect retained per-case logs")
      }
    expected <- if (algorithm == "Beer") c(codetransrad = 1, codetradtec = 2) else c(codetransrad = 2, codetradtec = 1)
    for (usm in usms) for (plant in 1:2) {
      folder <- file.path(native, usm)
      actual <- c(codetransrad = read_native_option(folder, paste0("ficplt", plant, ".txt"), "codetransrad"),
                  codetradtec = read_native_option(folder, paste0("fictec", plant, ".txt"), "codetradtec"))
      if (!identical(unname(actual), unname(expected))) stop("Incorrect native radiation mode for ", usm)
    }
    output[[algorithm]] <- read_intercrop_native(native, algorithm, usms)

  }
  data <- combine_intercrop_native(output, columns)
  candidate <- file.path(run_root, "simulations_stics_intercrops.csv")
  write.csv(data, candidate, row.names = FALSE, na = "")
  if (publish) {
    temporary <- paste0(canonical, ".partial")
    stopifnot(file.copy(candidate, temporary, overwrite = TRUE))
    if (!file.rename(temporary, canonical)) stop("Could not atomically publish corrected forcing")
    doe <- file.path(project_root, "1-simul_stics", "2-outputs", "doe.csv")
    old_3d <- file.path(project_root, "3-3D_light_inter", "0-data", "doe.csv")
    stopifnot(file.copy(doe, old_3d, overwrite = TRUE))

  }
  if (plots) {
    # CroPlotR registers the standard S3 method rather than exporting plot().
    plot_method <- getS3method("plot", "cropr_simulation", envir = asNamespace("CroPlotR"))
    graphics <- do.call(plot_method, c(output, list(type = "dynamic", all_situations = TRUE,
                              var = c("laimax", "hauteur", "somupvtsem", "laisen_n", "raint", "trg_n"))))
    dir.create(file.path(run_root, "plots"), recursive = TRUE, showWarnings = FALSE)
    CroPlotR::save_plot_png(graphics, out_dir = file.path(run_root, "plots"), suffix = "_dynamic")
  }
  message("Exported ", nrow(data), " STICS forcing rows")
  invisible(data)
}

# Sourcing this file defines the API and does not start simulations.
if (sys.nframe() == 0L) {
  arguments <- commandArgs(trailingOnly = TRUE)
  value <- function(name, default = NULL) {
    index <- match(name, arguments)
    if (is.na(index)) return(default)
    if (index == length(arguments)) stop("Missing value for ", name)
    arguments[index + 1L]
  }
  script <- sub("^--file=", "", grep("^--file=", commandArgs(), value = TRUE)[1])
  project <- normalizePath(file.path(dirname(script), "..", ".."))
  selected <- strsplit(value("--usms", paste(1:63, collapse = ",")), ",", fixed = TRUE)[[1]]
  if (!all(grepl("^(usm_)?[0-9]+$", selected))) stop("Invalid --usms list")
  selected <- ifelse(grepl("^usm_", selected), selected, paste0("usm_", selected))
  algorithms <- strsplit(value("--algorithms", "Beer,2.5D"), ",", fixed = TRUE)[[1]]
  run_stics_intercrops(project, run_root = value("--run-root"),
                       cores = as.integer(value("--cores", "4")),
                       usms = selected, algorithms = algorithms,
                       publish = !("--no-publish" %in% arguments), plots = "--plots" %in% arguments)
}
