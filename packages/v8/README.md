# V8 package

`packages/v8` builds a reusable V8 prefix from
[`bnoordhuis/v8-cmake`](https://github.com/bnoordhuis/v8-cmake). The package is
intended for PostgreSQL PL/V8 builds.

## Responsibility Boundary

This package owns the V8 JavaScript engine headers, static V8 libraries, the
`d8` shell binary, and basic discovery metadata. It does not build PL/V8 or
PostgreSQL.

The current implementation supports Linux x86_64, Linux aarch64, Linux riscv64,
Linux loongarch64, and x86_64 MinGW targets. For aarch64, riscv64, loongarch64,
and MinGW, the package builds native host generator tools before the target
build so CMake custom commands can run
`torque`, `mksnapshot`, and `bytecode_builtins_list_generator` on the build
host.

## Inputs

- v8-cmake source archive:
  `https://github.com/bnoordhuis/v8-cmake/archive/refs/tags/<version>.tar.gz`
- Default v8-cmake/V8 version: `11.6.189.4`
- Default image: `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- LLVM toolchain version: `18.1.8`

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

The package script accepts the common package knobs `--target`/`--arch`,
`--clean`, and `--jobs=<n>`.

## Build Commands

```bash
./packages/v8/build.sh --target=x86_64 --jobs=12
./packages/v8/build.sh --target=aarch64 --jobs=12
./packages/v8/build.sh --target=riscv64 --jobs=12
./packages/v8/build.sh --target=loongarch64 --jobs=12
./packages/v8/build.sh --target=mingw64 --jobs=12
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

For MinGW, the same configure flow uses `CMAKE_SYSTEM_NAME=Windows`, the
`x86_64-w64-windows-gnu` sysroot, and disables
`V8_ENABLE_SYSTEM_INSTRUMENTATION` because the packaged MinGW SDK does not ship
the ETW TraceLogging headers required by that optional Windows instrumentation
path. Linux builds keep `-fPIC`, pthread flags, and rpath-link flags; MinGW
builds omit those Linux-only flags.

For riscv64, the configure flow also adds `-mno-relax` to C/C++ flags and
`-Wl,--no-relax` to linker flags to avoid `R_RISCV_ALIGN` linker padding
failures when producing the cross-built `d8` binary.

It then builds:

```bash
cmake --build <build> --target v8_snapshot --parallel <jobs>
cmake --build <build> --target d8 --parallel <jobs>
```

The `v8_snapshot` target runs `mksnapshot` to generate `embedded.S` and
`snapshot.cc`. For aarch64, riscv64, loongarch64, and MinGW, `mksnapshot` is
built as a host tool and invoked from the target build through `PATH`. The `d8`
target is run as a smoke test only for the native x86_64 Linux package;
non-native and MinGW packages validate installed headers and metadata but skip
execution.

## Install And Validation Steps

The upstream project has no `install()` rules, so the package installs files
manually:

- Copies `v8/include/*` to `include/`.
- Copies v8-cmake static libraries to `lib/`.
- Copies `d8`/`d8.exe` to `bin/`.
- Writes `lib/pkgconfig/v8.pc`.
- Writes `lib/cmake/V8/V8Config.cmake`.
- Validates public headers, static libraries, `d8`, pkg-config metadata, and
  CMake metadata.

The package intentionally keeps the V8 static libraries. This differs from the
repository's normal preference for dynamic distributable libraries, but
v8-cmake produces split static V8 libraries and PL/V8 can consume static V8
inputs. The package does not ship V8 shared libraries (`.so`/`.dll`) because
the current v8-cmake flow in this repository produces and packages static V8
archives. The added `d8` binary is included for smoke testing and embedding
validation, not as proof of a dynamic V8 SDK.

## Output Layout

```text
v8-<version>-<triple>/
  README.v8
  bin/
    d8 | d8.exe
  include/
  lib/
    libv8_*.a
    pkgconfig/v8.pc
    cmake/V8/V8Config.cmake
```

## Release Artifact

```text
v8-<version>-<triple>.tar.xz
```
