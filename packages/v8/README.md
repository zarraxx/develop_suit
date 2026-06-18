# V8 package

`packages/v8` builds a reusable V8 prefix from
[`bnoordhuis/v8-cmake`](https://github.com/bnoordhuis/v8-cmake). The package is
intended for PostgreSQL PL/V8 builds.

## Responsibility Boundary

This package owns the V8 JavaScript engine headers, static V8 libraries, and
basic discovery metadata. It does not build PL/V8 or PostgreSQL.

The current implementation supports only `x86_64-unknown-linux-gnu`. The
upstream `v8-cmake` build can compile and run V8 generator tools on x86_64, but
cross targets need additional host-tool patches for `torque` and `mksnapshot`.

## Inputs

- v8-cmake source archive:
  `https://github.com/bnoordhuis/v8-cmake/archive/refs/tags/<version>.tar.gz`
- Default v8-cmake/V8 version: `11.6.189.4`
- Default image: `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- LLVM toolchain version: `18.1.8`

## Supported Targets

- `x86_64-unknown-linux-gnu`

The package script accepts the common package knobs `--target`/`--arch`,
`--clean`, and `--jobs=<n>`.

## Build Commands

```bash
./packages/v8/build.sh --target=x86_64 --jobs=12
./packages/v8/build.sh --target=x86_64 --v8-version=11.6.189.4 --clean --jobs=12
```

A local source archive can be supplied with:

```bash
./packages/v8/build.sh \
  --target=x86_64 \
  --v8-version=11.6.189.4 \
  --v8-archive=/path/to/v8-cmake-11.6.189.4.tar.gz
```

## Upstream Configure And Build

The container configures v8-cmake with:

```bash
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
  -DCMAKE_C_FLAGS="-fPIC -pthread -Wno-unused-command-line-argument" \
  -DCMAKE_CXX_FLAGS="-fPIC -pthread -Wno-invalid-offsetof -Wno-deprecated-declarations -Wno-unused-command-line-argument" \
  -DCMAKE_EXE_LINKER_FLAGS="-pthread -Wl,-rpath-link,<sysroot>/usr/lib ..." \
  -DV8_ENABLE_I18N=OFF \
  -DPYTHON_EXECUTABLE=<python3>
```

It then builds:

```bash
cmake --build <build> --target v8_snapshot --parallel <jobs>
cmake --build <build> --target d8 --parallel <jobs>
```

The `v8_snapshot` target runs `mksnapshot` to generate `embedded.S` and
`snapshot.cc`. The `d8` target is used only as a smoke test.

## Install And Validation Steps

The upstream project has no `install()` rules, so the package installs files
manually:

- Copies `v8/include/*` to `include/`.
- Copies v8-cmake static libraries to `lib/`.
- Writes `lib/pkgconfig/v8.pc`.
- Writes `lib/cmake/V8/V8Config.cmake`.
- Runs `d8 -e "if (6 * 7 !== 42) throw new Error('bad arithmetic')"`.
- Validates public headers, static libraries, pkg-config metadata, and CMake
  metadata.

The package intentionally keeps the V8 static libraries. This differs from the
repository's normal preference for dynamic distributable libraries, but
v8-cmake produces split static V8 libraries and PL/V8 can consume static V8
inputs.

## Output Layout

```text
v8-<version>-x86_64-unknown-linux-gnu/
  README.v8
  include/
  lib/
    libv8_*.a
    pkgconfig/v8.pc
    cmake/V8/V8Config.cmake
```

## Release Artifact

```text
v8-<version>-x86_64-unknown-linux-gnu.tar.xz
```
