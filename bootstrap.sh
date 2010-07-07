#!/bin/sh

DDIR="./deps"
ROOTDIR=`pwd`
DEPSDIR="$ROOTDIR/$DDIR"

mkdir -p $DEPSDIR
cd $DEPSDIR

# Make sure gproc is available
(
  if [ ! -d "$DEPSDIR/gproc" ]; then
    git clone git://github.com/auser/gproc.git
  fi
  cd gproc
  make 
)
