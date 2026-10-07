# Acceptance: setupProject(standAlone = TRUE) provisions SpaDES.core + terra from binaries behind
# the firewall, then a trivial simInit + a terra read work. Run with PLAIN Rscript from this folder.
Require::setupOff()
options(pkgType = "both",
        repos = c(PredictiveEcology = "https://predictiveecology.r-universe.dev",
                  CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))
out <- SpaDES.project::setupProject(
  paths = list(projectPath = getwd()),
  standAlone = TRUE,
  packages = c("terra", "SpaDES.core"),
  updateRprofile = TRUE)
f <- tempfile(fileext = ".tif")
r <- terra::rast(nrows = 2, ncols = 2, vals = 1:4); terra::writeRaster(r, f)
stopifnot(terra::global(terra::rast(f), "sum")[[1]] == 10)
sim <- SpaDES.core::simInit(times = list(start = 0, end = 1))
stopifnot(inherits(sim, "simList"))
cat("ACCEPTANCE: PASSED\n")
