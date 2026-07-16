#!/bin/tcsh
set echo
########################################################################################
# Set up parameters that are used for all the shell scripts throughout the cycling period.
#
# Note: 1. Specify a full path name at each line.
#       2. This script is called by driver_mpas_dart.csh (and some other shell scripts).
#       3. This script was tested with MPICMD on the NCART Derecho system.
#
# Usage: 1. create RUN_DIR as defined below.
#        2. copy this file and driver_mpas_dart.csh to RUN_DIR.
#        3. Go to RUN_DIR, then edit this file, as needed.
#        4. Execute driver_mpas_dart.csh, which will call this file.
#
# Prerequsite: i) Both DART and MPAS-A must be installed so that the filter and atmosphere_model
#              executables can be run in your RUN_DIR.
#              If initial ensemble should be created from scratch, WPS/ungrib.exe and
#              MPAS/init_atmosphere also need to be compiled and GRIB_DIR should be available.
#              ii) The MPAS mesh should be configured; both static.nc and graph.info files
#              should be available in GRID_DIR.
#              iii) All the namelist options should be properly edited beforehand, unless specified here.
#              input.nml, namelist.atmosphere, streams.atmosphere
#              (and qceff_table.csv for QCEFF) should be properly edited for your runs.
#
# Written by Soyoung Ha (NCAR/MMM) Nov-2025
########################################################################################
#
# General configuration 
#
set EXPERIMENT_NAME = EAKF
set MPAS_GRID       = wofs_mpas  	# Prefix of MPAS files (ex. wofs_mpas.afterda.nc)
set FILTER_NML      = input.nml

set USE_REGIONAL    = true 	# true  : use regional MPAS-A => calls update_bc.
                                # false : use global MPAS-A
set USE_RESTART     = true	# true  : use restart files for I/O, as defined in streams.atmosphere.
                                # false : use invariant and da_state file at streams; see template/streams.atmosphere.da_state
                                #         invariant stream is supported after MPASV8.
set USE_RTTOV       = false	# true  : check RTTOV_FILES below and define &obs_def_rttov_nml in input.nml.
set USE_CONDA       = true      #=> module load conda; conda activate npl (to run python in derecho)

# Time info for cycling
set DATE_INI = 2024-05-08_15:00:00      # initial cycle for spin-up or for the first guess time.
set DATE_BEG = 2024-05-08_15:30:00      # start date to run this script for cycling
set DATE_END = 2024-05-09_00:00:00      # end date to run this script for cycling; excluding extended forecasts
set INTV_DAY = 0                        # assimilation_period_days    in input.nml for cycling frequency
set INTV_SEC = 900                      # assimilation_period_seconds in input.nml for cycling frequency

# Model configuration in namelist.atmosphere
set     LEN_DISP = 3000         	# = 3 km; the finest resolution of the mesh [meter]
set      DT_MPAS = 15    		# config_dt [seconds] = LEN_DISP/1000. * 5 (or 4 or 6)

# PBS setup for NCAR HPCs (Derecho)
set   RUN_IN_PBS = yes          # Run on derecho using PBS? yes or no    # Change #
set  PROJ_NUMBER = xxxxxxxx	# Your account key for derecho  # Change #
set FILTER_NODES = 1            # for Derecho: -l select for DART/filter
set  MODEL_NODES = 1            # for Derecho: -l select for MPAS/atmosphere_model
set       N_CPUS = 128		# for Derecho: ncpus - no. of cpus per node (default = 128)
set N_PROCS_ANAL = 128		# Number of mpi processors for filter; reduce this for a large memory
set N_PROCS_MPAS = 128		# Number of mpi processors for MPAS (=> MODEL_NODES * N_PROCS_MPAS for graph.info)
set QUEUE_FILTER = regular	# queue priority for filter
set   QUEUE_MPAS = regular      # queue priority for mpas job (when queue is 'main' at derecho)
#set    MEMORY_GB = 230          # memory per node (GB) ; default mem=230GB (derecho)
set  TIME_FILTER = 00:15:00	# wall clock time for mpi filter runs
set    TIME_MPAS = 00:05:00	# walltime for prior forecast during DA - set walltime as the SMALLEST possible!


set   SST_UPDATE = false
set   SST_FNAME  = ${MPAS_GRID}.sfc_update.nc

# Ensemble filter configuration
set     ENS_SIZE = 3 	 	# Ensemble size
set ADAPTIVE_INF = true         # adaptive_inflation - If true, this script only supports
                                # spatially-varying state space prior inflation.
                                # And you also need to edit inf_sd_initial, inf_damping,
                                # inf_lower_bound, and inf_sd_lower_bound in &filter_nml.
set       CUTOFF = 0.036        # half-width localization radius
set   VLOC_COORD = 3		# vertical localization in height => set vert_normalization_height
set         VLOC = 111111.1     # half-width localization radius in height [meters] - will be mulplied by CUTOFF
set num_output_obs_members = $ENS_SIZE   # output members in obs_seq.out
set num_output_state_members = $ENS_SIZE # output members in output states
set binary_obs_seq = false        # binary or ascii obs_seq.final to produce
set DISTRIB_MEAN = false          # true for a large-memory job; false otherwise
set CONVERT_OBS  = true           # convert_all_obs_verticals_first = .true. in &assim_tools_nml
set CONVERT_STAT = false        #   convert_all_state_verticals_first = .false. in &assim_tools_nml

set     INFL_OUT = output_priorinf
set      INFL_IN = input_priorinf

# First Guess for cold-start runs or an initial ensemble
# Skip the first two lines unless init_mpas_grib.csh is called to create initial ensemble.
set GRIB_DIR  = /gdex/data/d084001 			# source directory for GRIB_DATA
set FGRIB_FORMAT = gfs.0p25.YYYYMMDDHH.f000.grib2	# for init_mpas_grib.csh
set GRIB_DATA = GFS         # GRIB DATA TYPE : GFS, GFSENS(GEFS), ERA5, or HRRRE
                            # for GFS or ERA5,  DART will be run to add perturbations.
                            # for GEFS, will use external data from GEFS ensemble
			    # for HRRRE, to test WOFS configuration (data is not in public)
set   VTABLE  = Vtable.${GRIB_DATA}	# Should specify a full path
set INIT_ENS_FCST_HRS = 120 # MPAS forecast hours to run for an initial ensemble

# Directories
set MPAS_DIR     = ${YOUR_PATH}/MPAS-Model_V8.0_fix
set DART_DIR     = ${YOUR_PATH}/DART_Regional
set DATA_DIR     = ${DART_DIR}/models/mpas_atm/data
set EXE_DIR      = ${DART_DIR}/models/mpas_atm/work
set CSH_DIR      = ${DART_DIR}/models/mpas_atm/shell_scripts

set ROOT_DIR     = ${YOUR_PATH}/MPAS_DART

set OBS_DIR      = ${ROOT_DIR}/OBS_SEQ        	# obs_seq.out
set GRID_DIR     = ${ROOT_DIR}/mesh		# MPAS mesh files like static.nc and graph.info
set INIT_DIR     = ${ROOT_DIR}/init             # MPAS initial ensemble under each member dir.
set LBC_DIR      = ${ROOT_DIR}/LBC              # LBCs under YYYYMMDDHHMM in this dir.
set SST_DIR      = ${ROOT_DIR}/sst		# only if sfc_update.nc will be used.
set WPS_DIR      = ${ROOT_DIR}/WPS		# only if init_mpas_grib.csh will be called.

set BASE_DIR     = ${ROOT_DIR}/${EXPERIMENT_NAME}
set RUN_DIR      = ${BASE_DIR}                    	# Run MPAS/DART cycling

set ENS_DIR      = member   	# Prefix for ensemble directory. This should match with advance_model.csh/temp_dir.

# init_template_filename in &model_nml in input.nml
set INIT_FNAME = ${MPAS_GRID}.init.nc
set F_TEMPLATE = ${GRID_DIR}/${INIT_FNAME}	# for init_template_filename in input.nml.
set F_GRAPH    = ${MPAS_GRID}.graph.info.part	# add .$ndecomp (= $MODEL_NODES * $N_PROCS)

# Namelist files
set NML_INIT     = namelist.init_atmosphere      # Namelist for init_atmosphere_model
set NML_MPAS     = namelist.atmosphere.regional  # Namelist for atmosphere_model
set NML_WPS      = namelist.wps			 # Namelist for WPS
set NML_DART     = input.nml			 # Namelist for DART
set STREAM_ATM   = streams.atmosphere		 # I/O list for atmosphere_model
set STREAM_INIT  = streams.init_atmosphere	 # I/O list for init_atmosphere_model

# User-defined coefficient files
set RTTOV_CSV    = ${DART_DIR}/observations/forward_operators/rttov_sensor_db.csv
set RTTOV_INPUT1 = ${DART_DIR}/models/mpas_atm/data/rtcoef_goes_16_abi.dat
set RTTOV_INPUT2 = ${DART_DIR}/models/mpas_atm/data/sccldcoef_goes_16_abi.dat
set RTTOV_FILES  = ( ${RTTOV_CSV} ${RTTOV_INPUT1} ${RTTOV_INPUT2} )

set SAMPLING_ERR_TBL = ${DART_DIR}/assimilation_code/programs/gen_sampling_err_table/work/sampling_error_correction_table.nc
#set BNRHF_CSV    = ${DATA_DIR}/dual_qceff_table.csv
#set KDEF_CSV     = ${DATA_DIR}/kde_qceff_table.csv
#set MPAS_LEVEL_TXT = L60.txt

# A list of model prognostic variables for prior backup before analysis,
# if save_prior = true in advance_model.csh: based on mpas_state_variables in &mpas_vars_nml
set VARLIST = 'xtime,theta,rho,u,w,qv,qc,qr,qi,qs,qg,qh,uReconstructZonal,uReconstructMeridional,refl10cm,t2m,u10,v10,q2,surface_pressure'

# mpas_lbc_variables in input.nml
set LBCLIST = "'lbc_qc', 'lbc_qr', 'lbc_qv', 'lbc_rho', 'lbc_theta', 'lbc_u', 'lbc_w'"


# Commands (do not need modification unless moving to new system)
set REMOVE = '/bin/rm -rf'
set   COPY = 'cp -pf'
set   MOVE = 'mv -f'
set   LINK = 'ln -sf'
set MPICMD = 'mpiexec'	# for Derecho
unalias cd
unalias ls
