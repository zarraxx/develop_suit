# boost package

`boost` builds a distributable Boost prefix for later CGAL/SFCGAL builds. It
contains the Boost headers plus the compiled shared libraries that CGAL-adjacent
packages commonly need.

## Boundary

This package builds Boost only. It does not build CGAL, GMP, MPFR, Eigen, or
other geometry stack dependencies. It also does not consume or extend
`python_dependencies` or `postgresql_dependencies`; it is an independent prefix
built with the staged LLVM/clang toolchain and target sysroot.

Supported targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

The build is treated as cross-compilation for every target, including
`x86_64-unknown-linux-gnu`.

## Build

Default image:

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

Build the default Boost 1.84.0 package:

```sh
./packages/boost/build.sh --target=x86_64 --clean --jobs=4
```

Build another target:

```sh
./packages/boost/build.sh --target=aarch64 --boost-version=1.84.0 --jobs=4
./packages/boost/build.sh --target=x86_64-w64-windows-gnu --jobs=4
```

Use a local upstream source archive:

```sh
./packages/boost/build.sh \
  --target=x86_64 \
  --boost-archive=/path/to/boost_1_84_0.tar.bz2
```

## Output

```text
packages/boost/build/out/boost-<version>-<triple>
packages/boost/build/dist/boost-<version>-<triple>.tar.xz
```

For Boost 1.84.0 on x86_64 Linux:

```text
packages/boost/build/dist/boost-1.84.0-x86_64-unknown-linux-gnu.tar.xz
```

Release asset names should use the same stem:

```text
boost-<version>-<triple>
boost-<version>-<triple>.tar.xz
```

## Boost.Build Configure

Source:

```text
https://archives.boost.io/release/<version>/source/boost_<version_with_underscores>.tar.bz2
```

The container generates a Boost.Build `user-config.jam` with a gcc-compatible
toolset backed by the staged clang C++ compiler:

```jam
using gcc : develop_suit : <target-clang++> :
  <archiver><target-ar>
  <ranlib><target-ranlib>
  <compileflags>"<target cpp/cxx flags>"
  <linkflags>"<target linker flags>"
  ;
```

If the LLVM SDK does not provide `<triple>-clang-g++`, the package writes a
small clang wrapper from `mount_root/templates/clang-wrapper.in` that injects
`--target=<triple>`, `--sysroot=<sysroot>`, and `-fuse-ld=lld`.

Boost.Build itself is bootstrapped with the build-machine clang:

```sh
./bootstrap.sh --prefix=<prefix> --with-toolset=clang
```

## Boost.Build Install

The installed Boost libraries are:

- `atomic`
- `chrono`
- `date_time`
- `filesystem`
- `serialization`
- `system`
- `thread`

Linux parameters:

```sh
./b2 --user-config=<user-config.jam> --prefix=<prefix> \
  --build-dir=<build-dir> --stagedir=<stage-dir> --layout=system \
  -j <jobs> \
  toolset=gcc-develop_suit target-os=linux binary-format=elf \
  address-model=64 variant=release link=shared runtime-link=shared \
  threading=multi threadapi=pthread \
  --with-atomic --with-chrono --with-date_time --with-filesystem \
  --with-serialization --with-system --with-thread \
  install
```

MinGW parameters:

```sh
./b2 --user-config=<user-config.jam> --prefix=<prefix> \
  --build-dir=<build-dir> --stagedir=<stage-dir> --layout=system \
  -j <jobs> \
  toolset=gcc-develop_suit target-os=windows binary-format=pe \
  address-model=64 variant=release link=shared runtime-link=shared \
  threading=multi threadapi=win32 \
  --with-atomic --with-chrono --with-date_time --with-filesystem \
  --with-serialization --with-system --with-thread \
  install
```

After install the package removes ordinary `.a` and `.la` files, preserves
MinGW `*.dll.a` import libraries, copies MinGW DLLs from `lib/` to `bin/` when
present, copies the Linux LLVM C++ runtime libraries into `lib/`, patches Linux
ELF RUNPATH entries to be `$ORIGIN`-relative, renders `README.boost`, and
validates the installed headers plus each requested Boost shared library.
