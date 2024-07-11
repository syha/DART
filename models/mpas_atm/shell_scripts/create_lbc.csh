#!/bin/tcsh
############################################
#PBS -N create_lbc
#PBS -A xxxxxxxx
#PBS -j oe
#PBS -q main
#PBS -l select=1:mpiprocs=1:ncpus=1
#PBS -l walltime=00:10:00
############################################

if ( $#argv != 4 ) then
     echo "Usage: create_lbc.csh mpas.nc lbc.nc mesh.nc points.txt"
     exit
else
     set b = $1		# global prior - restart.nc (input)
     set a = $2		# regional lbc - lbc.nc (to be created)
     set m = $3		# global mesh  - mesh.nc (input)
     set p = $4		# regional domain info - points.txt (input)
     echo
     echo create_lbc.csh $1 $2 $3 $4
     echo
endif

# LBC variables - Users can edit it based on their lbc file.
# ncdump -h lbc.nc | grep "lbc_" | grep Time | awk '{print $2}' | cut -d "(" -f1 | sed -e 's/lbc_//g'
set vlbc = ( xtime,theta,rho,w,u,qv,qc,qr,qi,qs,qg,qh )

# Check the executable and files
foreach fn ( create_region $p $m $b )
if( ! -e ${fn} ) then
    echo Cannot find $fn
    exit
endif
end
if( -e $a ) then
    echo $a already exists. We cannot create it. Stop.
    exit
endif

set r = `head -1 $p | awk '{print $2}'`   # region name
set o = ${r}.region.nc
set g = ${r}.graph.info

set f = out.nc

# clean up first
foreach fn ( $f $o $g )	
 if( -e $fn ) \rm -f $fn
end

# extract lbc variables
ncks -v $vlbc $b $f	|| exit
foreach v ( $vlbc )
  set vs = `echo $v | cut -c5-`
  ncrename -v $vs,$v $f			|| exit
end

# Add global mesh info
ncks -A $m $f				|| exit

# Cut out the global mesh over the region
create_region $p $f >! create_region.log

# Make an output lbc file
ncks -v $vlbc $o $a	|| exit

ls -lL $a		|| exit
\rm -f $g $f $o

#deactivate
