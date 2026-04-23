#!/bin/tcsh
########################################################################
#
#   init_mpas_grib.csh - shell script that can be used to create an
#                        initial MPAS ensemble from an external grib
#                        file, then allows the user to integrate the
#                        forecast forward in time, so the forecasts are
#                        available for the initial ensemble.
#
#   Note: A static.nc should exist before running this script.
#         We only run init_atmosphere to create init.nc from it.
#
#   Written by Soyoung Ha (Apr-2026)
#
########################################################################

  set ensemble_member = ${1}     # ensemble member index [1-N]
  set paramfile       = ${2}     # the parameter file with variables

  source $paramfile

  #=====================================================================================
  # User-defined parameters - Edit as you want.
  #=====================================================================================
  # output_interval for diagnostics in streams.atmosphere (HH:MM:SS)
  set intv_diag = 06:00:00	 # to check a time series of ensemble spread later.

  # Set nnode/nproc for the init forecast may differ from cycling runs.
  # Adjust these and ensure graph.info.$(nnode*nproc) exists in GRID_DIR.
  set nnode = 1		# $MODEL_NODES
  set nproc = 128	# $N_PROCS_MPAS
  #=====================================================================================
  # End User-defined parameters
  #=====================================================================================

  # MPAS mesh graph info
  @ ndecomp = $nnode * $nproc
  set f_graph = ${F_GRAPH}.${ndecomp}
  set fgraph = `basename $f_graph`

  # advance_time executable is needed to update time info below.
  if ( -x ${RUN_DIR}/advance_time ) then
     set ADV_TIME = ${RUN_DIR}/advance_time
  else
     set ADV_TIME = ${EXE_DIR}/advance_time
  endif

  # Output directory
  set temp_dir = ${INIT_DIR}/${ENS_DIR}${ensemble_member}

  if ( -d ${temp_dir} ) ${REMOVE} ${temp_dir}
  mkdir -p ${temp_dir}
  if ( ! -e ${RUN_DIR}/${ENS_DIR}${ensemble_member} ) then
     ${LINK} ${temp_dir} ${RUN_DIR}/${ENS_DIR}${ensemble_member}
  endif
  cd ${temp_dir}

  # Get these ready for time info.
  ${COPY} ${RUN_DIR}/input.nml  .   || exit 1
  ${LINK} ${ADV_TIME} advance_time  || exit 1

  #  Determine the initial, final and run times for the MPAS integration
  set fcst_hrs = `echo "$INIT_ENS_FCST_HRS / 1" | bc`   # integer truncation
  set init_utc = `echo $DATE_INI -${fcst_hrs}h -w | ./advance_time`
  set targ_utc = `echo $DATE_INI 0             -w | ./advance_time`

  # Parse date components from ISO init_utc (YYYY-MM-DD_HH:MM:SS)
  set YYYY = `echo $init_utc | cut -c1-4`
  set MM   = `echo $init_utc | cut -c6-7`
  set DD   = `echo $init_utc | cut -c9-10`
  set HH   = `echo $init_utc | cut -c12-13`
  set grib_utc = ${YYYY}${MM}${DD}${HH}
  set ugrb_utc = ${YYYY}-${MM}-${DD}_${HH}   # for ungrib output (FILE:YYYY-MM-DD_HH)
  set fgrib    = ${GRIB_DATA}:${ugrb_utc}

  # Model forecast hours
  set fdays    = `echo "$fcst_hrs / 24" | bc`
  set fhours   = `echo "$fcst_hrs % 24" | bc`
  set intv_utc = `printf "%02d_%02d:00:00" $fdays $fhours`

  if ( ! -e ${fgraph} ) then
       if ( -e ${GRID_DIR}/${f_graph} ) then
	       ${LINK} ${GRID_DIR}/${f_graph} ${fgraph}         || exit
       else
         if ( -e ${RUN_DIR}/${f_graph} ) then
		 ${LINK} ${RUN_DIR}/${f_graph} ${fgraph}         || exit
         else
             echo "ABORT: Cannot find ${fgraph} for n_mpas * n_proc (= $nnode * $nproc)"
             exit 1
       endif
  endif

  echo '========================================================================'
  echo  Run init_mpas_grib.csh to construct an initial ensemble at ${targ_utc}.
  echo '========================================================================'

  if ( ! -e $fgrib ) then

  echo '========================================================================'
  echo  Step 1. Run WPS/ungrib.exe over ${GRIB_DATA} to create ${fgrib}.
  echo '========================================================================'

  ${LINK} ${DATA_DIR}/${VTABLE} Vtable       	    || exit 1
  ${LINK} ${WPS_DIR}/ungrib.exe .           	    || exit 1
  ${LINK} ${WPS_DIR}/link_grib.csh .                || exit 1

  # Construct the GRIB source path from FGRIB_FORMAT in setup.csh.
  set grib_src = `echo $FGRIB_FORMAT | sed "s/YYYYMMDDHH/${grib_utc}/"`
  ./link_grib.csh ${GRIB_DIR}/${YYYY}/${YYYY}${MM}${DD}/${grib_src}   || exit 1

  cat >! namelist.wps << EOF
&share
 wrf_core = 'ARW',
 max_dom = 1,
 start_date = '${init_utc}',
 end_date   = '${init_utc}',
 interval_seconds = 10800
/

&geogrid
/

&ungrib
 out_format = 'WPS',
 prefix = '${GRIB_DATA}',
/

&metgrid
 fg_name = '${GRIB_DATA}'
/
EOF

  ./ungrib.exe   || exit 1
  ls -l $fgrib   || exit 1
  endif # ( -e $fgrib ) then


  echo '========================================================================'
  echo  Step 2. Run MPAS/init_atmosphere to create init.nc from ${GRIB_DATA}:${init_utc}.
  echo '========================================================================'

  # Configuration files for MPAS/init_atmosphere
  # Add ${MPAS_LEVEL_TXT} in $flist if config_nvertlevels != 55.
  ${COPY} ${DATA_DIR}/${STREAM_INIT} .   || exit 1

  # FIXME: static.nc should be prepared using the same MPAS version in advance.
  set statfile = `sed -n '/\"input\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_INIT} | \
                  grep filename_template | awk -F\" '{print $(NF-1)}'`
  if ( ! -r ${GRID_DIR}/${F_STATIC} ) then
     echo "ABORT: Static file not found: ${GRID_DIR}/${F_STATIC}"
     exit 1
  endif
  if ( "${statfile}" == "" ) then
     echo "ABORT: Could not parse static input filename from ${STREAM_INIT}."
     exit 1
  endif
  ${LINK} ${GRID_DIR}/${F_STATIC} ${statfile}   || exit 1

  # Get the executables and necessary files from RUN_DIR
  foreach fn ( atmosphere_model init_atmosphere_model )
     if ( ! -x ${MPAS_DIR}/${fn} ) then
        echo "ABORT: Cannot find executable ${MPAS_DIR}/${fn}"
        exit 1
     endif
     ${LINK} ${MPAS_DIR}/${fn} .   || exit 1
  end
  ${LINK} ${MPAS_DIR}/stream_list.*   .   || exit 1
  ${LINK} ${MPAS_DIR}/*BL       .   || exit 1
  ${LINK} ${MPAS_DIR}/*DATA     .   || exit 1

  # Update time and ungrib filename in namelist.init_atmosphere.
  # All other parameters should be properly edited before running this script.
  cat >! script.sed << EOF
  /config_start_time/c\
  config_start_time = '${init_utc}'
  /config_stop_time/c\
  config_stop_time = '${init_utc}'
  /config_met_prefix/c\
  config_met_prefix = '${GRIB_DATA}'
  /config_static_interp/c\
  config_static_interp = false
  /config_vertical_grid/c\
  config_vertical_grid = true
  /config_block_decomp_file_prefix/c\
  config_block_decomp_file_prefix = '${F_GRAPH}.'
EOF
  sed -f script.sed ${DATA_DIR}/${NML_INIT} >! ${NML_INIT}   || exit 1

  # Parse the init_atmosphere output filename from its stream definition.
  set fini = `sed -n '/<immutable_stream name=\"output\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${STREAM_INIT} | \
              grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`
  if ( "${fini}" == "" ) then
     echo "ABORT: Could not parse init_atmosphere output filename from ${STREAM_INIT}."
     exit 1
  endif

  if ( $RUN_IN_PBS == yes ) then

    set jobname = init_atm_mem${ensemble_member}

    cat >! run_init.pbs << EOF
#!/bin/tcsh
#==================================================================
#PBS -N ${jobname}
#PBS -A ${PROJ_NUMBER}
#PBS -o ${jobname}.log
#PBS -j oe
#PBS -q main
#PBS -l job_priority=economy
#PBS -l select=1:mpiprocs=${N_PROCS_MPAS}:ncpus=${N_CPUS}
#PBS -l walltime=${TIME_MPAS}
#==================================================================
${MPICMD} ./init_atmosphere_model
EOF

    set jid = `qsub run_init.pbs`

    # Wait until the job is finished in Derecho.
    set is_there = 0
    while ( $is_there == 0 )
      sleep 30
      qstat -w $jid
      set is_there = $?
    end

  else

    ${MPICMD} ./init_atmosphere_model   || exit 1

  endif # ( $RUN_IN_PBS == yes )

  ls -l $fini   || exit 1


  echo '========================================================================'
  echo  Step 3. Run MPAS/atmosphere to produce ensemble forecasts for ${fcst_hrs} hrs.
  echo '========================================================================'

  # Generate MPAS namelist file for the forecast run
  cat >! script.sed << EOF
  /config_start_time/c\
  config_start_time = '${init_utc}'
  /config_run_duration/c\
  config_run_duration = '${intv_utc}'
  /config_do_restart/c\
  config_do_restart = false
  /config_do_DAcycling/c\
  config_do_DAcycling = false
EOF
  sed -f script.sed ${RUN_DIR}/${NML_MPAS} >! ${NML_MPAS}   || exit 1

  # Check restart mode from the namelist we just wrote.
  set if_restart = `grep config_do_restart ${NML_MPAS} | awk '{print $3}'`

  if ( ${USE_REGIONAL} == true ) then
     # FIXME: prepare LBC files for initial ensemble forecast.
     # ${CSH_DIR}/driver_lbc_ens.csh  # Needs time adjustment for init period
     echo "WARNING: USE_REGIONAL=true but LBC prep for init ensemble is not yet automated."
     echo "         Ensure LBC files for the init period are available in ${LBC_DIR}."
  endif

  ${COPY} ${RUN_DIR}/${STREAM_ATM} streams.atmosphere   || exit 1

  # Change output_interval for the long init ensemble forecast.
  # restart, history, da_state are printed at the same interval, 
  # diagnostics is output more often to check the ensemble spread change in time later.
  sed -i -f - streams.atmosphere << EOF
/immutable_stream name="da_state"/,/\/>/ s|output_interval="[^"]*"|output_interval="${intv_utc}"|
/immutable_stream name="restart"/,/\/>/ s|output_interval="[^"]*"|output_interval="${intv_utc}"|
/<stream name="output"/,/\/>/ s|output_interval="[^"]*"|output_interval="${intv_utc}"|
/<stream name="diagnostics"/,/\/>/ s|output_interval="[^"]*"|output_interval="${intv_diag}"|
EOF

  # Some MPAS versions required the invariant stream.
  set if_invariant_defined = `grep invariant ${STREAM_ATM} | wc -l`
  if (${if_invariant_defined} > 0) then
      set finv = `sed -n '/<immutable_stream name=\"invariant\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere |
              grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`
      ${LINK} $fini $finv
  endif

  if ( $RUN_IN_PBS == yes ) then

    set jobname = atm_mem${ensemble_member}

    # Clean out any stale log files before submission
    if ( -e log.0000.out ) ${REMOVE} log.*

    cat >! run_atm.pbs << EOF
#!/bin/tcsh
#==================================================================
#PBS -N ${jobname}
#PBS -A ${PROJ_NUMBER}
#PBS -o ${jobname}.log
#PBS -j oe
#PBS -q main
#PBS -l job_priority=economy
#PBS -l select=${nnode}:mpiprocs=${nproc}:ncpus=128:mem=230GB
#PBS -l walltime=${TIME_MPAS}
#==================================================================
${MPICMD} ./atmosphere_model
EOF

    set jobid = `qsub run_atm.pbs`

    set is_running = 0
    while ( $is_running == 0 )
      sleep 30
      qstat -w $jobid
      set is_running = $?
    end

  else

    ${MPICMD} ./atmosphere_model   || exit 1

  endif # ( $RUN_IN_PBS == yes )

  # Verify the expected output file exists at the target time.
  if ( ${if_restart} == true ) then
     set frst = `sed -n '/<immutable_stream name=\"restart\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere | \
                 grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
  else
     set frst = `sed -n '/<immutable_stream name=\"da_state\"/,/\/>/{/Scree/{p;n};/##/{q};p}' streams.atmosphere | \
                 grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
  endif

  set fout = ${frst}`echo ${targ_utc} | sed -e 's/:/\./g'`.nc
  ls -l ${fout}   || exit 1

  # Optional: remove intermediate restart files, keeping only the target time.
  # Uncomment if disk space is a concern.
  #foreach rfile ( `ls -1 ${frst}*` )
  #  if ( $rfile != $fout ) ${REMOVE} $rfile
  #end

  echo "init_mpas_grib.csh done for member ${ensemble_member} to produce ${fout}"
  cd $RUN_DIR
