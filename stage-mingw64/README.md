# stage-mingw64

`stage-mingw64` adds a first-pass Windows GNU target layer on top of the
`llvm-18.1.8` image.

The stage can produce Linux-hosted overlays for `x86_64`, `aarch64`, `riscv64`,
and `loongarch64`. The Windows target remains `x86_64-w64-windows-gnu`.
It uses the prebuilt MinGW GCC package as the source for headers, CRT objects,
import libraries, and temporary bootstrap tools. Binutils is built from GNU
source for the public `x86_64-w64-windows-gnu` triple. The final overlay keeps
a clean Windows GNU target layout and builds the LLVM runtimes in bootstrap
order:

- `compiler-rt` builtins-only
- `libunwind`
- `libc++abi`
- `libc++`
- full `compiler-rt` with builtins, profile, sanitizers, and CRT enabled when
  supported by LLVM for the Windows GNU target

It then exposes clang driver entries that target Windows:

- `x86_64-w64-windows-gnu-clang-gcc`
- `x86_64-w64-windows-gnu-clang-g++`

The build output is a rootfs overlay under:

```text
stage-mingw64/build/out/x86_64
stage-mingw64/build/out/aarch64
stage-mingw64/build/out/riscv64
stage-mingw64/build/out/loongarch64
```

## Layout

The overlay installs:

```text
/opt/x86_64-w64-windows-gnu
/opt/x86_64-w64-windows-gnu/sysroot
/opt/x86_64-w64-windows-gnu/bin
/opt/x86_64-w64-windows-gnu/lib
/opt/x86_64-w64-windows-gnu/include/c++/v1
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-gcc
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-g++
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-gcc.cfg
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-g++.cfg
```

`/opt/x86_64-w64-windows-gnu/bin` contains GNU binutils built by this stage
and the Windows runtime DLLs copied from the seed sysroot, such as
`libwinpthread-1.dll`, `libgcc_s_seh-1.dll`, and `libstdc++-6.dll`.

The clang config files use `<CFGDIR>` so the overlay remains relocatable inside
the container image. The sysroot is available directly at:

```text
/opt/x86_64-w64-windows-gnu/sysroot
```

## Build

```bash
./stage-mingw64/build.sh --arch=x86_64 --clean --pull --jobs=4
```

Replace `x86_64` with `aarch64`, `riscv64`, or `loongarch64` to build the same
Windows GNU target tools hosted by that Linux architecture.

The build container itself stays `linux/amd64`; non-x86 host outputs are built
as Canadian cross builds.

By default the build uses:

```text
ghcr.io/zarraxx/develop_suit:llvm-18.1.8
```

and downloads:

```text
https://github.com/zarraxx/package_builder/releases/download/compiler-mingw32-gcc-15.2.0/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz
https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.xz
https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz
```

GNU also publishes the same binutils release as:

```text
https://ftp.gnu.org/gnu/binutils/binutils-2.46.0.tar.zst
```

If the archive already exists locally, pass it explicitly:

```bash
./stage-mingw64/build.sh \
  --arch=x86_64 \
  --mingw-archive=/path/to/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz
```

## Image

```bash
./stage-mingw64/image.sh --arch=x86_64
```

The default local image tag is:

```text
develop_suit:llvm-with-mingw64-18.1.8
```

The image smoke test compiles C and C++ programs into `PE32+ x86-64` Windows
executables under `stage-mingw64/build/smoke/<arch>`. It does not run the
Windows binaries.

## Binutils

Each host-arch stage builds GNU binutils with:

```text
build  = x86_64-unknown-linux-gnu
host   = <arch>-unknown-linux-gnu
target = x86_64-w64-windows-gnu
```

Binutils 2.46.0 does not accept `x86_64-w64-windows-gnu` out of the box, so the
stage applies `mount_root/patches/binutils-2.46.0-windows-gnu.patch` with the
standard `patch` command. The patch maps the triple to the same PE/COFF backend
used for MinGW while keeping final tool names under `x86_64-w64-windows-gnu-*`.

The binutils flow is kept in:

```text
stage-mingw64/mount_root/build_binutils.sh
```
