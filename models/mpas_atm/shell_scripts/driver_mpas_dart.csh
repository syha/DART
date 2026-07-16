#!/bin/tcsh
#
# DART software - Copyright UCAR. This open source software is provided
# by UCAR, "as is", without charge, subject to all terms of use at
# http://www.image.ucar.edu/DAReS/DART/DART_download
#
##############################################################################################
#  driver_mpas_dart.csh
#
#  THIS IS A TOP-LEVEL DRIVER SCRIPT FOR CYCLING RUNS.
#  BOTH THE ENSEMBLE KALMAN FILTER AND THE MPAS FORECAST ARE RUN IN MPI.
#
#  This is a sample script for cycling runs in a retrospective case study,
#  and was tested on the NCAR HPC "Derecho" using a "qsub" command.
#
#  BEFORE RUNNING THIS SCRIPT, EDIT these files:
#  1. setup.csh for the general configuration including all the parameters.
#  2. ${DATA_DIR}/${FILTER_NML} for the filter configuration, which will be your input.nml. 
#  3. ${DATA_DIR}/${STREAM_ATM} for the model I/O stream, which will be your streams.atmosphere.
#  4. ${DATA_DIR}/${NML_MPAS}   for the model configuration, which will be your namelist.atmosphere.
#
#  Note:
#  1. Our general policy is that we only edit the parameters that affect the I/O changes here.
#     One exception is the time info, which will be updated inside advance_model.csh for each cycle.
#     All the rest remain unchanged for the model and the filter configurations.
#     This means that it is the user's responsibility to edit all other namelist parameters
#     and streams.atmosphere (that defines input and output file names and frequency)
#     before running this script. 
#  2. This script does NOT specify all the options available for the EnKF data assimilation either.
#     For your own complete filter design, you need to edit your ${DATA_DIR}/${FILTER_NML} 
#     - at least &filter_nml, &obs_kind_nml, &model_nml, &location_nml and &mpas_vars_nml sections
#     to set up your filter configuration before running this script.
#  3. For adaptive inflation, we only support the choice of prior adaptive inflation in the state
#     space here. For more options, check 
#     https://docs.dart.ucar.edu/en/latest/assimilation_code/modules/assimilation/filter_mod.html
#  4. All the logical parameters used here are CASE-SENSITIVE. They should be either true or false.
#  5. Warning!!! All the output files will be locally stored in $RUN_DIR.
#     For a large ensemble run, check if you have enough disk space before running this script.
#
#  Required scripts to run this driver:
#  (All template files are available in either shell_scripts or data under DART/models/mpas_atm/.)
#  1. setup.csh                  (for the general configuration of this experiment)
#  2. namelist.atmosphere        (for mpas)   - a namelist template for mpas.
#  3. streams.atmosphere         (for mpas)   - an I/O filename template for mpas.
#  4. input.nml                  (for filter) - a namelist template for filter.
#  5. filter.template.pbs        (for an mpi filter run; with async >= 2)
#  6. advance_model.template.pbs (for an mpi mpas run; using separate nodes for each ensemble member)
#  7. advance_model.template.csh (for mpas/filter) - a driver script to run mpas forecast at each cycle
#
#  Input files to run this script:
#  A. input_state_file_list  - a list of input ensemble netcdf files for DART/filter
#  B. output_state_file_list - a list of output ensemble netcdf files from DART/filter
#  C. RUN_DIR/member#/${mpas_filename}          - the input file for each member
#  D. OBS_DIR/obs_seq.out.${YYYYMMDDHHMM}       - obs sequence files for each analysis cycle
#     For sub-hourly cycling (e.g. 15-min), file names use 12-digit YYYYMMDDHHMM.
#     For hourly cycling, 10-digit YYYYMMDDHH is also accepted (minutes default to 00).
#  For the file/directory structure, read README and readme.rst in DART/models/mpas_atm/ and
#  then check several README files in DART/models/mpas_atm/shell_scripts/.
#
#  Time stamp convention used in this script:
#    time_anl is always stored as a 12-digit string YYYYMMDDHHMM.
#    This is derived from advance_time using the -w (ISO) flag, which always
#    returns YYYY-MM-DD_HH:MM:SS regardless of whether the interval is hourly
#    or sub-hourly, avoiding the 10-vs-12 digit ambiguity in advance_time output.
#
#  Written by Soyoung Ha (MMM/NCAR)
#
#  Updated for MPAS V5 and DART/Manhattan; tested on cheyenne (Jun-27-2017)
#  Updated for a better streamline and consistency: Ryan Torn (Jul-6-2017)
#  Updated for MPASV7: Soyoung Ha (Mar-4-2020)
#  Updated for a limited-area version of MPASV8+: Soyoung Ha (Oct-25-2025)
#  Updated for QCEFF/BNRHF adding a python script to clamp hydrometeors: Soyoung Ha (Nov-11-2025)
#  Updated for unified time handling for hourly and sub-hourly cycling: Soyoung Ha (Apr-8-2026)
#
#  For any questions or comments, contact: syha@ucar.edu (+1-303-497-2601)
##############################################################################################
set echo

set fn_param = `pwd`/setup.csh

if (! -e $fn_param ) then
   echo $fn_param does not exist. Cannot proceed.
   exit
endif
source $fn_param

echo '===================================================='
echo  Experiment name: $EXPERIMENT_NAME at `hostname`
echo '===================================================='

if( ! -e $RUN_DIR ) mkdir -p $RUN_DIR
cd $RUN_DIR

echo Running $0 in $RUN_DIR
echo
if ( ! -d logs ) mkdir logs

#------------------------------------------
# Prepare all the necessary files.
#------------------------------------------
if ( ! -d MPAS_RUN ) then
   if ( ! -d $MPAS_DIR ) then
      echo $MPAS_DIR does not exist. Stop.
      exit
   endif
   ${LINK} $MPAS_DIR MPAS_RUN				|| exit
endif

@ ndecomp = $MODEL_NODES * $N_PROCS_MPAS

set f_graph = ${F_GRAPH}.${ndecomp}
set fgraph = `basename $f_graph`
if ( ! -e ${fgraph} ) then
       ${LINK} ${GRID_DIR}/${f_graph} ${fgraph}		|| exit
       if(! -e ${fgraph}) then
          echo "Cannot find ${fgraph} for n_mpas * n_proc (= $MODEL_NODES * $N_PROCS_MPAS)"
          exit
       endif
endif
set FILELIST = ( $fgraph )

if ( ! -e ${F_TEMPLATE} ) then

set flist = ( filter advance_time update_mpas_states )
foreach fn ( $flist )
   echo ${LINK} ${EXE_DIR}/${fn} .
        ${LINK} ${EXE_DIR}/${fn} .
   if ( ! $status == 0 ) then
      echo ABORT\: We cannot find required executable dependency $fn.
      exit
   endif
end
set FILELIST = ( $FILELIST $flist )

set flist = ( filter.template.pbs advance_model.template.pbs advance_model.template.csh )
foreach fn ( $flist )
   if ( ! -r $fn || -z $fn ) then
      echo ${LINK} ${CSH_DIR}/${fn} .
           ${LINK} ${CSH_DIR}/${fn} .
      if ( ! $status == 0 ) then
         echo ABORT\: We cannot find required script $fn.
         exit
      endif
   endif
end

# Update the template file to advance_model.csh.
# VARLIST is defined in setup.csh.
#------------------------------------------
${COPY} ${CSH_DIR}/advance_model.template.csh adv.csh			|| exit
sed -e "s/VARLIST/${VARLIST}/g" adv.csh >! advance_model.csh		|| exit
chmod +x ./advance_model.csh
${REMOVE} adv.csh

set FILELIST = ( $FILELIST $flist advance_model.csh )

# === Added for Regional cycling ===
if ( ${USE_REGIONAL} == true ) then
      foreach fn ( update_bc )
         if ( ! -x $fn ) then
            echo ${LINK} ${EXE_DIR}/${fn} .
                 ${LINK} ${EXE_DIR}/${fn} .
            if ( ! $status == 0 ) then
               echo ABORT\: We cannot find required executable dependency $fn.
               exit
            endif
         endif
      end
      set FILELIST = ( $FILELIST $fn )

      foreach fn ( driver_lbc_ens.csh driver_init_ens.csh )
         if ( ! -r $fn ) then
            echo ${LINK} ${CSH_DIR}/${fn} .
                 ${LINK} ${CSH_DIR}/${fn} .
            if ( ! $status == 0 ) then
               echo ABORT\: We cannot find required script $fn.
               exit
            endif
         endif
      end
      set FILELIST = ( $FILELIST $fn )
endif
# === End for Regional cycling ===

# === From MPAS V8+, cycling supports both restart and non-restart modes.
# Restart mode uses full restart files for both input and output at each cycle, 
# Non-restart mode uses the da_state stream, reducing I/O overhead at the cost of reproducibility.
# Set USE_RESTART in setup.csh.
foreach fn ( ${STREAM_ATM} )
      if ( ! -r ${fn} || -z $fn ) then
         if ( $USE_RESTART == true ) then
             ${COPY} ${DATA_DIR}/${fn} .
         endif
      endif
      if ( ! $status == 0 ) then
         echo ABORT\: We cannot find required file $fn.
         exit
      endif
end
set FILELIST = ( $FILELIST $fn )
echo

# === Added for QCEFF ===
# We assume ${NML_DART} (e.g., input.nml) already has qceff_table_filename defined.
# If not, set ftbl = "" in setup.csh or leave it undefined and the block is skipped.
set fn = ${DATA_DIR}/${FILTER_NML}
set ftbl = `grep qceff_table_filename ${fn} | head -1 | awk '{print $3}' | sed -e "s/'//g"`

if ( $ftbl != "" ) then
      echo "We need $ftbl for Non-Gaussian analyses."
      ${COPY} ${DATA_DIR}/${ftbl} .	|| exit

      # Load conda environment for check_negative_ensemble.py
      # Comment out or adjust if conda is not used on your system.
      if ( $?USE_CONDA && $USE_CONDA == true ) then
         module load conda
         conda activate npl
      endif

      # === Check dependencies for QCEFF hydrometeor clipping ===
      # Check if the clipping script is available.
      set fn = ${CSH_DIR}/clip_hydro_per_member.csh
      if ( ! -r ${fn} ) then
         if ( ! $status == 0 ) then
            echo ABORT\: We cannot find required script $fn.
            exit
         endif
      endif
      chmod +x $fn
      set FILELIST = ( $FILELIST $fn )

      # Check if NCO commands required by clip_hydro_per_member.csh are available.
      foreach nco_cmd ( ncap2 ncks )
         which $nco_cmd > /dev/null
         if ( $status != 0 ) then
            echo "ABORT: NCO command '$nco_cmd' not found in PATH."
            echo "       Load the NCO module before running this script."
            exit
         endif
      end

      # Check that python and check_negative_ensemble.py are available
      which python > /dev/null
      if ( $status != 0 ) then
         echo "ABORT: python not found. Load conda environment before running."
         exit
      endif
      if ( ! -r ${CSH_DIR}/check_negative_ensemble.py ) then
         echo "ABORT: Cannot find ${CSH_DIR}/check_negative_ensemble.py"
         exit
      endif

endif #if ( $ftbl != "" ) then

set FILELIST = ( $FILELIST ${ftbl} )
echo
# === End for QCEFF ===

# === Coefficient files needed. Add more in setup.csh, if needed.
set flist = ( ${SAMPLING_ERR_TBL} )
if ( ${USE_RTTOV} == true ) set flist = ( $flist ${RTTOV_FILES} )
foreach f ( $flist )
   set fn = `basename $f`
   if ( ! -r ${fn} || -z $fn ) then
            ${LINK} ${f} .			|| exit
   endif
end
set FILELIST = ( $FILELIST $flist )

#--------------------------------------------------------------------------
# Edit namelist.atmosphere
#--------------------------------------------------------------------------
cat >! nml.sed << EOF
   /config_dt /c\
    config_dt = ${DT_MPAS}
   /config_len_disp /c\
    config_len_disp = ${LEN_DISP}
   /config_block_decomp_file_prefix /c\
    config_block_decomp_file_prefix = '${F_GRAPH}.'
   /config_sst_update /c\
    config_sst_update = ${SST_UPDATE}
EOF

if ( ${USE_REGIONAL} == true ) then
cat >! nml2.sed << EOF
   /config_apply_lbcs /c\
    config_apply_lbcs = true
EOF
cat nml2.sed >> nml.sed
endif
sed -f nml.sed ${DATA_DIR}/${NML_MPAS} > ${NML_MPAS}	|| exit
ls -l ${NML_MPAS}					|| exit
set FILELIST = ( $FILELIST ${NML_MPAS} )

if ( $SST_UPDATE == true ) then
  set fsst = `sed -n '/<stream name=\"surface\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_ATM} | \
              grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
  ${LINK} ${SST_DIR}/${SST_FNAME} $fsst         || exit
else
  echo NO SST_UPDATE...
endif

#--------------------------------------------------------------------------
# Edit input.nml
#--------------------------------------------------------------------------
  cat >! dart.sed << EOF
  /ens_size /c\
   ens_size                 = ${ENS_SIZE}
  /num_output_obs_members /c\
   num_output_obs_members   = ${num_output_obs_members}
  /num_output_state_members/c\
   num_output_state_members = ${num_output_state_members}
  /assimilation_period_days /c\
   assimilation_period_days     = ${INTV_DAY}
  /assimilation_period_seconds /c\
   assimilation_period_seconds  = ${INTV_SEC}
  /cutoff /c\
   cutoff                       = ${CUTOFF}
  /vert_localization_coord  /c\
   vert_localization_coord      = ${VLOC_COORD}
  /vert_normalization_height /c\
   vert_normalization_height   = ${VLOC}
  /distribute_mean /c\
   distribute_mean              = .${DISTRIB_MEAN}.
  /convert_all_obs_verticals_first /c\
   convert_all_obs_verticals_first   = .${CONVERT_OBS}.
  /convert_all_state_verticals_first /c\
   convert_all_state_verticals_first = .${CONVERT_STAT}.
  /write_binary_obs_sequence /c\
   write_binary_obs_sequence = .${binary_obs_seq}.
  /tasks_per_node /c\
   tasks_per_node = ${N_PROCS_ANAL}
  /mpas_lbc_variables = /c\
   mpas_lbc_variables = ${LBCLIST}
EOF

sed -f dart.sed ${DATA_DIR}/${FILTER_NML} > ${NML_DART}
ls -l ${NML_DART}					|| exit
set FILELIST = ( $FILELIST ${NML_DART} )

#--------------------------------------------------------------------------
#  Take file names from input.nml
#--------------------------------------------------------------------------
set  input_list = `grep input_state_file_list  ${NML_DART} | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
set output_list = `grep output_state_file_list ${NML_DART} | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
set  obs_seq_in = `grep obs_sequence_in_name   ${NML_DART} | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
set obs_seq_out = `grep obs_sequence_out_name  ${NML_DART} | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`

# init.nc: an MPAS template for mesh info.
set fmesh = `grep init_template_filename ${NML_DART} | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`

if ( ! -e $fmesh ) ${LINK} ${F_TEMPLATE} $fmesh    || exit
set FILELIST = ( $FILELIST ${fmesh} )

#--------------------------------------------------------
# Take MPAS file names from streams.atmosphere.
#--------------------------------------------------------
set fini = `sed -n '/<immutable_stream name=\"input\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_ATM} | \
            grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`
set frst = `sed -n '/<immutable_stream name=\"restart\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_ATM} | \
            grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`

if ($fini != $fmesh) then
   echo $fmesh in ${NML_DART} should be the same as $fini in ${STREAM_ATM}. Stop.
   exit
endif

if ( ${USE_RESTART} == false ) then
 set frst = `sed -n '/<immutable_stream name=\"da_state\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_ATM} | \
             grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
endif

set fbdy = `sed -n '/<immutable_stream name=\"lbc_in\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_ATM} | \
    grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`

#------------------------------------------
# Initial ensemble for $DATE_INI
#------------------------------------------
if( $DATE_BEG == $DATE_INI ) then
    set nens =  0
    if( -e ${input_list} ) then
       set fens = `cat ${input_list}`
       set nens = `ls -1L $fens | wc -l`
    endif
    if( ! -e ${input_list} || $nens != ${ENS_SIZE} ) then
            ${CSH_DIR}/driver_init_ens.csh ${fn_param}
    endif
    if ( ${USE_REGIONAL} == true ) then
       set  blist = `grep update_boundary_file_list input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
       set  nlist = `cat $blist | wc -l`
       if( ! -e $blist || $nlist != $ENS_SIZE) then
       echo Running driver_lbc_ens.csh to copy ensemble LBC files...
       ${CSH_DIR}/driver_lbc_ens.csh ${fn_param}
       endif
       set  nlist = `cat $blist | wc -l`
       if( $nlist != $ENS_SIZE) then
           echo Not enough LBC files to start with. Stop.
           exit
       endif
    endif
endif

#--------------------------------------------------------------------------
# Time info
#
# DESIGN NOTE: advance_time returns YYYYMMDDHH (10 digits) for on-hour times
# and YYYYMMDDHHMM (12 digits) for sub-hourly times, making output length
# unpredictable for mixed-interval cycling.
#
# Solution: use "advance_time -w" which always returns ISO format
# YYYY-MM-DD_HH:MM:SS, then strip non-digits and take 12 characters to get
# a canonical YYYYMMDDHHMM timestamp that works for both hourly and 15-min
# cycling without any special-casing.
#--------------------------------------------------------------------------
set intv_min = `expr ${INTV_SEC} \/ 60`
set intv_hr  = `expr ${INTV_SEC} \/ 3600`

# Helper alias: convert any advance_time date argument to 12-digit YYYYMMDDHHMM.
# Usage: set t = `iso2tag $DATE_BEG 0`
#        set t = `iso2tag $time_anl +900s`
# (passes all arguments to advance_time -w, strips non-digits, takes 12 chars)
alias iso2tag 'echo \!* -w | ./advance_time | sed "s/[^0-9]//g" | cut -c1-12'

set time_ini = `iso2tag $DATE_INI 0`
set time_anl = `iso2tag $DATE_BEG 0`
set time_end = `iso2tag $DATE_END 0`

# Compute number of cycles using Gregorian arithmetic (independent of format)
set greg_beg = `echo $DATE_BEG 0 -g | ./advance_time`
set greg_end = `echo $DATE_END 0 -g | ./advance_time`
set diff_day = `expr $greg_end[1] \- $greg_beg[1]`
set diff_sec = `expr $greg_end[2] \- $greg_beg[2]`
set diff_tot = `expr $diff_day \* 86400 \+ $diff_sec`
set n_cycles = `expr $diff_tot \/ ${INTV_SEC} \+ 1`
if($n_cycles < 0) then
   echo Cannot figure out how many cycles to run. Check the time setup.
   exit
endif

set icyc = 1
if( $DATE_BEG != $DATE_INI ) then
   set greg_ini = `echo $DATE_INI 0 -g | ./advance_time`
   set init_day = `expr $greg_beg[1] \- $greg_ini[1]`
   set init_sec = `expr $greg_beg[2] \- $greg_ini[2]`
   set init_dif = `expr $init_day \* 86400 \+ $init_sec`
   set icyc = `expr $init_dif \/ $INTV_SEC \+ 1`
endif
echo

echo "Total of ${n_cycles} cycles from ${time_anl} to ${time_end} every ${intv_min} min."

#--------------------------------------------------------
# Cycling gets started
# All time variables (time_anl, time_pre, time_nxt) are
# always 12-digit YYYYMMDDHHMM via the iso2tag alias.
#--------------------------------------------------------
while ( $time_anl <= $time_end )

  set time_pre = `iso2tag $time_anl -${INTV_SEC}s`
  set time_nxt = `iso2tag $time_anl +${INTV_SEC}s`

  set anal_utc = `echo $time_anl 0 -w | ./advance_time`
  set greg_obs = `echo $time_anl 0 -g | ./advance_time`
  set greg_obs_days = $greg_obs[1]
  set greg_obs_secs = $greg_obs[2]

  set sav_dir = ${RUN_DIR}/${time_anl}
  if( ! -d ${sav_dir} ) mkdir -p ${sav_dir}

  echo
  echo "icyc = ${icyc} at ${time_anl}: ${greg_obs_days}_${greg_obs_secs} in $sav_dir"
  echo

  #------------------------------------------------------
  # 1. Namelist setup
  #------------------------------------------------------
  if($icyc == 1) then
     set cycling    = false
     set do_restart = false
  else
     set cycling    = true
     set do_restart = ${USE_RESTART}
  endif
  if ( ${USE_RESTART} == true ) then
     set jedi_io    = false
  else
     set jedi_io    = true
  endif

  if ( -e init.sed ) ${REMOVE} init.sed script*.sed

  cat >! init.sed << EOF3
   /config_do_DAcycling /c\
    config_do_DAcycling = ${cycling}
   /config_do_restart /c\
    config_do_restart = ${do_restart}
   /config_jedi_da    /c\
    config_jedi_da = ${jedi_io}
EOF3
  mv ${NML_MPAS} namelist.temp
  sed -f init.sed namelist.temp >! ${NML_MPAS}
  ${REMOVE} init.sed namelist.temp

  if ( $ADAPTIVE_INF == true ) then       # For a spatially-varying prior inflation.

    if ($icyc == 1) then
       cat >! script.sed << EOF
       /inf_initial_from_restart/c\
       inf_initial_from_restart    = .false.,                .false.,
       /inf_sd_initial_from_restart/c\
       inf_sd_initial_from_restart = .false.,                .false.,
EOF
    else
       cat >! script.sed << EOF
       /inf_initial_from_restart/c\
       inf_initial_from_restart    = .true.,                .true.,
       /inf_sd_initial_from_restart/c\
       inf_sd_initial_from_restart = .true.,                .true.,
EOF
    endif

  endif

  ${MOVE} ${NML_DART} ${NML_DART}.temp
  sed -f script.sed ${NML_DART}.temp >! ${NML_DART}             || exit 2
  ${REMOVE} script.sed ${NML_DART}.temp

  #------------------------------------------------------
  # 2. Update the input file list to get filter started
  #------------------------------------------------------
  set f_rst =   ${frst}`echo ${anal_utc} | sed -e 's/:/\./g'`.nc
  set f_anl = analysis.`echo ${anal_utc} | sed -e 's/:/\./g'`.nc
  set f_out =   ${frst}`echo ${anal_utc} | sed -e 's/:/\./g'`.nc  # same as f_rst after analysis
  set f_prior = prior.`echo ${anal_utc} | sed -e 's/:/\./g'`.nc
  set f_diag  = diag.`echo ${anal_utc}  | sed -e 's/:/\./g'`.nc
  set f_pdiag = pdiag.`echo ${anal_utc} | sed -e 's/:/\./g'`.nc

  echo "Input ensemble for ${time_anl}"
  if( -e ${input_list})  ${REMOVE} ${input_list}
  if( -e ${output_list}) ${REMOVE} ${output_list}
  echo "Creating ${input_list} and ${output_list}"

  set finput = ${f_rst}
  set i = 1
  while ( $i <= ${ENS_SIZE} )
    if ( $icyc == 1 && ! -d ${ENS_DIR}${i} ) ${LINK} ../${ENS_DIR}${i} .

    # Back up prior and clean stale analysis files before writing new list
    if( -e ${ENS_DIR}${i}/${f_out} ) then
       ${COPY} ${ENS_DIR}${i}/${f_out} ${ENS_DIR}${i}/${f_prior} &
       ${COPY} ${ENS_DIR}${i}/${f_out} ${ENS_DIR}${i}/${f_rst}   &
    endif
    if ( -e ${ENS_DIR}${i}/${f_diag} ) then
       ${MOVE} ${ENS_DIR}${i}/${f_diag} ${ENS_DIR}${i}/${f_pdiag} &
    endif

    @ r = $i / 10
    if ( $r == 0 ) wait
    @ i++
  end
  wait

  set i = 1
  while ( $i <= ${ENS_SIZE} )
    if ( $icyc == 1 ) set finput = ${fini}
    if (! -e ${ENS_DIR}${i}/${finput}) then
        echo "Cannot find ${ENS_DIR}${i}/${finput}. Stop."
        exit
    else
        if( -e ${ENS_DIR}${i}/${f_out}  ) ${REMOVE} ${ENS_DIR}${i}/${f_out}
        if( -e ${ENS_DIR}${i}/${f_diag} ) ${REMOVE} ${ENS_DIR}${i}/${f_diag}
        echo ${ENS_DIR}${i}/${finput} >> ${input_list}
    endif
    echo ${ENS_DIR}${i}/${f_anl} >> ${output_list}
    @ i++
  end

  set ne = `cat ${input_list} | wc -l `
  if ( $ne != $ENS_SIZE ) then
     echo "We need ${ENS_SIZE} initial ensemble members, but found ${ne} only."
     exit
  endif
  echo

  #------------------------------------------------------
  # Clip hydrometeors for QCEFF (if qceff_table is set)
  # Uses a PBS array job for efficiency (one job per member).
  #------------------------------------------------------
  if ( $ftbl != "" && ! -e ./clip_done ) then
       if ( -e check_negative.log ) ${REMOVE} check_negative.log
       python $CSH_DIR/check_negative_ensemble.py $RUN_DIR ${finput} > check_negative.log
       set nneg = `tail -1 check_negative.log | awk '{print $1}' | bc`

       if ( $nneg > 0 ) then
          echo "${nneg} negative values found. Clipping hydrometeors (array job)."
          set jobn = clip.`echo ${time_anl} | cut -c5-`

          cat >! clip.pbs << EOF
#!/bin/tcsh
#============================================
#PBS -N $jobn
#PBS -A ${PROJ_NUMBER}
#PBS -j oe
#PBS -q main
#PBS -l job_priority=premium
#PBS -l select=1:mpiprocs=1:ncpus=1
#PBS -l walltime=00:10:00
#PBS -J 1-${ENS_SIZE}%10
#============================================
source $MODFILE
set memid = \${PBS_ARRAY_INDEX}
ls -l $RUN_DIR/${ENS_DIR}\${memid}/${finput}
$CSH_DIR/clip_hydro_per_member.csh $RUN_DIR/${ENS_DIR}\${memid} "${finput}"
ls -l $RUN_DIR/${ENS_DIR}\${memid}/${finput}
EOF
          set jid = `qsub clip.pbs`
          sleep 60

          # Wait until the array job is finished.
          set is_there = 0
          while ( $is_there == 0 )
            sleep 30
            qstat -w $jid
            set is_there = $?
          end

          set i = 1
          while ( $i <= ${ENS_SIZE} )
            ls -l ${ENS_DIR}${i}/${finput}
            @ i++
          end
          ${MOVE} ${jobn}.o* ./logs
          touch clip_done

       endif	# if ( $nneg > 0 )
  endif	# if ( $ftbl != "" )

  if ( -e ./clip_done ) ${REMOVE} ./clip_done

  if ( $ADAPTIVE_INF == true && $icyc > 1 ) then
    if ( ! -e ${RUN_DIR}/${time_pre}/${INFL_OUT}_mean.nc ) then
      echo ${RUN_DIR}/${time_pre}/${INFL_OUT}_mean.nc does not exist. Stop.
      exit
    endif
    ${LINK} ${RUN_DIR}/${time_pre}/${INFL_OUT}_mean.nc ${INFL_IN}_mean.nc	|| exit
    ${LINK} ${RUN_DIR}/${time_pre}/${INFL_OUT}_sd.nc   ${INFL_IN}_sd.nc	|| exit
  endif

  #------------------------------------------------------
  # 3. Obs sequence for this analysis cycle
  #------------------------------------------------------
  set fn_obs = ${OBS_DIR}/obs_seq.out.${time_anl}
  if ( ! -e ${fn_obs} ) then
     echo ${fn_obs} does not exist. Stop.
     exit
  endif
  ${LINK} ${fn_obs} ${obs_seq_in}

  #------------------------------------------------------
  # 4. Run filter
  #------------------------------------------------------
  set jobn = ${EXPERIMENT_NAME}.`echo $time_anl | cut -c5-`	# MMDDHHmm

  if( ! -e filter_done && ! -e ${obs_seq_out} ) then

    if ( $RUN_IN_PBS == yes ) then
       echo Running filter: $jobn

       cat >! filter.sed << EOF
    s#JOB_NAME#${jobn}#g
    s#PROJ_NUMBER#${PROJ_NUMBER}#g
    s#NODES#${FILTER_NODES}#g
    s#NPROC#${N_PROCS_ANAL}#g
    s#NCPUS#${N_CPUS}#g
    s#JOB_TIME#${TIME_FILTER}#g
    s#QUEUE#${QUEUE_FILTER}#g
EOF

       sed -f filter.sed filter.template.pbs >! filter.pbs
       set jid = `qsub filter.pbs`
       sleep 60
       ${REMOVE} filter.sed

       # Wait until the filter job is finished.
       set is_there = 0
       while ( $is_there == 0 )
         sleep 30
         qstat -w $jid
         set is_there = $?
       end
       ${MOVE} ${jobn}.o* logs/.

    else

       echo `date +%s` >&! filter_started
       set flog = ${sav_dir}/${jobn}.log
       ./filter >! $flog

    endif       # if ( $RUN_IN_PBS == yes )

    if ( -e ${obs_seq_out})  touch filter_done

  endif # if( ! -e filter_done )

  # Check errors in filter.
  if ( -e filter_started && ! -e filter_done ) then
    echo "Filter was not normally finished. Exiting."
    ls -l filter_started
    date
    ${REMOVE} filter_started
    exit
  endif

  ${REMOVE} filter_started filter_done
  echo Filter is done for Cycle at ${time_anl}

  #------------------------------------------------------
  # 5. Target time for model advance
  #------------------------------------------------------
  set greg_obs = `echo $time_anl ${INTV_DAY}d${INTV_SEC}s -g | ./advance_time`
  set greg_obs_days = $greg_obs[1]
  set greg_obs_secs = $greg_obs[2]
  echo Target date: $time_nxt ${greg_obs_days}_${greg_obs_secs}
  ${COPY} input.nml ${time_anl}/input.nml.filter.${icyc}

  #------------------------------------------------------
  # 6. Run update_mpas_states for all ensemble members
  #------------------------------------------------------
  set fanal = `grep update_output_file_list input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
  set nanal = `cat $fanal | wc -l`

  set flog = logs/update_mpas_states.${time_anl}.cycle${icyc}.log
  if ( -e $flog ) ${REMOVE} $flog

  if ( ! -e $flog || -z $flog) then
  ${EXE_DIR}/update_mpas_states > $flog
  endif

  set i_err = `grep ERROR    $flog | wc -l`
  set idone = `grep Finished $flog | wc -l`
  if($nanal != $ENS_SIZE || ${i_err} > 0 || $idone == 0 ) then
     echo Error in $flog
     echo nanal = $nanal ensemble input files with i_err = ${i_err} and idone = $idone.
     exit
  endif
  echo

  #------------------------------------------------------
  # 7. Run update_bc for all ensemble members (regional MPAS)
  #------------------------------------------------------
  if ( ${USE_REGIONAL} == true ) then

       set anllist = `grep update_analysis_file_list input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
         if($anllist != $fanal) then
            echo $anllist should be the same as $fanal for update_bc. Exit.
            exit
         endif
       set bdylist = `grep update_boundary_file_list input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
       if( -e $bdylist) ${REMOVE} $bdylist
       if( -e  bdynext) ${REMOVE}  bdynext

       echo Creating $bdylist for update_bc now.
       touch $bdylist bdynext
       # lbc file names use ISO UTC format (YYYY-MM-DD_HH.MM.SS) from advance_time -w
       set lbc0 = ${fbdy}`echo ${time_anl} 0 -w | ./advance_time | sed -e 's/:/\./g'`.nc
       set lbcN = ${fbdy}`echo ${time_nxt} 0 -w | ./advance_time | sed -e 's/:/\./g'`.nc
       set g_fc = ${f_rst}	# analysis after update_mpas_states

       set n = 1
       while ( $n <= $ENS_SIZE )

	set num = `printf "%02d" $n`

        ls -lL ${ENS_DIR}${n}/${lbc0}                                    || exit
        echo ${ENS_DIR}${n}/${lbc0} >> $bdylist

        if( ! -e ${ENS_DIR}${n}/${lbcN} ) then
          ${COPY} ${LBC_DIR}/${time_anl}/${ENS_DIR}${num}/${lbcN} ${ENS_DIR}${n}/    || exit
        endif
        ls -1 ${ENS_DIR}${n}/${lbcN} >> bdynext

        @ n++
       end

  set  nbdy = `cat $bdylist | wc -l`
  set nbdyN = `cat bdynext | wc -l`
  if($nbdy != $ENS_SIZE || $nbdyN != $ENS_SIZE) then
     echo Not enough LBC files for the regional MPAS run: $nbdy and $nbdyN. Stop.
     exit
  endif

  ${EXE_DIR}/update_bc >!    logs/update_bc.${time_anl}.cycle${icyc}.log
  set i_err = `grep ERROR    logs/update_bc.${time_anl}.cycle${icyc}.log | wc -l`
  set idone = `grep Finished logs/update_bc.${time_anl}.cycle${icyc}.log | wc -l`
  if( ${i_err} > 0 || $idone == 0 ) then
     echo Error in logs/update_bc.${time_anl}.cycle${icyc}.log
     exit
  endif

  if( -z $bdylist ) then
      echo $bdylist is zero. Check update_bc. Exit.
      exit
  endif

  endif # if ( ${USE_REGIONAL} == true )

  #------------------------------------------------------
  # 8. Advance model for each member
  # Uses PBS array job (-J) when RUN_IN_PBS=yes for efficiency.
  # Each array element handles one ensemble member.
  #------------------------------------------------------
  echo Advance model for ${ENS_SIZE} members now...

  if( -e list.${time_nxt}.txt ) \rm -f list.${time_nxt}.txt

  if ( $RUN_IN_PBS == "yes" ) then  # Derecho: array job over members

     set jobname = ${EXPERIMENT_NAME}.`echo $time_anl | cut -c5-`  # MMDDHHmm
     set jobn    = `echo $jobname | cut -c1-8`                      # for qstat

     cat >! advance.sed << EOF
     s#JOB_NAME#${jobname}#g
     s#PROJ_NUMBER#${PROJ_NUMBER}#g
     s#ENS_SIZE#${ENS_SIZE}#g
     s#QUEUE#${QUEUE_MPAS}#g
     s#NODES#${MODEL_NODES}#g
     s#NPROC#${N_PROCS_MPAS}#g
     s#NCPUS#${N_CPUS}#g
     s#JOB_TIME#${TIME_MPAS}#g
EOF
     sed -f advance.sed advance_model.template.pbs >! advance_model.pbs
     set jid = `qsub advance_model.pbs`
     sleep 60
     ${REMOVE} advance.sed

  else  # serial: run members one at a time

     set n = 1
     while ( $n <= $ENS_SIZE )
       ./advance_model.csh $n $n >! logs/advance_model.${time_anl}.cycle${icyc}.e${n}.log
       @ n++
     end

  endif

  if ( $RUN_IN_PBS == yes ) then
    # Wait until all model advance jobs are finished.
    set is_there = 0
    while ( $is_there == 0 )
      sleep 30
      qstat -w $jid
      set is_there = $?
    end

    # Rename PBS job logs for readability
    set rename_jobid = `echo $jid | sed 's/\[.*//'`
    if ( -e logs/${jobname}.o${rename_jobid}.* ) then
       rename "o${rename_jobid}." "log.e" logs/${jobname}.o${rename_jobid}.*
    endif
    date
    sleep 30
  endif

  #------------------------------------------------------
  # 9. Store output files
  #------------------------------------------------------
  echo Saving output files for ${time_anl}.
  ls -lrt >! ${sav_dir}/list.txt
  set fstat = `grep stages_to_write input.nml | awk -F= '{print $2}'`
  set fs = `echo $fstat | sed -e 's/,/ /g' | sed -e "s/'//g"`

  foreach f ( $fs ${obs_seq_out} ${input_list} ${output_list} $bdylist bdynext )
    ${MOVE} ${f}* ${sav_dir}/
  end
  if ( -e check_negative.log       ) ${MOVE} check_negative.log       ${sav_dir}/
  if ( -e check_negative.final.log ) ${MOVE} check_negative.final.log ${sav_dir}/

  #------------------------------------------------------
  # 10. Get ready to run filter for next cycle.
  #------------------------------------------------------
  cd $RUN_DIR
  ls -lL list.${time_nxt}.txt           || exit
  set nout = `cat list.${time_nxt}.txt | wc -l`

  if ( $nout != ${ENS_SIZE} ) then
     echo This cycle has failed with only $nout members done. Check missing members.
     exit
  else
     echo Filter is ready to go for $nout members for the next cycle ${time_nxt}.
     set time_anl = $time_nxt
     @ icyc++
  endif

  echo
end
#
echo Cycling is done for $n_cycles cycles in ${EXPERIMENT_NAME}.
echo Script exiting normally.
#
exit 0
