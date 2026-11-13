# Native STICS output is the authority for forcing ArchiCrop. In particular,
# do not export stics_wrapper()$sim_list: SticsOnR 1.3.0 fills phenological NA
# values across species. This reader keeps a missing stage as the STICS zero
# sentinel and backfills an observed stage only within its own crop.

backfill_crop_stages <- function(data, stages = c("ilevs", "iamfs", "ilaxs")) {
  stopifnot(is.data.frame(data), "pla" %in% names(data))
  for (crop in unique(data$pla)) {
    indices <- which(data$pla == crop)
    indices <- indices[order(data$Date[indices])]
    for (stage in intersect(stages, names(data))) {
      values <- as.numeric(data[[stage]][indices])
      if (any(!is.finite(values)) || any(values < 0)) {
        stop("Invalid native phenology for ", crop, "/", stage)
      }
      next_event <- 0
      for (index in rev(seq_along(values))) {
        if (values[index] > 0) {
          next_event <- values[index]
        } else if (next_event > 0) {
          values[index] <- next_event
        }
      }
      data[[stage]][indices] <- values
    }
  }
  data
}

read_intercrop_native <- function(output_path, algorithm, usms) {
  stopifnot(length(algorithm) == 1L, algorithm %in% c("Beer", "2.5D"))
  species <- c(sor = "sorghum", mai = "maize", ble = "wheat")
  output <- setNames(vector("list", length(usms)), usms)
  for (usm in usms) {
    folder <- file.path(output_path, usm)
    required <- file.path(folder, paste0(c("mod_sp", "mod_sa"), usm, ".sti"))
    if (!all(file.exists(required))) stop("Missing native output for ", usm)
    raw <- SticsRFiles::get_sim(folder, verbose = FALSE)[[1]]
    if (is.null(raw) || !nrow(raw)) stop("Empty native output for ", usm)
    raw$Date <- as.Date(raw$Date)
    if (anyDuplicated(paste(raw$Date, raw$pla))) {
      stop("Duplicate date/species in ", usm)
    }
    for (crop in unique(raw$pla)) {
      days <- sort(raw$Date[raw$pla == crop])
      if (length(days) > 1 && any(as.numeric(diff(days)) != 1)) {
        stop("Non-contiguous native calendar in ", usm, "/", crop)
      }
    }
    data <- backfill_crop_stages(raw)
    data$Plant <- unname(species[as.character(data$pla)])
    if (anyNA(data$Plant)) stop("Unknown crop code in ", usm)
    data$situation <- usm
    data$algorithm <- algorithm
    output[[usm]] <- data
  }
  structure(output, class = "cropr_simulation")
}

combine_intercrop_native <- function(outputs, columns = NULL) {
  tables <- unlist(outputs, recursive = FALSE)
  data <- do.call(rbind, unname(tables))
  rownames(data) <- NULL
  usm_number <- as.integer(sub("^usm_", "", data$situation))
  data <- data[order(usm_number, match(data$algorithm, c("Beer", "2.5D")),
                     data$Date, data$pla), , drop = FALSE]
  rownames(data) <- NULL
  if (!is.null(columns)) {
    missing <- setdiff(columns, names(data))
    if (length(missing)) stop("Missing exported columns: ", paste(missing, collapse = ", "))
    data <- data[, columns, drop = FALSE]
  }
  if (anyDuplicated(paste(data$situation, data$algorithm, data$Date, data$pla))) {
    stop("Duplicate case/date/species in aggregate export")
  }
  data
}

copy_stics_workspace <- function(source, destination) {
  if (dir.exists(destination) && length(list.files(destination, all.files = TRUE,
                                                   no.. = TRUE))) {
    stop("Refusing to replace existing XML workspace: ", destination)
  }
  dir.create(destination, recursive = TRUE, showWarnings = FALSE)
  files <- list.files(source, full.names = TRUE, all.files = TRUE, no.. = TRUE)
  copied <- file.copy(files, destination, recursive = TRUE, copy.mode = TRUE)
  if (!all(copied)) stop("Incomplete isolated XML workspace copy")
  normalizePath(destination, mustWork = TRUE)
}

