# tcl package

`tcl` builds a distributable Tcl prefix on top of
`python_dependencies-<triple>` or `pyhton_dependencies-3-<triple>`.

## Boundary

This package builds Tcl only. It consumes the dependency prefix produced by
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
./packages/tcl/build.sh --target=x86_64 --tcl-version=8.6.18 --clean --jobs=4
```

Explicit dependency input:

```sh
./packages/tcl/build.sh \
  --target=x86_64 \
  --tcl-version=8.6.18 \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

## Output

```text
packages/tcl/build/out/tcl-<version>-<triple>
packages/tcl/build/dist/tcl-<version>-<triple>.tar.xz
```

For Tcl 8.6.18 on x86_64 Linux:

```text
packages/tcl/build/dist/tcl-8.6.18-x86_64-unknown-linux-gnu.tar.xz
```

Release assets use the same stem:

```text
tcl-<version>-<triple>.tar.xz
```

## Tcl Configure

Source:

```text
https://prdownloads.sourceforge.net/tcl/tcl<version>-src.tar.gz
```

The package treats the build as cross-compilation even for x86_64 Linux. It
first builds a host Tcl helper used by Tcl's generated-file rules, then
configures target Tcl with the staged LLVM compiler.

Linux:

```sh
unix/configure --build=<build> --host=<target> --prefix=<prefix> \
  --enable-shared \
  --enable-threads \
  --with-tzdata=no
make -j <jobs> binaries libraries
make install-binaries install-libraries install-headers
```

MinGW:

```sh
win/configure --build=<build> --host=x86_64-w64-mingw32 --prefix=<prefix> \
  --enable-shared \
  --enable-threads \
  --enable-64bit \
  --with-tzdata=no
make -j <jobs> binaries libraries TCL_EXE=<host-tclsh>
make install-binaries install-libraries install-headers TCL_EXE=<host-tclsh>
```

Dependency discovery is routed through the copied dependency prefix using
`CPPFLAGS`, `LDFLAGS`, and `PKG_CONFIG_LIBDIR`. The bundled Tcl `pkgs/`
extension set is not installed by this package; extension packaging should be
handled explicitly by a separate package if needed.

After install, Linux `tclsh8.6` is wrapped so `TCL_LIBRARY` is resolved relative
to the executable, a `tclsh` symlink is created, ordinary `.a` and `.la` files
are removed, Linux ELF rpaths are patched to `$ORIGIN`-relative paths, and the
x86_64 build runs a small Tcl smoke test. The `libtclstub*.a` stub archive is
kept because Tcl extensions use it as part of the stable stub ABI.
