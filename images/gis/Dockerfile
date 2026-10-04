# spades-gis: R-only geospatial work (mapping, predictive modelling, R-based fire models).
# Adds only NetCDF/HDF5 on top of base (GDAL/GEOS/PROJ are already in base). Spec §3.2.
ARG BASE_IMAGE=ghcr.io/allenlarocque/spades-base:latest
FROM ${BASE_IMAGE}
USER root
RUN apt-get update && apt-get install -y --no-install-recommends \
      libnetcdf-dev netcdf-bin libhdf5-dev \
    && apt-get clean && rm -rf /var/lib/apt/lists/*
USER agent
