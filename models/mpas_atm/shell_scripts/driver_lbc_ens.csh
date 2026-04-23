#!/bin/tcsh
# Get ensemble LBCs ready for cycling.
# For a retrospective study, assuming that they were created beforehand, we only link to them here.
# To run init_atmosphere with config_init_case = 9, first run WPS/ungrib.exe over original grib data.
# That is not supported here (yet).
#
# Time format conventions:
#   - Loop/comparison/subdir keys use a 12-digit YYYYMMDDHHMM string,
#   - LBC filenames follow the MPAS ISO form: lbc.YYYY-MM-DD_HH.MM.SS.nc
#
# Written by Soyoung Ha (MMM/NCAR) Nov-2025

if ( $#argv >= 1 ) then
   set fn_param = ${1}
else
   set fn_param = `pwd`/setup.csh
endif
source ${fn_param}

# Derive 12-digit YYYYMMDDHHMM timestamps (works for both hourly and sub-hourly)
set time_beg = `echo $DATE_BEG 0 -w | $EXE_DIR/advance_time | sed 's/[^0-9]//g' | cut -c1-12`
set time_end = `echo $DATE_END 0 -w | $EXE_DIR/advance_time | sed 's/[^0-9]//g' | cut -c1-12`
set intv_min = `expr ${INTV_SEC} \/ 60`
set intv_hr  = `expr ${INTV_SEC} \/ 3600`

cd $RUN_DIR	|| exit		# Assume init ensemble were already created.
ls -l  input.nml streams.atmosphere	|| exit

echo
echo "driver_lbc_ens.csh to link ensemble LBCs from ${time_beg} to ${time_end} every ${intv_min} min \n in $RUN_DIR"
echo

# Check the file names for the MPAS model and the file lists for DART/filter.
set   fbdy = `sed -n '/<immutable_stream name=\"lbc_in\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere | \
    grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`

set  blist = `grep update_boundary_file_list input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
if( -e $blist) \rm -f $blist
touch $blist

echo "Coping (prior) LBC files into each member directory..."

set tcyc = $time_beg
while ( $tcyc <= $time_end )

  echo $tcyc

  # ISO form for the LBC filename (e.g. lbc.2017-04-27_00.00.00.nc)
  set tcyc_iso = `echo $tcyc 0 -w | $EXE_DIR/advance_time | sed -e 's/:/\./g'`
  set lbc0 = ${fbdy}${tcyc_iso}.nc

  set nens0 = `ls -1 ${LBC_DIR}/${tcyc}/${ENS_DIR}*/${lbc0} | wc -l`

  if ( ${nens0} < $ENS_SIZE ) then
	  echo Only ${nens0} ensemble LBCs to link to. Stop.
	  exit
  endif

  set n = 1
  while ( $n <= $ENS_SIZE )

     if (! -d ${ENS_DIR}${n}) mkdir ${ENS_DIR}${n}
     cd ${ENS_DIR}${n}
     #set num = `printf "%02d" $n` # two-digit integer like 01, 02, 03, ...
     #ls -l   ${LBC_DIR}/${tcyc}/${ENS_DIR}${num}/${lbc0} 	|| exit
     if ( ! -e ${lbc0} ) then
     ${COPY} ${LBC_DIR}/${tcyc}/${ENS_DIR}${n}/${lbc0} .	|| exit
     endif

     cd ../
     ls -l ${ENS_DIR}${n}/${lbc0}
     if ( $tcyc == $time_beg ) echo ${ENS_DIR}${n}/${lbc0} >> $blist

     @ n++
  end # while ( $n <= $ENS_SIZE )

  # Advance to the next cycle, keeping the 12-digit form
  set tnxt = `echo $tcyc +${INTV_SEC}s -w | $EXE_DIR/advance_time | sed 's/[^0-9]//g' | cut -c1-12`

  set tcyc = $tnxt

end # while ( $tcyc <= $time_end )
