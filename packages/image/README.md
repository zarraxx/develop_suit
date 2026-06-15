# image package

`image` should build the reusable image-codec prefix used by GDAL and other
geospatial packages. It should be layered on top of
`postgresql_dependencies-<triple>` instead of rebuilding the common compression
and XML/network stack.

## Boundary

This package owns image codecs only:

- libjpeg-turbo
- libpng
- libtiff

It does not build GDAL, GEOS, PROJ, libgeotiff, SpatiaLite, or PostgreSQL.

The package should consume the same-target `postgresql_dependencies` prefix as
its base. That base already includes the common libraries needed by this image
stack, including zlib, zstd, xz/liblzma, OpenSSL, curl, sqlite, libxml2, ICU,
and related runtime libraries.

## Inputs

Required base prefix:

```text
postgresql_dependencies-<triple>.tar.xz
postgresql_dependencies-18-<triple>.tar.xz
```

The build script should also accept an already extracted base prefix via a
`--postgresql-deps-dir=<dir>` style option, matching the pattern used by the
other package scripts.

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

All targets are built through the cross-compilation path, including
`x86_64-unknown-linux-gnu`.

## Default Image

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## Build Commands

Use the default local `postgresql_dependencies` archive:

```sh
./packages/image/build.sh --target=x86_64 --clean --jobs=4
./packages/image/build.sh --target=loongarch64 --clean --jobs=4
./packages/image/build.sh --target=mingw64 --clean --jobs=4
```

Use an explicit base archive:

```sh
./packages/image/build.sh \
  --target=x86_64 \
  --postgresql-deps-archive=packages/postgresql_dependencies/build/dist/postgresql_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

## Upstream Sources

libjpeg-turbo:

```text
https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.4.1/libjpeg-turbo-3.1.4.1.tar.gz
```

libpng:

```text
https://prdownloads.sourceforge.net/libpng/libpng-1.6.58.tar.xz
```

libtiff:

```text
https://download.osgeo.org/libtiff/tiff-4.7.1.tar.xz
```

## Build Direction

Expected output:

```text
packages/image/build/out/image-<triple>
packages/image/build/dist/image-<triple>.tar.xz
```

Build order:

1. Copy/extract `postgresql_dependencies` into the output prefix.
2. Build libjpeg-turbo as shared libraries, with ordinary static archives
   disabled or removed after install.
3. Build libpng against zlib from the copied prefix.
4. Build libtiff against libjpeg, libpng, zlib, zstd, and liblzma from the
   copied prefix.
5. Remove ordinary `.a` and `.la` files; preserve MinGW `*.dll.a` import
   libraries.
6. Patch Linux ELF RUNPATH entries to be `$ORIGIN`-relative.

## Component Commands

### libjpeg-turbo 3.1.4.1

Source:

```text
https://github.com/libjpeg-turbo/libjpeg-turbo/releases/download/3.1.4.1/libjpeg-turbo-3.1.4.1.tar.gz
```

CMake:

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DENABLE_SHARED=ON \
  -DENABLE_STATIC=OFF \
  -DWITH_SIMD=OFF \
  -DWITH_JPEG8=ON \
  -DWITH_TURBOJPEG=ON \
  -DWITH_TOOLS=OFF \
  -DWITH_TESTS=OFF
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### libpng 1.6.58

Source:

```text
https://prdownloads.sourceforge.net/libpng/libpng-1.6.58.tar.xz
```

CMake:

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DPNG_SHARED=ON \
  -DPNG_STATIC=OFF \
  -DPNG_TESTS=OFF \
  -DPNG_TOOLS=OFF \
  -DZLIB_ROOT=<prefix>
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### libtiff 4.7.1

Source:

```text
https://download.osgeo.org/libtiff/tiff-4.7.1.tar.xz
```

CMake:

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -Dtiff-tools=OFF \
  -Dtiff-tests=OFF \
  -Dtiff-contrib=OFF \
  -Dtiff-docs=OFF \
  -Dtiff-deprecated=OFF \
  -Dld-version-script=OFF \
  -Djpeg=ON \
  -Dlzma=ON \
  -Dzstd=ON \
  -DZLIB_ROOT=<prefix>
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

Final validation removes ordinary `.a` and `.la` files, preserves MinGW
`*.dll.a` import libraries, copies MinGW DLLs to `bin/`, and writes a
`README.image` marker into the prefix.
