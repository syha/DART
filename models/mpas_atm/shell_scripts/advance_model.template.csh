#!/bin/csh
#
# advance_model.template.csh for mpas_atm
#
# A template for advance_model.csh to run the MPAS-A(tmostphere) model from the DART analysis.
#
# advance_model.csh is called by advance_model.template.pbs in driver_mpas_dart.csh
# after the analysis step - filter, update_mpas_states (and update_bc for regional runs) -
# is done at each cycle.
#
# This script performs the following:
# 1.  Creates a temporary directory to run an MPAS-A realization (see options)
# 2.  Gets all the files necessary for the model run in each member directory.
# 3.  Updates an MPAS namelist from a template with new dates.
# 4.  Runs the MPAS-A model in a restart mode until the target time is reached.
# 5.  Regional MPAS is also supported, if chosen.
# 6.  Checks for incomplete runs.
#
# As of Dec 2024, a new features (for MPASV8+) is supported as below.
# 7. Cycling in non-restart mode is also supported through 'da_state' and 'invariant' streams.
#
#
# Note: 1. This script supports MPAS V7+ and the Manhattan release of DART. 
#          It is NOT backward compatible for older versions.
#       2. MPAS is run in a restart mode during the cycles, which means
#          both input and output of the model run are restart files.
#          This also means that one should not delete the member directory as
#          one needs to keep the restart file for each member during the cycle.
#       3. The input analysis file should be provided through update_mpas_states 
#          (which is supposed to be run before running this script).
#       4. For the required data to run this script, check the section of 'dependencies'.
#       5. Anything specific to the experiment is supposed to be provided in ${CENTRALDIR}/.
#
# Arguments for this script (created by 'filter' or 'perfect_model_obs') are:
# 1) ensemble member number
# 2) maximum ensemble member number
# 
# This script can loop over all the ensemble members unless the two input 
# arguments are identical for a specific ensemble member number.
#----------------------------------------------------------------------
set ensemble_member = $1
set ensemble_max    = $2

# Do you want to save prior states before being overwritten at the next cycle?
#-------------------------------------------------------------------
set save_prior = false 

echo "Running advance_model.csh with save_prior = ${save_prior} for ensemble member ${ensemble_member}."

# mpi command
#-------------------------------------------------------------------
#set mpicmd = "mpi -n 4"			# Mac OS
set mpicmd = "mpiexec"			# Derecho (cpu)

# Other commands
#-------------------------------------------------------------------
set  REMOVE = 'rm -rf'
set    COPY = 'cp -pf'
set    MOVE = 'mv -f'
set    LINK = 'ln -sf'
unalias cd
unalias ls

# The run-time directory for the entire experiment is called CENTRALDIR;
#-------------------------------------------------------------------
set CENTRALDIR = `pwd`

# Copy necessary input files/executables/files common
# to all model advances to a clean, temporary directory.
#-------------------------------------------------------------------
if ( ! -r ${CENTRALDIR}/input.nml ) then
     echo ABORT\: advance_model.csh could not find required readable dependency ${CENTRALDIR}/input.nml
     exit 1
endif

foreach f ( namelist.atmosphere streams.atmosphere )
if ( ! -r ${CENTRALDIR}/$f ) then
     echo ABORT\: advance_model.csh could not find required readable dependency ${CENTRALDIR}/$f
     echo The file is assumed to be edited for your own configuration.
     exit 1
endif
end

if ( ! -x ${CENTRALDIR}/advance_time ) then
     echo ABORT\: advance_model.csh could not find required executable dependency ${CENTRALDIR}/advance_time
     exit 1
endif

if ( ! -d ${CENTRALDIR}/MPAS_RUN ) then
      echo ABORT\: advance_model.csh could not find required data directory ${CENTRALDIR}/MPAS_RUN, 
      echo         which contains all the default input files for running MPAS/atmosphere_model.
      exit 1
endif

if ( ! -x ${CENTRALDIR}/MPAS_RUN/atmosphere_model ) then
     echo ABORT\: advance_model.csh could not find required executable dependency ${CENTRALDIR}/MPAS_RUN/atmosphere_model
     echo         ${CENTRALDIR}/MPAS_RUN/atmosphere_model
     exit 1
endif

# NOTE: advance_time returns YYYYMMDDHH (10 digits) for on-hour times
# and YYYYMMDDHHMM (12 digits) for sub-hourly times
# Solution: Use "advance_time -w" which always returns ISO format (YYYY-MM-DD_HH:MM:SS),
# then strip non-digits and take 12 characters to get a canonical YYYYMMDDHHMM timestamp
# that works for both hourly and sub-hourly cycling without any special-casing.
alias iso2tag 'echo \!* -w | ${CENTRALDIR}/advance_time | sed "s/[^0-9]//g" | cut -c1-12'

# A list of input analysis file names (i.e., output from update_mpas_states).
#-------------------------------------------------------------------
set inlist  = `grep update_output_file_list ${CENTRALDIR}/input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`

set sample = `head -1 $inlist`
set dhead  = `dirname $sample | cut -c1-6`
if($dhead != "member") then
   echo "Check temp_dir below. The directory name cannot start with 'member'."
   echo "Input ensemble directories are named as $dhead instead."
   exit
endif

# Common input files based on the model configuration
#-------------------------------------------------------------------
# Get the grid info files - now for PIO
set fs_grid = `grep config_block_decomp_file_prefix ${CENTRALDIR}/namelist.atmosphere | awk '{print $3}' | sed -e "s/['\"]//g"`

# Surface update
set if_sfc_update = `grep config_sst_update ${CENTRALDIR}/namelist.atmosphere | awk '{print $3}'`
set fsfc = `sed -n '/<stream name=\"surface\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${CENTRALDIR}/streams.atmosphere | \
               grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`

# Sanity check - A switch for cycling
set if_DAcycling = `grep config_do_DAcycling ${CENTRALDIR}/namelist.atmosphere | wc -l`
if($if_DAcycling == 0) then
   echo "Please add config_do_DAcycling = .true. in \&restart"
   echo "in ${CENTRALDIR}/namelist.atmosphere."
   exit -1
endif

#----------------------------------------------------------------------
# Check cycling mode and input/output file names.
#----------------------------------------------------------------------
set fnml = ${CENTRALDIR}/namelist.atmosphere
set if_restart = `grep config_do_restart   ${fnml} | awk '{print $3}' | sed -e "s/[.'\"]//g"`
set if_cycling = `grep config_do_DAcycling ${fnml} | awk '{print $3}' | sed -e "s/[.'\"]//g"`
set if_jedi_io = `grep config_jedi_da      ${fnml} | awk '{print $3}' | sed -e "s/[.'\"]//g"`

# Prefix of each file name (for I/O)
set fInO = ${CENTRALDIR}/streams.atmosphere

set finit = `sed -n '/<stream name=\"input\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${fInO} | \
                    grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`
set fhead = `sed -n '/<immutable_stream name=\"restart\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${fInO} | \
                    grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
set fdiag = `sed -n '/<stream name=\"diagnostics\"/,/<\/stream>/{/Scree/{p;n};/##/{q};p}' ${fInO} | \
                    grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
   
if ( ( ${if_restart} == false ) && ( ${if_cycling} == true ) && ( ${if_jedi_io} == true ) ) then
	set fhead = `sed -n '/<immutable_stream name=\"da_state\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${fInO} | \
                   grep filename_template | awk -F= '{print $2}' | awk -F$ '{print $1}' | sed -e 's/"//g'`
   set fstatic = `sed -n '/<stream name=\"invariant\"/,/\/>/{/Scree/{p;n};/##/{q};p}' ${fInO} | \
                     grep filename_template | awk -F= '{print $2}' | sed -e 's/"//g'`
endif

echo "Cycling mode: restart = ${if_restart}, DAcycling = ${if_cycling}, jedi_io = ${if_jedi_io}"
echo "Input files: ${fstatic} for static fields, ${finit} for input fields" 
echo "Output files: ${fhead}.YYYY-MM-DD_HH.MN.SS.nc and ${fdiag}.YYYY-MM-DD_HH.MN.SS.nc"
echo ""

set is_it_regional = `grep config_apply_lbcs ${fnml} | awk '{print $3}' | sed -e "s/[.'\"]//g"`
if ( ${is_it_regional} == true ) then
      echo "This is a regional MPAS run. We need LBCs and update_bc."
      set blist  = `grep update_boundary_file_list ${CENTRALDIR}/input.nml | awk '{print $3}' | cut -d ',' -f1 | sed -e "s/'//g" | sed -e 's/"//g'`
endif

#----------------------------------------------------------------------
# A main section for the model integration
#----------------------------------------------------------------------
while( $ensemble_member <= $ensemble_max )

   # Create a new temp directory for each member unless requested to keep and it exists already.
   set temp_dir = 'member'${ensemble_member}

   if(! -d $temp_dir) mkdir -p $temp_dir  || exit 1
   cd $temp_dir                           || exit 1

   # Get the program and necessary auxiliary files for the model
   ${LINK} ${CENTRALDIR}/MPAS_RUN/atmosphere_model     .         || exit 1
   ${LINK} ${CENTRALDIR}/MPAS_RUN/*BL                  .         || exit 1
   ${LINK} ${CENTRALDIR}/MPAS_RUN/*DATA                .         || exit 1
   ${LINK} ${CENTRALDIR}/MPAS_RUN/stream_list.atmosphere.* .     || exit 1
   ${LINK} ${CENTRALDIR}/advance_time                  .         || exit 1

   # Get the files specific for this experiment
   ${COPY} ${CENTRALDIR}/input.nml                     .         || exit 1
   ${LINK} ${CENTRALDIR}/streams.atmosphere            .         || exit 1
   ${COPY} ${CENTRALDIR}/namelist.atmosphere           .         || exit 1
   ${LINK} ${CENTRALDIR}/${fs_grid}*                   .	        || exit 1

   if( $if_sfc_update == .true. || $if_sfc_update == true ) then
       ${LINK} ${CENTRALDIR}/${fsfc} .
       ls -lL $fsfc						 || exit 1
   endif

   # Input analysis file
   set input_file = `head -n $ensemble_member ${CENTRALDIR}/${inlist}  | tail -1`
   set input_file = `basename $input_file`

   # Analysis time
   set anal_utc = `ncdump -v xtime $input_file | tail -2 | head -1 | cut -d";" -f1 | sed -e 's/"//g'`
   set    tanal = `iso2tag ${anal_utc} 0`  #=> YYYYMMDDHHMN
   
   # Target forecast time (= next analysis time)
   set assim_days = `grep assimilation_period_days    input.nml | awk '{print $3}' | cut -d ',' -f1`
   set assim_secs = `grep assimilation_period_seconds input.nml | awk '{print $3}' | cut -d ',' -f1`
   set   targ_utc = `echo ${anal_utc} ${assim_days}d${assim_secs}s -w | ./advance_time`
   set      tfcst = `iso2tag ${targ_utc} 0`  #=> YYYYMMDDHHMN
   
   # Compute forecast interval in ISO format (DD_HH:MM:SS)
   @ total_seconds = $assim_days * 86400 + $assim_secs
   @ days   = $total_seconds / 86400
   @ remain = $total_seconds % 86400
   @ hours  = $remain / 3600
   @ remain = $remain % 3600
   @ mins   = $remain / 60
   @ secs   = $remain % 60

   # forecast length in ISO format (DD_HH:MM:SS) for namelist editing
   set fcst_length = `printf "%02d_%02d:%02d:%02d" $days $hours $mins $secs`

   cat >! script.sed << EOF
   /config_start_time/c\
    config_start_time   = '${anal_utc}'
   /config_run_duration/c\
    config_run_duration = '${fcst_length}'
EOF

   echo  ${input_file}
   ls -l ${input_file}							|| exit 1
   if ( -e namelist.atmosphere )  ${REMOVE} namelist.atmosphere
   sed -f script.sed ${CENTRALDIR}/namelist.atmosphere >! namelist.atmosphere

   if ( $is_it_regional == true ) then # For regional runs, we need to update the LBC file as well.
        set flbc = `head -n $ensemble_member ${CENTRALDIR}/${blist}  | tail -1`
        set flbc = `basename $flbc`
        set tnow = `echo $anal_utc | sed -e 's/:/\./g'`
        set tnxt = `echo $targ_utc | sed -e 's/:/\./g'`
        set flbcN = `echo $flbc | sed -e "s/$tnow/$tnxt/g"`
        ls -lL ${flbc} ${flbcN} 		|| exit 1
   endif

   # clean out any old log files
   if ( -e log.atmosphere.0000.out ) ${REMOVE} log.atmosphere.0000.out

   # Run the model
   $mpicmd ./atmosphere_model

   # Check the output status
   ${MOVE} log.atmosphere.0000.out log.atmosphere.${tanal}.out
   ls -lrt >! list.${tanal}.txt
  
   # Model output at the target time
   set output_file = ${fhead}`echo ${targ_utc} | sed -e 's/:/\./g'`.nc
   if ( ! -e ${output_file} ) then
      echo "ABORT: model output ${output_file} not found (model crashed before writing output)"
      echo $ensemble_member >>! ${CENTRALDIR}/blown.${tanal}_${tfcst}.out
      exit 1
   endif
   set fcst_utc = `ncdump -v xtime ${output_file} | tail -2 | head -1 | cut -d";" -f1 | sed -e 's/"//g'`

   # Check if the model was succefully completed.
   if($fcst_utc != $targ_utc) then
      if( -e ${CENTRALDIR}/blown.${tanal}_${tfcst}.out ) then
          set ichk = `grep $ensemble_member ${CENTRALDIR}/blown.${tanal}_${tfcst}.out | wc -l`
          if ( $ichk == 0 ) echo $ensemble_member >>! ${CENTRALDIR}/blown.${tanal}_${tfcst}.out
      else
          echo $ensemble_member >>! ${CENTRALDIR}/blown.${tanal}_${tfcst}.out
      endif
      echo "Model failure! Check file " ${CENTRALDIR}/blown.${tanal}_${tfcst}.out
      exit 1
   else
      set n = `tail log.atmosphere.${tanal}.out | grep complete | wc -l`
      if($n < 1) then
         echo $ensemble_member >>! ${CENTRALDIR}/incomplete.${tanal}_${tfcst}.out
         exit 2
      else 
      echo Model is run successfully.
      echo
      endif
   endif

   # Back up some fields and clean up.
   #-------------------------------------------------------------------
   set vlist = VARLIST
   # 'xtime,theta,rho,u,w,qv,qc,qr,uReconstructZonal,uReconstructMeridional'
   if($save_prior == true) then
      set fprior = prior.`echo ${targ_utc} | sed -e 's/:/\./g'`.nc
      ncks -O -v ${vlist} ${output_file} $fprior
      ls -l $fprior
   endif

   # Change back to the top directory.
   #-------------------------------------------------------------------
   cd $CENTRALDIR
   ls -l ${temp_dir}/${output_file}		|| exit 1
   echo ${temp_dir}/${output_file} >> list.${tfcst}.txt

   echo "Ensemble Member $ensemble_member completed"

   # Now repeat the entire process for other ensemble members
   #-------------------------------------------------------------------
   @ ensemble_member = $ensemble_member + 1

end

exit 0
