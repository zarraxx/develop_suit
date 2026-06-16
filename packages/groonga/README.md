# groonga package

`groonga` builds a reusable Groonga dependency prefix for PGroonga builds.

## Boundary

This package builds:

- xxHash
- msgpack-c
- Groonga

It intentionally does not build PostgreSQL or PGroonga itself. A PGroonga
package should consume this archive together with the matching PostgreSQL
package or PostgreSQL dependency prefix.

## Inputs

No binary package input is required. Source archives are downloaded into the
shared repository `cache/` directory.

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

```sh
./packages/groonga/build.sh --target=x86_64 --clean --jobs=4
./packages/groonga/build.sh --target=loongarch64 --clean --jobs=4
./packages/groonga/build.sh --target=mingw64 --clean --jobs=4
```

Expected output:

```text
packages/groonga/build/out/groonga-<groonga-version>-<triple>
packages/groonga/build/dist/groonga-<groonga-version>-<triple>.tar.xz
```

## Release Artifact Names

Default versions produce:

```text
groonga-16.0.5-<triple>.tar.xz
```

## Upstream Sources

xxHash:

```text
https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.3.tar.gz
```

msgpack-c:

```text
https://github.com/msgpack/msgpack-c/releases/download/c-6.1.0/msgpack-c-6.1.0.tar.gz
```

Groonga:

```text
https://packages.groonga.org/source/groonga/groonga-16.0.5.tar.gz
```

## Build Direction

1. Build xxHash as a shared library with CMake.
2. Build msgpack-c as a shared library with CMake.
3. Add `msgpack.pc -> msgpack-c.pc` for consumers that search either name.
4. Build Groonga as a shared library against the staged xxHash and msgpack-c.
5. Disable unrelated optional Groonga integrations so PGroonga gets a compact,
   deterministic dependency prefix.
6. Remove ordinary `.a` and `.la` files; preserve MinGW `*.dll.a` import
   libraries.
7. Patch Linux ELF RUNPATH entries to be `$ORIGIN`-relative.

## Component Commands

### xxHash 0.8.3

```sh
cmake -S <src>/cmake_unofficial -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DXXHASH_BUNDLED_MODE=OFF \
  -DXXHASH_BUILD_XXHSUM=ON
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### msgpack-c 6.1.0

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DMSGPACK_ENABLE_SHARED=ON \
  -DMSGPACK_ENABLE_STATIC=OFF \
  -DMSGPACK_BUILD_TESTS=OFF \
  -DMSGPACK_BUILD_EXAMPLES=OFF
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### Groonga 16.0.5

```sh
cmake -S <src> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DCMAKE_BUILD_TYPE=Release \
  -DBUILD_SHARED_LIBS=ON \
  -DGRN_WITH_MESSAGE_PACK=system \
  -DGRN_WITH_XXHASH=system \
  -DGRN_WITH_BUNDLED_ONIGMO=ON \
  -DGRN_WITH_DOC=OFF \
  -DGRN_WITH_BENCHMARKS=OFF \
  -DGRN_WITH_EXAMPLES=OFF \
  -DGRN_WITH_TOOLS=OFF
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

The actual package script also disables optional Groonga integrations that are
not needed by PGroonga, such as Arrow, RapidJSON, MeCab, KyTea, zstd, LZ4, H3,
llama.cpp, USearch, Faiss, curl, and related bundled downloads.
