#!/bin/bash

ROOT=$(cd `dirname $0`;pwd)
source $ROOT/.env

export ARCH=`arch`

mkdir -p $ROOT/mount_root
mkdir -p $ROOT/build/out/$ARCH/osxcross/
mkdir -p $ROOT/build/build/$ARCH

read -rsp "Nextcloud share password: " PASS

sudo docker run -it --rm  -v $ROOT/mount_root:/data \
                          -v  $ROOT/build/out/$ARCH/osxcross/:/opt/osxcross \
                          -v  $ROOT/build/build/$ARCH:/build \
                          -e  MACOS_SDK_URL=$MACOS_SDK_URL \
                          -e  PASS=$PASS \
                          ghcr.io/zarraxx/develop_suit:llvm-18.1.8 \
/bin/bash -c /data/container_build.sh  --arch=$ARCH
