# python package

`python` builds a distributable CPython prefix on top of
`python_dependencies-<triple>` or `pyhton_dependencies-3-<triple>`. The final
tarball contains both CPython and the dependency libraries needed by that
interpreter.

## Boundary

This package builds CPython only. It consumes the dependency prefix produced by
`packages/python_dependencies`; it does not rebuild zlib, OpenSSL, libffi,
sqlite, readline, ncurses, expat, libuuid, gdbm, libxslt, or ICU.

Supported targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

## Build

```sh
./packages/python/build.sh --target=x86_64 --python-version=3.14.5 --clean --jobs=4
```

Explicit dependency input:

```sh
./packages/python/build.sh \
  --target=x86_64 \
  --python-version=3.14.5 \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

## Output

```text
packages/python/build/out/python-<version>-<triple>
packages/python/build/dist/python-<version>-<triple>.tar.xz
```

For Python 3.14.5 on x86_64 Linux:

```text
packages/python/build/dist/python-3.14.5-x86_64-unknown-linux-gnu.tar.xz
```

GitHub Actions publishes one release per Python version and target triple. The
release tag and asset name are the same stem:

```text
python-<version>-<triple>
python-<version>-<triple>.tar.xz
```

Examples:

```text
python-3.14.5-x86_64-unknown-linux-gnu
python-3.14.5-x86_64-w64-windows-gnu
```

## CPython Configure

Source:

```text
https://www.python.org/ftp/python/<version>/Python-<version>.tar.xz
```

The package treats the build as cross-compilation even for x86_64 Linux. It
first builds a same-version host helper Python, then configures target CPython
with:

```sh
./configure --build=<build> --host=<target> --prefix=<prefix> \
  --enable-shared \
  --with-build-python=<host-build-python> \
  --with-openssl=<prefix> \
  --with-system-expat \
  --with-ensurepip=no
```

Dependency discovery is routed through the copied dependency prefix using
`CPPFLAGS`, `LDFLAGS`, `PKG_CONFIG_LIBDIR`, and explicit library variables for
uuid, sqlite, gdbm, readline, zlib, bzip2, lzma, zstd, and ffi.

After install, ordinary `.a` and `.la` files are removed, Linux ELF rpaths are
patched to `$ORIGIN`-relative paths, and the x86_64 build runs an import smoke
test for core extension modules.

For MinGW, the package follows the MSYS2 `cpython-mingw` direction. It uses the
MSYS2 MinGW CPython branch, regenerates `configure` before the container build,
uses the Windows GNU sysroot resource headers for `llvm-windres`, keeps MinGW
`*.dll.a` import libraries, and validates the Windows executable layout.
