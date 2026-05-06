# stage-mingw64

`stage-mingw64` adds a first-pass Windows GNU target layer on top of the
`llvm-18.1.8` image.

The initial version intentionally supports only an `x86_64` Linux host output.
It uses the prebuilt MinGW GCC package as the source for headers, CRT objects,
import libraries, `libgcc`, and `libstdc++`, then exposes clang driver entries
that target Windows:

- `x86_64-w64-windows-gnu-clang-gcc`
- `x86_64-w64-windows-gnu-clang-g++`

The build output is a rootfs overlay under:

```text
stage-mingw64/build/out/x86_64
```

## Layout

The overlay installs:

```text
/opt/x86_64-w64-windows-gnu
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-gcc
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-g++
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-gcc.cfg
/opt/llvm-18.1.8/bin/x86_64-w64-windows-gnu-clang-g++.cfg
```

The clang config files use `<CFGDIR>` so the overlay remains relocatable inside
the container image.

## Build

```bash
./stage-mingw64/build.sh --arch=x86_64 --clean --pull --jobs=4
```

By default the build uses:

```text
ghcr.io/zarraxx/develop_suit:llvm-18.1.8
```

and downloads:

```text
https://github.com/zarraxx/package_builder/releases/download/compiler-mingw32-gcc-15.2.0/compiler-mingw32-gcc-15.2.0-linux-x86_64.tar.gz
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

The image smoke test compiles C and C++ programs into `PE32+ x86-64` Windows
executables. It does not run the Windows binaries.

## Next Steps

This first pass deliberately uses the GCC-provided MinGW runtime:

- `libgcc`
- `libstdc++`

The next runtime stage can build and overlay the LLVM runtime stack for
`x86_64-w64-windows-gnu`:

- `compiler-rt`
- `libunwind`
- `libc++abi`
- `libc++`

That should follow the same runtime overlay pattern used by `stage_llvm`, but
install into the target layout under `/opt/x86_64-w64-windows-gnu`
and/or clang's resource directory as appropriate.

## Canadian Binutils Plan

For a full traditional GNU MinGW toolchain on each Linux host architecture,
build binutils with:

```text
build  = x86_64-unknown-linux-gnu
host   = <arch>-unknown-linux-gnu
target = x86_64-w64-windows-gnu
```

Example for a future `aarch64` hosted MinGW binutils build:

```bash
../binutils/configure \
  --build=x86_64-unknown-linux-gnu \
  --host=aarch64-unknown-linux-gnu \
  --target=x86_64-w64-windows-gnu \
  --prefix=/opt/x86_64-w64-windows-gnu
```

That expansion is intentionally left out of the first x86_64-only version.
