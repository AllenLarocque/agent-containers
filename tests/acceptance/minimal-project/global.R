# Acceptance: setupProject(standAlone = TRUE) provisions SpaDES.core + terra (+ googledrive) from
# binaries behind the firewall, then a trivial simInit, a terra read and an anonymous Google Drive
# prepInputs() work. Run with PLAIN Rscript from this folder.
Require::setupOff()
options(pkgType = "both",
        repos = c(PredictiveEcology = "https://predictiveecology.r-universe.dev",
                  CRAN = "https://packagemanager.posit.co/cran/__linux__/noble/latest"))
out <- SpaDES.project::setupProject(
  paths = list(projectPath = getwd()),
  standAlone = TRUE,
  packages = c("terra", "SpaDES.core", "googledrive"),
  updateRprofile = TRUE)
f <- tempfile(fileext = ".tif")
r <- terra::rast(nrows = 2, ncols = 2, vals = 1:4); terra::writeRaster(r, f)
stopifnot(terra::global(terra::rast(f), "sum")[[1]] == 10)
sim <- SpaDES.core::simInit(times = list(start = 0, end = 1))
stopifnot(inherits(sim, "simList"))
# Google Drive through the base allowlist, the usual SpaDES way, with NO Google sign-in: a public
# ("anyone with the link") zip owned by the project owner (shared for this test, 2026-11-04).
# reproducible.gdriveNoAuth = TRUE forces the anonymous rung, so this proves no login is needed.
cat("reproducible", format(packageVersion("reproducible")), "\n")
options(reproducible.gdriveNoAuth = TRUE)
dl <- file.path(tempdir(), "gdrive")
got <- reproducible::prepInputs(
  url = "https://drive.google.com/file/d/1NMxY_yb9XYlTov9sxK4idgrByD0HGNb6/view?usp=sharing",
  destinationPath = dl, fun = NA)
zips <- list.files(dl, pattern = "[.]zip$", full.names = TRUE)
stopifnot(length(zips) >= 1, all(file.size(zips) > 0))
cat("Google Drive (anonymous):", basename(zips), "->", length(list.files(dl)), "file(s)\n")
cat("ACCEPTANCE: PASSED\n")
