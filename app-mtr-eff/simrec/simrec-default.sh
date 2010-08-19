#!/bin/bash

# Params
export MOMENTUMS="15"
export CDBS="75pct-maxcorr r-maxcorr"

# For each momentum...
for P in $MOMENTUMS
do

  for C in $CDBS
  do

    # Write options in Config.C
    ./preprocess.sh Config.C.in \
      MUONS_PER_EVENT   1  \
      MOMENTUM_GEV_C   $P. \
      PHI_MIN_DEG       0. \
      PHI_MAX_DEG     360. \
      THETA_MIN_DEG   170. \
      THETA_MAX_DEG   180. \
    > Config.C

    # Launch the jobs (40 000 generated muons total!)
    echo ""
    ./joblaunch.sh \
      --jobs     40 \
      --events 1000 \
      --tag    sim-muplus-onemu-angles-${P}gev-${C} \
      --cdb    'local:///dalice05/berzano/cdb/'${C}'/'

    # Remove the Config.C (it can be found in jobs directories)
    rm Config.C

  done

done
