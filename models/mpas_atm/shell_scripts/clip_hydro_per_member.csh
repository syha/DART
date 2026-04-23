
#!/bin/csh -f
# ------------------------------------------------------------------------------
# clip_hydro_per_member.csh
#
# Purpose:
#   For BNRHF, ensures all hydrometeor variables in a single MPAS NetCDF file are non-negative.
#   This script sets any negative values of qv, qc, qr, qi, qs, qg, qh, q2 to zero.
#   The variable list should be consistent with the qceff_table.csv in use for the filter.
#
# Motivation:
#   The Python-based approach using .to_netcdf() can cause compatibility issues
#   with DART when reading the updated NetCDF files. This shell script uses NCO
#   tools for robust in-place editing and is suitable for batch processing.
#
# Usage:
#   ./clip_hydro_per_member.csh /path/to/dir 'filename.nc'
#
# Example:
#   ./clip_hydro_per_member.csh $RUN_DIR/member1 'init.nc'
#
# Arguments:
#   $1 - Directory containing the NetCDF file(s)
#   $2 - Filename or pattern to match NetCDF files (e.g., 'init.nc')
#
# Written by Soyoung Ha (Nov 2024)
# ------------------------------------------------------------------------------


# Check for required arguments
if ( $#argv < 2 ) then
    echo "Usage: $0 <directory> <filename_pattern>"
    exit 1
endif


# Input directory and file pattern
set drun = $1
set f_in = $2


# Find matching files in the specified directory
set FILES = (`/bin/sh -c "cd $drun && ls $f_in"`)
if ( $#FILES == 0 ) then
    echo "No files matched pattern '$f_in' under $drun"
    exit 0
endif


# List of hydrometeor variables to check and clip
# (EPS_QV could be set as a floor for qv, but is currently unused)
set HYDROS = ( qv qc qr qi qs qg qh q2 )


# Check for required NCO tools
which ncap2 >/dev/null || (echo "ncap2 not found; install NCO"; exit 2)
which ncks  >/dev/null || (echo "ncks not found; install NCO";  exit 2)


# Full path to the target file
set f = "$drun/$f_in"
set expr = ""
echo "Processing: $f"


# Loop over each hydrometeor variable and build an ncap2 expression to set negatives to zero
foreach v ( $HYDROS )
    # Check if variable exists in the file (suppress output)
    /bin/sh -c "ncks -C -m -v $v '$f' > /dev/null 2>&1"
    # If variable exists, append to ncap2 expression
    if ( $status == 0 ) then
         set expr = "$expr where($v<0.0) $v=0.0;"
    endif
end


# If any variables needed clipping, run ncap2 and replace the file atomically
if ( "$expr" != "" ) then
    set ftmp = "${f}.tmp_clip"
    # Run ncap2 with the constructed expression
    # -O: Overwrite output, -h: skip metadata copy for speed
    ncap2 -O -h -s "$expr" "$f" "$ftmp"
    # Check for ncap2 success
    if ( $status != 0 ) then
        echo "ncap2 FAILED on $f"
        /bin/rm -f "$ftmp"
        exit 3
    endif
    # Replace original file with the clipped version
    /bin/mv -f "$ftmp" "$f"
    ls -l "$f"
    echo "  -> clipped and updated in place"
else
    echo "  (no target variables found; skipped)"
endif
