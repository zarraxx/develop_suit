# python package

`python` builds a distributable CPython prefix on top of
`python_dependencies-<triple>` or `pyhton_dependencies-3-<triple>`. The final
tarball contains both CPython and the dependency libraries needed by that
interpreter.

## Boundary

This package builds CPython only. It consumes the dependency prefix produced by
`packages/python_dependencies`; it does not rebuild zlib, OpenSSL, libffi,
sqlite, readline, ncurses, expat, libuuid, gdbm, libxslt, or ICU.

The initial implementation supports Linux targets. The first tested target is
`x86_64-unknown-linux-gnu`.

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
