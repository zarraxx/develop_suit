# clang package

`packages/clang` builds the distributable clang toolchain package on top of
the existing LLVM SDK packages.

This package should not rebuild the LLVM SDK dependency prefix. It consumes:

- `llvm_dependencies-<triple>.tar.xz`
- `llvmsdk-<version>-<triple>.tar.xz`
- `native-clang-stage0-<version>-x86_64-unknown-linux-gnu.tar.xz`
- `libcxx-<version>-<triple>.tar.xz` for every supported runtime target

The final package name is:

```text
clang-<version>-<triple>.tar.xz
```

The top-level unpacked directory is:

```text
clang-<version>-<triple>/
```

## Boundary

This package owns:

- `clang`
- `clang++`
- `lld`
- `clang-tools-extra`
- target driver symlinks and `.cfg` files
- final copy-and-run layout assembly

This package does not own:

- LLVM SDK libraries and tools built by `packages/llvm`
- external dependency prefixes built by `packages/llvm_dependencies`
- standalone C++ runtime packages built by `packages/libcxx`
- Linux sysroots
- host-arch MinGW sysroot/binutils prefixes
- stage rootfs image construction

## Targets

Supported package targets follow the repository package target set:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

All targets are treated as cross-compilation targets, including x86_64 Linux.

## Versioning

The package unit name defaults to the package directory basename:

```sh
unit_name="$(basename packages/clang)"
```

The package version follows the LLVM version being built. This mirrors the
LLVM SDK naming model:

```text
clang-18.1.8-x86_64-unknown-linux-gnu.tar.xz
clang-22.1.5-loongarch64-unknown-linux-gnu.tar.xz
```

## Build Plan

The clang package build is split into two workflow phases.

### Phase 1: native stage0 clang

Build one native Linux x86_64 bootstrap clang package for the selected LLVM
version.

This bootstrap clang only needs the backend set required to build the final
package targets:

- X86
- AArch64
- RISCV
- LoongArch

The native stage0 artifact is used by the final target matrix so every matrix
job does not rebuild the same host-side clang tools.

Expected helper scripts:

```text
packages/clang/build_native_stage0.sh
packages/clang/mount_root/container_stage0.sh
```

Build command:

```sh
./packages/clang/build_native_stage0.sh \
  --llvm-version=18.1.8 \
  --llvmsdk-archive=packages/llvm/build/dist/llvmsdk-18.1.8-x86_64-unknown-linux-gnu.tar.xz \
  --clean \
  --jobs=4
```

The stage0 build uses the same-version host native `llvmsdk` as the installed
LLVM provider. It builds `clang` and `lld` standalone against:

```text
<llvmsdk>/lib/cmake/llvm/LLVMConfig.cmake
<llvmsdk>/bin/llvm-config
<llvmsdk>/bin/llvm-tblgen
<llvmsdk>/lib/libLLVM.so
```

It does not rebuild LLVM itself. The bootstrap C/C++ compiler still comes from
the build image, normally `/opt/llvm-18.1.8/bin/clang`.

### Phase 2: target matrix

Run a five-target matrix and build the final clang package for each supported
target.

The final clang build should enable all available stable and experimental LLVM
targets for user-facing clang/lld usage.

The installed clang defaults match the staged LLVM toolchain policy:

- default linker: `lld`
- default C++ standard library: `libc++`
- default runtime library: `compiler-rt`
- default unwind library: `libunwind`
- default objcopy: `llvm-objcopy`
- `libclang.so` and `libclang-cpp.so` are required package outputs

Expected helper scripts:

```text
packages/clang/build.sh
packages/clang/mount_root/container_clang.sh
```

Build command:

```sh
./packages/clang/build.sh \
  --target=x86_64 \
  --llvm-version=22.1.5 \
  --clean \
  --jobs=4
```

The final package is assembled from the same-target `llvmsdk`, the native
x86_64 Linux `llvmsdk` for build-time tools, the native x86_64 Linux stage0
clang, and all five `libcxx` runtime packages.

The output clang prefix intentionally does not contain Linux or MinGW sysroots.
Its driver cfg files expect the container-style sibling layout:

```text
/opt/clang-<version>-<host-triple>/bin/clang
/opt/sysroot/<linux-triple>
/opt/x86_64-w64-windows-gnu/sysroot
/opt/x86_64-w64-windows-gnu/bin
```

From `bin/*.cfg`, Linux sysroots are referenced through:

```text
<CFGDIR>/../../sysroot/<linux-triple>
```

The Windows GNU target is referenced through:

```text
<CFGDIR>/../../x86_64-w64-windows-gnu/sysroot
<CFGDIR>/../../x86_64-w64-windows-gnu/bin
```

This keeps clang versions replaceable while allowing Linux sysroots and the
host-arch MinGW sysroot/binutils prefix to be shared.

## C++ Runtime Package

The C++ runtime is intentionally a separate package:

```text
libcxx-<version>-<triple>.tar.xz
```

It contains only the runtime-facing files needed by consumers:

- `bin/`
- `lib/`
- `include/`
- target runtime metadata needed for clang configuration

It must not contain the rest of LLVM.

Expected helper script:

```text
packages/clang/build_libcxx.sh
packages/clang/mount_root/container_libcxx.sh
```

Build command:

```sh
./packages/clang/build_libcxx.sh \
  --target=x86_64 \
  --llvm-version=22.1.5 \
  --native-stage0-archive=packages/clang/build/dist/native-clang-stage0-22.1.5-x86_64-unknown-linux-gnu.tar.xz \
  --clean \
  --jobs=8
```

The runtime build order is:

1. Build `compiler-rt` builtins.
2. Build `libunwind`, `libcxxabi`, and `libcxx`.
3. Build the remaining `compiler-rt` runtime libraries.

The final clang package consumes the libcxx package and includes enough runtime
files beside clang/lld to be copy-and-run.

## Expected Inputs

For each target matrix job:

```text
llvm_dependencies-<triple>.tar.xz
llvmsdk-<version>-<triple>.tar.xz
libcxx-<version>-x86_64-unknown-linux-gnu.tar.xz
libcxx-<version>-aarch64-unknown-linux-gnu.tar.xz
libcxx-<version>-riscv64-unknown-linux-gnu.tar.xz
libcxx-<version>-loongarch64-unknown-linux-gnu.tar.xz
libcxx-<version>-x86_64-w64-windows-gnu.tar.xz
native-clang-stage0-<version>-x86_64-unknown-linux-gnu.tar.xz
```

`mingw64-sysroot-<host-triple>.tar.xz` may be provided to `build.sh` for local
validation, but it is not copied into the final clang tarball.

## Expected Outputs

```text
packages/clang/build/out/clang-<version>-<triple>
packages/clang/build/dist/clang-<version>-<triple>.tar.xz
```

For the standalone C++ runtime package:

```text
packages/clang/build/out/libcxx-<version>-<triple>
packages/clang/build/dist/libcxx-<version>-<triple>.tar.xz
```

For the native stage0 bootstrap artifact:

```text
packages/clang/build/out/native-clang-stage0-<version>-x86_64-unknown-linux-gnu
packages/clang/build/dist/native-clang-stage0-<version>-x86_64-unknown-linux-gnu.tar.xz
```

## Driver Layout

The final package creates clang driver symlinks and cfg files in `bin/`:

```text
<linux-triple>-clang-gcc -> clang
<linux-triple>-clang-g++ -> clang++
x86_64-w64-windows-gnu-clang-gcc -> clang
x86_64-w64-windows-gnu-clang-g++ -> clang++
```

Linux targets also get LLVM binutils-style symlinks:

```text
<linux-triple>-ar -> llvm-ar
<linux-triple>-nm -> llvm-nm
<linux-triple>-objcopy -> llvm-objcopy
<linux-triple>-ranlib -> llvm-ranlib
<linux-triple>-strip -> llvm-strip
```

The MinGW target keeps binutils in the external host-arch
`x86_64-w64-windows-gnu` prefix because those tools are host-architecture
specific.
