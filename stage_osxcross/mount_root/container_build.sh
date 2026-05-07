#!/bin/bash
set -e

cd /usr/lib

ln -sf libtinfow.so libtinfo.so
ln -sf libncursesw.so libncurses.so

cd /build
rm -rf * *.*
ARCH=$(arch)


export TARGET_DIR=/opt/osxcross
export LLVM_HOME=/opt/llvm-18.1.8

ln -s $LLVM_HOME/bin/clang $LLVM_HOME/bin/gcc
ln -s $LLVM_HOME/bin/clang++ $LLVM_HOME/bin/g++
ln -s $LLVM_HOME/bin/llvm-ar $LLVM_HOME/bin/ar
ln -s $LLVM_HOME/bin/llvm-ranlib $LLVM_HOME/bin/ranlib
ln -s $LLVM_HOME/bin/llvm-strip $LLVM_HOME/bin/strip
ln -s $LLVM_HOME/bin/llvm-strings $LLVM_HOME/bin/strings
ln -s $LLVM_HOME/bin/llvm-as $LLVM_HOME/bin/as
ln -s $LLVM_HOME/bin/lld $LLVM_HOME/bin/ld
ln -s $LLVM_HOME/bin/llvm-size $LLVM_HOME/bin/size


git clone https://github.com/tpoechtrager/osxcross.git
cd osxcross
cd tarballs
ln -s /cache/MacOSX${SDK_VERSION}.sdk.tar.xz MacOSX${SDK_VERSION}.sdk.tar.xz
ls -la /cache
ls -la
file  MacOSX${SDK_VERSION}.sdk.tar.xz

cd /build/osxcross

TARGET_DIR=${TARGET_DIR} UNATTENDED=1 SDK_VERSION=${SDK_VERSION} ./build.sh
rm -rf ${TARGET_DIR}/SDK/*

