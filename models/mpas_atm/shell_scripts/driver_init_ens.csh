#!/bin/tcsh
#
# driver_init_ens.csh
#
# Create an initial ensemble.
# This script is called by driver_mpas_dart.csh for the initial cycle.
#
# time_ini is stored as 12-digit YYYYMMDDHHMM for consistency with the
# driver script, using advance_time -w (ISO format).
# 
# Soyoung Ha (MMM/NCAR)
#
#set echo

if ( $#argv >= 1 ) then
   set fn_param = ${1}
else
   set fn_param = `pwd`/setup.csh
endif
source ${fn_param}

# Check if this cycling experiment is run in restart or non-restart mode.
if ( $USE_RESTART == true ) then
	echo "$EXPERIMENT_NAME is cycled in restart mode."
else
	echo "$EXPERIMENT_NAME is cycled in non-restart mode."
	#non-restart mode with two input files (invariant.nc and init.TIME.nc) and da_stream as output."
	# Since MPAS V8.3+, invariant.nc is no longer needed.
endif

# Derive 12-digit YYYYMMDDHHMM timestamp (works for both hourly and sub-hourly)
set time_wrf = `echo $DATE_INI 0 -w | $EXE_DIR/advance_time`	# YYYY-MM-DD_HH:MM:SS
set time_ini = `echo $DATE_INI 0 -w | $EXE_DIR/advance_time | sed 's/[^0-9]//g' | cut -c1-12`

echo '#################################################'
echo  driver_init_ens.csh at ${time_ini} in $RUN_DIR
echo '#################################################'

if (! -e $RUN_DIR) mkdir -p $RUN_DIR
cd $RUN_DIR

# Prepare necessary input files, first.
foreach f ( input.nml streams.atmosphere )

  ls -l $f
  if ( ! $status == 0 ) then
     echo ABORT\: $f not found. You may want to run driver_mpas_dart.csh, first.
     exit
  endif
end

# Check the file names for the MPAS model and the file lists for DART/filter.
set fini = `sed -n '/<immutable_stream name=\"input\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere | \
            grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g' | cut -d . -f1`
set f_nc = ${fini}.`echo ${time_wrf} | sed -e 's/:/\./g'`.nc

set  input_list = `grep input_state_file_list  input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`

#if ( -e ${finput} ) ${REMOVE} ${finput}
echo "Creating ${input_list} for a list of input files"
touch ${input_list}

# If an initial ensemble already exists, simply link to it.
echo "Check $INIT_DIR/${ENS_DIR}*/${F_INIT}" first.
if ( -e $INIT_DIR/${ENS_DIR}1 ) then

  set  nens = `ls -1 $INIT_DIR/${ENS_DIR}*/${F_INIT} | wc -l`	

  if ( $nens >= $ENS_SIZE ) then

     echo "An initial ensemble is found."
     echo "Copy them in each member directory (to be overwritten by DA)."

     set n = 1
     while ( $n <= $ENS_SIZE )

       set finput = ${ENS_DIR}${n}/$f_nc

       if ( ! -d ${ENS_DIR}${n} ) mkdir ${ENS_DIR}${n}

       #set num = `printf "%02d" $n` # two-digit integer like 01, 02, 03, ...

       ls -l ${INIT_DIR}/${ENS_DIR}${n}/${F_INIT}		        || exit
       ${COPY} ${INIT_DIR}/${ENS_DIR}${n}/${F_INIT} ${finput}	|| exit

       echo ${finput} >> ${input_list}
  
       @ n++

     end

     ls -l ${input_list}	|| exit
     echo

  else

     echo Only ${nens} initial ensemble files are found. Stop.
     exit

  endif #( $nens >= $ENS_SIZE )

else

   echo "An initial ensemble should be generated from scratch."
   echo "Run init_mpas_grib.csh using WPS and MPAS/init_atmosphere."

   # If $GRIB_DATA supports ensemble data, loop over the members (instead of 1) below.
   echo "Run init_mpas_grib.csh 1 ${fn_param}"
   ${CSH_DIR}/init_mpas_grib.csh 1 ${fn_param}	

endif
echo "driver_init_ens.csh is done."
echo
