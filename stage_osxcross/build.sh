#!/bin/bash

ROOT=$(cd `dirname $0`;pwd)
PARENT=$(dirname $ROOT)
export SDK_VERSION=13.3

source $ROOT/.env

export ARCH=`arch`

sudo rm -rf $ROOT/build/out/$ARCH/osxcross/
sudo rm -rf $ROOT/build/build/$ARCH


mkdir -p $ROOT/mount_root
mkdir -p $ROOT/build/out/$ARCH/osxcross/
mkdir -p $ROOT/build/build/$ARCH
mkdir -p $PARENT/cache


read -rsp "Nextcloud share password: " PASS
curl -L -u "anonymous:${PASS}" \
  "$MACOS_SDK_URL" \
  -o $PARENT/cache/MacOSX${SDK_VERSION}.sdk.tar.xz

## Building cctools-port (986-ld64-711) ##
sudo docker run -it --rm  -v $ROOT/mount_root:/data \
                          -v $ROOT/build/out/$ARCH/osxcross/:/opt/osxcross \
                          -v $ROOT/build/build/$ARCH:/build \
                          -v $PARENT/cache:/cache \
                          -e SDK_VERSION=$SDK_VERSION \
                          -e ARCH=$ARCH \
                          ghcr.io/zarraxx/develop_suit:llvm-18.1.8 \
/bin/bash -c /data/container_build.sh  --arch=$ARCH
