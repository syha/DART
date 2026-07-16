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
set echo

if ( $#argv >= 1 ) then
   set fn_param = ${1}
else
   set fn_param = `pwd`/setup.csh
endif
source ${fn_param}

# Check if this cycling experiment is run in restart or non-restart mode.
if ( $USE_RESTART == true ) then
	echo $EXPERIMENT_NAME is cycled in restart mode.
else
	echo $EXPERIMENT_NAME is cycled in non-restart mode with two input files (invariant.nc and init.TIME.nc).
endif

# Derive 12-digit YYYYMMDDHHMM timestamp (works for both hourly and sub-hourly)
set time_ini = `echo $DATE_INI 0 -w | $EXE_DIR/advance_time | sed 's/[^0-9]//g' | cut -c1-12`

echo '#################################################'
echo  driver_init_ens.csh at ${time_ini} in $RUN_DIR
echo '#################################################'

if (! -e $RUN_DIR) mkdir -p $RUN_DIR
cd $RUN_DIR

# Prepare necessary input files, first.
foreach f ( input.nml streams.atmosphere )
  if (! -e $f ) cp -p ${RUN_DIR}/$f .
end
ls -l  input.nml streams.atmosphere
if ( ! $status == 0 ) then
     echo ABORT\: Run driver_mpas_dart.csh to have input.nml and streams.atmosphere ready for $0.
     exit
endif

# Check the file names for the MPAS model and the file lists for DART/filter.
set fini = `sed -n '/<immutable_stream name=\"input\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere | \
            grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`

set  input_list = `grep input_state_file_list  input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`

#if ( -e ${finput} ) ${REMOVE} ${finput}
echo "Creating ${input_list} for a list of input files"
touch ${input_list}

# If an initial ensemble already exists, simply link to it.
echo Check $INIT_DIR/${ENS_DIR}*/${INIT_FNAME} first.
set nens = `ls -1 $INIT_DIR/${ENS_DIR}*/${INIT_FNAME} | wc -l`	
if ( $nens >= $ENS_SIZE ) then

   echo "An initial ensemble is found."
   echo "Copy them in each member directory (to be overwritten by DA)."

   set n = 1
   while ( $n <= $ENS_SIZE )

     set finput = ${ENS_DIR}${n}/$fini

     if ( ! -d ${ENS_DIR}${n} ) mkdir ${ENS_DIR}${n}

     set num = `printf "%02d" $n` # two-digit integer like 01, 02, 03, ...

     ls -l ${INIT_DIR}/${ENS_DIR}${num}/${INIT_FNAME}		        || exit
     ${COPY} ${INIT_DIR}/${ENS_DIR}${num}/${INIT_FNAME} ${finput}	|| exit

     echo ${finput} >> ${input_list}

     @ n++

   end

else

   echo An initial ensemble should be generated from scratch. 
   echo Run init_mpas_grib.csh using WPS and MPAS/init_atmosphere.

   # If $GRIB_DATA supports ensemble data, loop over the members (instead of 1) below.
   ./init_mpas_grib.csh 1 ${fn_param}	

endif
