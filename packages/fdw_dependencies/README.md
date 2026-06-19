# fdw_dependencies

`fdw_dependencies` builds a reusable client-library prefix for PostgreSQL FDW packages.

It is intentionally limited to redistributable open-source client libraries. Vendor binary SDKs such as Oracle Instant Client and IBM DB2 CLI/ODBC are documented here as build-time inputs for downstream FDW packages, but they are not bundled into this package.

The package consumes an existing `postgresql_dependencies` prefix as its base
runtime/development prefix. It reuses the base OpenSSL, zlib, curl, iconv, and
other common libraries instead of rebuilding them here.

## Components

- unixODBC `2.3.14`, Linux targets only
- FreeTDS `1.5.16`
- MariaDB Connector/C `3.4.9`, used as the MySQL client library
- hiredis `1.4.0`
- mongo-c-driver `1.30.8`, including libbson

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

All targets are built through the package cross-compilation flow, including x86_64 Linux. unixODBC is skipped for `x86_64-w64-windows-gnu`; FreeTDS is built without ODBC support on MinGW.

## Default Image

`ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`

Override it with `--image=<image>`.

## Inputs

Required:

- `postgresql_dependencies` for the same target triple, either as an archive or
  as an already extracted prefix.

The build script auto-detects these local archives when present:

```text
packages/postgresql_dependencies/build/dist/postgresql_dependencies-18-<triple>.tar.xz
packages/postgresql_dependencies/build/dist/postgresql_dependencies-<triple>.tar.xz
tmp/postgresql_dependencies-18-<triple>.tar.xz
tmp/postgresql_dependencies-<triple>.tar.xz
```

Explicit inputs:

```bash
./packages/fdw_dependencies/build.sh \
  --target=x86_64 \
  --postgresql-deps-archive=packages/postgresql_dependencies/build/dist/postgresql_dependencies-18-x86_64-unknown-linux-gnu.tar.xz

./packages/fdw_dependencies/build.sh \
  --target=x86_64 \
  --postgresql-deps-dir=/path/to/postgresql_dependencies-18-x86_64-unknown-linux-gnu
```

## Build Commands

```bash
./packages/fdw_dependencies/build.sh --target=x86_64 --clean --jobs=8
./packages/fdw_dependencies/build.sh --target=aarch64 --clean --jobs=8
./packages/fdw_dependencies/build.sh --target=riscv64 --clean --jobs=8
./packages/fdw_dependencies/build.sh --target=loongarch64 --clean --jobs=8
./packages/fdw_dependencies/build.sh --target=mingw64 --clean --jobs=8
```

Version knobs:

```bash
./packages/fdw_dependencies/build.sh \
  --target=x86_64 \
  --unixodbc-version=2.3.14 \
  --freetds-version=1.5.16 \
  --mariadb-version=3.4.9 \
  --hiredis-version=1.4.0 \
  --mongo-c-driver-version=1.30.8
```

## Output Layout

The installed prefix is staged under:

```text
packages/fdw_dependencies/build/out/fdw_dependencies-<triple>/
```

Expected layout:

```text
include/
lib/
lib/pkgconfig/
lib/cmake/
bin/                # mainly MinGW DLLs and helper binaries when installed
README.fdw-dependencies
```

Final archives:

```text
packages/fdw_dependencies/build/dist/fdw_dependencies-<triple>.tar.xz
```

## Component Build Details

### unixODBC

Linux only.

Source:

```text
https://www.unixodbc.org/unixODBC-2.3.14.tar.gz
```

Configure:

```bash
./configure \
  --build=<build-triple> \
  --host=<target-triple> \
  --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --disable-gui \
  --disable-drivers \
  --disable-driver-conf \
  --disable-iconv
```

Build and install:

```bash
make -j <jobs>
make install
```

### FreeTDS

Source:

```text
https://github.com/FreeTDS/freetds/releases/download/v1.5.16/freetds-1.5.16.tar.bz2
```

Linux configure:

```bash
./configure \
  --build=<build-triple> \
  --host=<target-triple> \
  --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --disable-server \
  --disable-apps \
  --with-tdsver=7.4 \
  --disable-libiconv \
  --with-unixodbc=<prefix>
```

MinGW configure:

```bash
./configure \
  --build=<build-triple> \
  --host=x86_64-w64-mingw32 \
  --prefix=<prefix> \
  --enable-shared \
  --disable-static \
  --disable-server \
  --disable-apps \
  --with-tdsver=7.4 \
  --disable-libiconv \
  --disable-odbc
```

Build and install:

```bash
make -j <jobs>
make install
```

### MariaDB Connector/C

Source:

```text
https://dlm.mariadb.com/4751056/Connectors/c/connector-c-3.4.9/mariadb-connector-c-3.4.9-src.tar.gz
```

CMake:

```bash
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DWITH_SSL=OPENSSL \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_EXTERNAL_ZLIB=OFF \
  -DWITH_CURL=OFF \
  -DWITH_MYSQLCOMPAT=ON \
  -DWITH_STATIC=OFF
```

MinGW uses Schannel instead of OpenSSL:

```bash
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DWITH_SSL=SCHANNEL \
  -DWITH_UNIT_TESTS=OFF \
  -DWITH_EXTERNAL_ZLIB=OFF \
  -DWITH_CURL=OFF \
  -DWITH_MYSQLCOMPAT=ON \
  -DWITH_STATIC=OFF
```

Build and install:

```bash
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### hiredis

Source:

```text
https://github.com/redis/hiredis/archive/refs/tags/v1.4.0.tar.gz
```

CMake:

```bash
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DENABLE_SSL=OFF \
  -DDISABLE_TESTS=ON
```

Build and install:

```bash
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### mongo-c-driver

Source:

```text
https://github.com/mongodb/mongo-c-driver/releases/download/1.30.8/mongo-c-driver-1.30.8.tar.gz
```

CMake:

```bash
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DENABLE_SHARED=ON \
  -DENABLE_STATIC=OFF \
  -DENABLE_TESTS=OFF \
  -DENABLE_EXAMPLES=OFF \
  -DENABLE_MAN_PAGES=OFF \
  -DENABLE_HTML_DOCS=OFF \
  -DENABLE_SSL=OPENSSL \
  -DENABLE_SASL=OFF \
  -DENABLE_SNAPPY=OFF \
  -DENABLE_ZLIB=BUNDLED \
  -DENABLE_ZSTD=OFF \
  -DENABLE_CLIENT_SIDE_ENCRYPTION=OFF
```

MinGW uses the Windows TLS backend:

```bash
-DENABLE_SSL=WINDOWS
```

Build and install:

```bash
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

## Cleanup And Validation

After install, the package script:

- copies MinGW DLLs into `bin/`
- removes ordinary `.a` and `.la` files
- preserves MinGW `*.dll.a` import libraries
- removes bulky upstream docs/man/info directories
- patches Linux ELF RPATHs to use the packaged `lib/`
- validates representative headers and shared libraries
- normalizes final package permissions before archiving

## Vendor SDK Notes

Oracle Instant Client can be downloaded and used locally to build Oracle-related FDWs, but it should not be redistributed inside this package.

Useful Oracle archives:

```text
https://download.oracle.com/otn_software/nt/instantclient/2326200/instantclient-sdk-windows.x64-23.26.2.0.0.zip
https://download.oracle.com/otn_software/nt/instantclient/2326200/instantclient-basic-windows.x64-23.26.2.0.0.zip
https://download.oracle.com/otn_software/linux/instantclient/2122000/instantclient-basic-linux.x64-21.22.0.0.0dbru.zip
https://download.oracle.com/otn_software/linux/instantclient/2122000/instantclient-sdk-linux.x64-21.22.0.0.0dbru.zip
https://download.oracle.com/otn_software/linux/instantclient/2326200/instantclient-basic-linux.arm64-23.26.2.0.0.zip
https://download.oracle.com/otn_software/linux/instantclient/2326200/instantclient-sdk-linux.arm64-23.26.2.0.0.zip
```

IBM DB2 CLI/ODBC packages are also vendor binaries and should be provided separately by the FDW build that needs them:

```text
https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/v11.5.9/linuxx64_odbc_cli.tar.gz
https://public.dhe.ibm.com/ibmdl/export/pub/software/data/db2/drivers/odbc_cli/v11.5.9/ntx64_odbc_cli.zip
```
