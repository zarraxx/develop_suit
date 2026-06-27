# V8 package

`packages/v8` builds a reusable V8 SDK prefix through the official
`depot_tools`, `fetch v8`, GN, and Ninja flow. The package is intended for
PostgreSQL PL/V8 builds and other embedders that need V8 headers, shared V8
libraries, and a matching `d8` smoke-test shell.

## Responsibility Boundary

This package owns the V8 JavaScript engine checkout/build, public headers,
shared component libraries, `d8`, and basic discovery metadata. It does not
build PL/V8 or PostgreSQL.

The package currently publishes Linux targets only. Official V8 GN Windows
builds use the MSVC/clang-cl ABI, so this package does not publish an
`x86_64-w64-windows-gnu` MinGW artifact.

## Inputs

- Upstream V8 checkout: `https://chromium.googlesource.com/v8/v8`
- Depot tools checkout: `packages/v8/depot_tools` when present, otherwise
  cloned into `cache/depot_tools`
- Default V8 version/tag: `11.6.189.4`
- Default image: `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- LLVM toolchain version: `18.1.8`

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`

The package script accepts the common package knobs `--target`/`--arch`,
`--clean`, and `--jobs=<n>`.

## Build Commands

```bash
./packages/v8/build.sh --target=x86_64 --jobs=12
./packages/v8/build.sh --target=aarch64 --jobs=12
./packages/v8/build.sh --target=riscv64 --jobs=12
./packages/v8/build.sh --target=loongarch64 --jobs=12
./packages/v8/build.sh --target=x86_64 --v8-version=11.6.189.4 --clean --jobs=12
```

## Upstream Configure And Build

The container obtains V8 with:

```bash
fetch --nohooks v8
git checkout --detach <version>
gclient sync --with_branch_heads --with_tags -D --jobs <jobs>
```

It then writes `args.gn` with the important parameters:

```gn
is_debug = false
is_component_build = true
is_clang = true
target_os = "linux"
target_cpu = "<x64|arm64|riscv64|loong64>"
v8_target_cpu = "<x64|arm64|riscv64|loong64>"
v8_enable_i18n_support = false
v8_use_external_startup_data = false
v8_enable_sandbox = false
use_custom_libcxx = false
use_sysroot = false
cc = "/opt/llvm-18.1.8/bin/clang"
cxx = "/opt/llvm-18.1.8/bin/clang++"
ar = "/opt/llvm-18.1.8/bin/llvm-ar"
```

Linux cross builds add `--target=<triple>` and `--sysroot=<sysroot>` through
GN `extra_cflags` and `extra_ldflags`. The riscv64 build also adds
`-mno-relax` and `-Wl,--no-relax`.

The actual build command is:

```bash
gn gen <out-dir>
ninja -C <out-dir> -j <jobs> d8
```

`is_component_build=true` makes the distributable output dynamic/shared instead
of the old split static archive layout.

## Install And Validation Steps

The upstream project has no package install step for this layout, so this
package installs files manually:

- Copies `include/*` to `include/`.
- Copies generated `libv8*.so`, `libcppgc*.so`, and `libchrome_zlib*.so` files
  to `lib/`.
- Copies `d8` to `bin/`.
- Writes `lib/pkgconfig/v8.pc`.
- Writes `lib/cmake/V8/V8Config.cmake`.
- Validates public headers, shared libraries, `d8`, pkg-config metadata, and
  CMake metadata.
- Patches Linux ELF rpaths so installed tools and shared libraries can find
  sibling package libraries.

For the native x86_64 Linux build, the container runs a small `d8` JavaScript
smoke test immediately after the build. Other targets are validated by the
package test job on a matching runner or qemu-enabled Docker platform.

## Output Layout

```text
v8-<version>-<triple>/
  README.v8
  bin/
    d8
  include/
  lib/
    libv8*.so
    libcppgc*.so
    libchrome_zlib*.so
    pkgconfig/v8.pc
    cmake/V8/V8Config.cmake
```

## Release Artifact

```text
v8-<version>-<triple>.tar.xz
```
