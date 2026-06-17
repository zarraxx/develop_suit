# postgis_dependencies package

`postgis_dependencies` builds the reusable dependency prefix used to build
PostGIS. It is layered on top of the same-target `gdal` and `cgal` packages.

## Boundary

This package consumes, but does not rebuild:

- `gdal-3.13.1-<triple>.tar.xz`
- `cgal-5.6.3-sfcgal-1.5.2-<triple>.tar.xz`

This package builds the additional dependencies listed for PostGIS:

- libmd
- libbsd
- Qhull
- protobuf
- protobuf-c

It intentionally does not build or package PostgreSQL, libpq, `pg_config`, or
PostGIS itself. PostgreSQL is combined in the later PostGIS package step.

MinGW currently skips libmd/libbsd because they are Linux/BSD compatibility
libraries and are not required for the Windows GNU PostGIS dependency prefix.

## Inputs

Required same-target prefixes:

```text
gdal-3.13.1-<triple>.tar.xz
cgal-5.6.3-sfcgal-1.5.2-<triple>.tar.xz
```

The build script accepts either archives or already extracted prefixes:

```sh
--gdal-archive=<tar>
--gdal-dir=<dir>
--cgal-archive=<tar>
--cgal-dir=<dir>
```

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

Use default local `gdal` and `cgal` archives:

```sh
./packages/postgis_dependencies/build.sh --target=x86_64 --clean --jobs=4
./packages/postgis_dependencies/build.sh --target=loongarch64 --clean --jobs=4
./packages/postgis_dependencies/build.sh --target=mingw64 --clean --jobs=4
```

Use explicit archives:

```sh
./packages/postgis_dependencies/build.sh \
  --target=x86_64 \
  --gdal-archive=packages/gdal/build/dist/gdal-3.13.1-x86_64-unknown-linux-gnu.tar.xz \
  --cgal-archive=packages/cgal/build/dist/cgal-5.6.3-sfcgal-1.5.2-x86_64-unknown-linux-gnu.tar.xz
```

## Output Layout

```text
packages/postgis_dependencies/build/out/postgis_dependencies-<triple>
packages/postgis_dependencies/build/dist/postgis_dependencies-<triple>.tar.xz
```

The installed prefix contains the GDAL and CGAL/SFCGAL dependency stacks plus
the additional PostGIS dependencies. Final validation removes ordinary `.a` and
`.la` files, preserves MinGW `*.dll.a` import libraries, copies MinGW DLLs to
`bin/`, rewrites Linux absolute in-prefix `DT_NEEDED` entries to basenames, and
patches Linux ELF RUNPATH entries to be `$ORIGIN`-relative.

## Release Artifact Names

```text
postgis_dependencies-<triple>.tar.xz
```

## Upstream Sources

libmd:

```text
https://archive.hadrons.org/software/libmd/libmd-1.2.0.tar.xz
```

libbsd:

```text
https://libbsd.freedesktop.org/releases/libbsd-0.12.2.tar.xz
```

Qhull:

```text
http://www.qhull.org/download/qhull-2020-src-8.0.2.tgz
```

The `--qhull-version` option currently accepts `2020.2` / `8.0.2`, which map
to the upstream `qhull-2020-src-8.0.2.tgz` archive.

protobuf:

```text
https://github.com/protocolbuffers/protobuf/releases/download/v21.0/protobuf-all-21.0.tar.gz
```

protobuf-c:

```text
https://github.com/protobuf-c/protobuf-c/releases/download/v1.5.2/protobuf-c-1.5.2.tar.gz
```

## Component Commands

### libmd 1.2.0

Linux only.

```sh
./configure --build=<build> --host=<target> --prefix=<prefix> \
  --enable-shared \
  --disable-static
make -j <jobs>
make install
```

### libbsd 0.12.2

Linux only.

```sh
./configure --build=<build> --host=<target> --prefix=<prefix> \
  --enable-shared \
  --disable-static
make -j <jobs>
make install
```

### Qhull 2020.2

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DLINK_APPS_SHARED=ON
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### protobuf 21.0

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_BUILD_TYPE=Release \
  -Dprotobuf_BUILD_TESTS=OFF \
  -Dprotobuf_BUILD_CONFORMANCE=OFF \
  -Dprotobuf_BUILD_EXAMPLES=OFF \
  -Dprotobuf_BUILD_PROTOC_BINARIES=OFF \
  -Dprotobuf_BUILD_LIBPROTOC=OFF \
  -Dprotobuf_BUILD_SHARED_LIBS=ON
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### protobuf-c 1.5.2

`protobuf-c` is built for the target runtime library. The target-side
`protoc-gen-c` compiler is disabled because the PostGIS build needs
`libprotobuf-c`, headers, and pkg-config metadata rather than a target-executed
generator.

```sh
./configure --build=<build> --host=<target> --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --disable-protoc
make -j <jobs>
make install
```
