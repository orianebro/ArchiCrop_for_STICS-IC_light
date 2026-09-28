# Run only the three Arminda/Pactol USMs; existing simulation outputs are untouched.
library(SticsRFiles)
file_arg <- grep('^--file=', commandArgs(FALSE), value = TRUE)
stopifnot(length(file_arg) == 1L)
workspace <- dirname(normalizePath(sub('^--file=', '', file_arg)))
args <- commandArgs(TRUE)
out_dir <- if (length(args)) args[1] else file.path(workspace, '..', '..', '2-outputs', 'relay_Arminda_Pactol')
dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
out_dir <- normalizePath(out_dir)
javastics <- Sys.getenv('JAVASTICS_HOME', '/Users/rvezy/Documents/dev/stics/JavaSTICS-v11.0.0-rc2')
exe <- Sys.getenv('STICS_EXE', file.path(javastics, 'bin', 'stics_modulo_mac'))
stopifnot(file.exists(exe))
usms <- c('Auzeville_Arminda_Pactol_relay_2007', 'Auzeville_Arminda_monocrop_2007', 'Auzeville_Pactol_monocrop_2007')
gen_usms_xml2txt(javastics = javastics, workspace = workspace, out_dir = out_dir, usm = usms, parallel = FALSE)
for (usm in usms) {
  local({
    run_dir <- file.path(out_dir, usm)
    # No soil profiles requested: avoid inheriting the unrelated 2000 profile date.
    writeLines('0', file.path(run_dir, 'prof.mod'))
    original_dir <- setwd(run_dir)
    on.exit(setwd(original_dir))
    status <- system2(exe, stdout = 'execution.log', stderr = 'execution.stderr.log')
    if (status != 0L) stop(usm, ': STICS failed (', status, '). See ', run_dir, '/stics_errors.log')
    message(usm, ': OK')
  })
}
message('Results: ', out_dir)
