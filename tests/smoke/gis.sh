#!/usr/bin/env bash
set -euo pipefail
fail=0
check(){ local d="$1"; shift; if "$@" >/dev/null 2>&1; then echo "OK:   $d"; else echo "FAIL: $d"; fail=1; fi; }
check "inherits base smoke"     bash /tests/smoke/base.sh
check "netcdf dev headers"      bash -c 'dpkg -s libnetcdf-dev libhdf5-dev'
check "ncdump"                  bash -c 'which ncdump && ncdump -h 2>&1 | grep -qiE "ncdump|netcdf"'
check "GDAL writes+reads NetCDF" bash -c 'gdal_create -outsize 2 2 -bands 1 -burn 1 -of GTiff /tmp/g.tif && gdal_translate -q -of netCDF /tmp/g.tif /tmp/g.nc && ncdump -h /tmp/g.nc | grep -q dimensions'
[ "$fail" -eq 0 ] && echo "SMOKE gis: ALL PASSED" || { echo "SMOKE gis: FAILURES"; exit 1; }
