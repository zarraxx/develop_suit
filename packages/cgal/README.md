# cgal package

`cgal` builds the CGAL/SFCGAL dependency prefix used by PostGIS builds that want
SFCGAL support. It is layered on top of the same-target Boost package.

## Boundary

This package builds:

- GMP
- MPFR
- CGAL
- SFCGAL

It consumes, but does not rebuild:

- Boost 1.84.0 by default

It intentionally does not build or package PostgreSQL, libpq, GDAL, GEOS, PROJ,
or PostGIS itself.

## Inputs

Required same-target Boost prefix:

```text
boost-1.84.0-<triple>.tar.xz
```

The build script accepts either `--boost-archive=<tar>` or an already extracted
prefix via `--boost-dir=<dir>`.

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

All targets are treated as cross-compilation targets, including x86_64 Linux.

## Default Image

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## Build Commands

Use the default local Boost archive:

```sh
./packages/cgal/build.sh --target=x86_64 --clean --jobs=4
./packages/cgal/build.sh --target=loongarch64 --clean --jobs=4
./packages/cgal/build.sh --target=mingw64 --clean --jobs=4
```

Use an explicit Boost archive:

```sh
./packages/cgal/build.sh \
  --target=x86_64 \
  --boost-archive=packages/boost/build/dist/boost-1.84.0-x86_64-unknown-linux-gnu.tar.xz
```

Expected output:

```text
packages/cgal/build/out/cgal-<cgal-version>-sfcgal-<sfcgal-version>-<triple>
packages/cgal/build/dist/cgal-<cgal-version>-sfcgal-<sfcgal-version>-<triple>.tar.xz
```

## Release Artifact Names

Default versions produce:

```text
cgal-5.6.3-sfcgal-1.5.2-<triple>.tar.xz
```

## Upstream Sources

GMP:

```text
https://ftp.gnu.org/gnu/gmp/gmp-6.3.0.tar.xz
```

MPFR:

```text
https://ftp.gnu.org/gnu/mpfr/mpfr-4.2.2.tar.xz
```

CGAL:

```text
https://github.com/CGAL/cgal/releases/download/v5.6.3/CGAL-5.6.3.tar.xz
```

SFCGAL:

```text
https://gitlab.com/sfcgal/SFCGAL/-/archive/v1.5.2/SFCGAL-v1.5.2.tar.bz2
```

## Build Direction

1. Copy/extract the Boost package into the output prefix.
2. Rewrite Boost CMake package metadata from `/opt/boost-...` to the current
   CGAL/SFCGAL prefix.
3. Build GMP as shared libraries. Linux targets enable GMP C++ bindings; MinGW
   disables them and uses the C library plus MPFR for the SFCGAL path.
4. Build MPFR as shared libraries against GMP from the prefix.
5. Install CGAL headers and CMake metadata against Boost/GMP/MPFR from the
   prefix.
6. Build SFCGAL as shared libraries against CGAL, Boost, GMP, and MPFR.
7. Remove ordinary `.a` and `.la` files; preserve MinGW `*.dll.a` import
   libraries.
8. Patch Linux ELF RUNPATH entries to be `$ORIGIN`-relative.

## Component Commands

### GMP 6.3.0

```sh
./configure \
  --build=<build> \
  --host=<target> \
  --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --enable-cxx
make -j <jobs>
make install
```

`ABI=64` is set for x86_64 targets. Other targets use GMP's default target ABI;
for example, loongarch64 uses `standard`. The loongarch64 GMP build also adds
`-D__int128__=__int128` because GMP 6.3.0's loongarch helper macro uses the GCC
spelling `__int128__`, while the clang toolchain accepts `__int128`.

MinGW uses `--disable-cxx`; Linux targets use `--enable-cxx`.

### MPFR 4.2.2

```sh
./configure \
  --build=<build> \
  --host=<target> \
  --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --with-gmp=<prefix>
make -j <jobs>
make install
```

### CGAL 5.6.3

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_TESTING=OFF \
  -DCGAL_BUILD_TESTING=OFF \
  -DCGAL_BUILD_EXAMPLES=OFF \
  -DCGAL_BUILD_DEMOS=OFF \
  -DBOOST_ROOT=<prefix> \
  -DBoost_ROOT=<prefix> \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DGMP_INCLUDE_DIR=<prefix>/include \
  -DGMP_LIBRARIES=<prefix>/lib/libgmp.so \
  -DGMPXX_LIBRARIES=<prefix>/lib/libgmpxx.so \
  -DMPFR_INCLUDE_DIR=<prefix>/include \
  -DMPFR_LIBRARIES=<prefix>/lib/libmpfr.so
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

MinGW uses `*.dll.a` import libraries for the GMP/MPFR library paths.

### SFCGAL 1.5.2

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DSFCGAL_BUILD_TESTS=OFF \
  -DSFCGAL_BUILD_EXAMPLES=OFF \
  -DSFCGAL_BUILD_VIEWER=OFF \
  -DSFCGAL_BUILD_OSG=OFF \
  -DBOOST_ROOT=<prefix> \
  -DBoost_ROOT=<prefix> \
  -DBoost_NO_SYSTEM_PATHS=ON \
  -DCGAL_DIR=<prefix>/lib/cmake/CGAL \
  -DGMP_INCLUDE_DIR=<prefix>/include \
  -DGMP_LIBRARIES=<prefix>/lib/libgmp.so \
  -DGMPXX_LIBRARIES=<prefix>/lib/libgmpxx.so \
  -DMPFR_INCLUDE_DIR=<prefix>/include \
  -DMPFR_LIBRARIES=<prefix>/lib/libmpfr.so
cmake --build <build> --parallel <jobs>
cmake --install <build>
```
