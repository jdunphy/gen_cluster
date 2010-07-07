#!/bin/sh

DDIR="./deps"
ROOTDIR=`pwd`
DEPSDIR="$ROOTDIR/$DDIR"

RABBIT_VERSION="1.8.0"

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
