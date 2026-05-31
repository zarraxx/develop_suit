# perl package

`perl` builds a distributable Perl prefix on top of
`python_dependencies-<triple>` or `pyhton_dependencies-3-<triple>`.

## Boundary

This package builds Perl only. It consumes the dependency prefix produced by
`packages/python_dependencies`; it does not rebuild zlib, OpenSSL, libffi,
sqlite, readline, ncurses, expat, libuuid, gdbm, libxslt, or ICU.

Supported package targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

Linux targets use Perl's upstream Unix `Configure` cross-compilation path.
Non-x86_64 Linux targets need a target runner command passed with
`--perl-target-runner` because Perl's `Configure` runs target probe programs.

The MinGW target is part of the package boundary, but it should use a separate
Windows VM build path. Perl's upstream MinGW build is centered on
`win32/GNUmakefile`; it assumes Windows command syntax, Windows paths, and
running generated Windows executables during the build. It is therefore treated
as a Windows native-style build using the staged clang/mingw64 SDK and the
matching `python_dependencies` prefix, not as the Linux-container Unix
`Configure` cross path.

## Build strategy

Linux packages are built on GitHub Linux VMs with qemu installed for foreign
Linux targets. The VM runs the normal package container and passes a qemu-user
runner into Perl `Configure`:

```sh
sudo apt-get update
sudo apt-get install -y qemu-user

./packages/perl/build.sh \
  --target=loongarch64 \
  --perl-target-runner="qemu-loongarch64 -L /opt/sysroot/loongarch64-unknown-linux-gnu" \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-loongarch64-unknown-linux-gnu.tar.xz
```

The same pattern applies to `aarch64` and `riscv64` with the corresponding
qemu binary and sysroot path.

MinGW64 packages are built on a GitHub Windows VM. The workflow should first
install or unpack:

- clang/LLVM `18.1.8`
- the staged `x86_64-w64-windows-gnu` mingw64 toolchain/sysroot
- `python_dependencies-x86_64-w64-windows-gnu.tar.xz`

Then it should invoke Perl's `win32/GNUmakefile` as a Windows native-style
MinGW build, using the staged clang/mingw64 tools and installing into the
package prefix that will be archived as:

```text
perl-<version>-x86_64-w64-windows-gnu.tar.xz
```

## Build

```sh
./packages/perl/build.sh --target=x86_64 --perl-version=5.42.2 --clean --jobs=4
```

Explicit dependency input:

```sh
./packages/perl/build.sh \
  --target=x86_64 \
  --perl-version=5.42.2 \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

For non-x86_64 Linux targets, provide a runner available inside the container:

```sh
./packages/perl/build.sh \
  --target=aarch64 \
  --perl-target-runner="qemu-aarch64 -L /opt/sysroot/aarch64-unknown-linux-gnu"
```

## Output

```text
packages/perl/build/out/perl-<version>-<triple>
packages/perl/build/dist/perl-<version>-<triple>.tar.xz
```

For Perl 5.42.2 on x86_64 Linux:

```text
packages/perl/build/dist/perl-5.42.2-x86_64-unknown-linux-gnu.tar.xz
```

Release assets use the same stem:

```text
perl-<version>-<triple>.tar.xz
```

## Perl Configure

Source:

```text
https://cpan.metacpan.org/authors/id/S/SH/SHAY/perl-<version>.tar.gz
```

The package applies `mount_root/patch/perl-configure-local-targetrun.patch`
with `patch -p1`. The patch adds a `targetrun=local` mode so x86_64 Linux can
still use Perl's cross-compilation mode without depending on an SSH server.
The build also creates short compiler wrappers such as
`x86_64-unknown-linux-gnu-gcc` inside the container build-tools directory so
Perl's `Configure` can derive a stable `targetarch`.

Linux:

```sh
Configure -des \
  -Dusecrosscompile \
  -Dtargethost=localhost \
  -Dtargetrun=local \
  -Dtargetto=cp \
  -Dtargetfrom=cp \
  -Dtargetdir=<build>/target-run \
  -Dtargetarch=<target> \
  -Darchname=<target> \
  -Dprefix=<prefix> \
  -Dvendorprefix=<prefix> \
  -Dsiteprefix=<prefix> \
  -Dinstallusrbinperl=n \
  -Duserelocatableinc \
  -Uuseshrplib \
  -Dusethreads \
  -Duse64bitall \
  -Dcc=<target-cc> \
  -Dld=<target-cc> \
  -Dar=<target-ar> \
  -Dranlib=<target-ranlib> \
  -Dsysroot=<sysroot> \
  -Dlibs="-lm -lpthread -ldl -lcrypt [-lintl]"
make -j <jobs>
make install
```

When the copied dependency prefix contains `libintl`, `-lintl` is added to
`-Dlibs`. Linux builds also add a temporary absolute rpath for
`<prefix>/lib` so `Configure` can run target probe programs; after install the
package rewrites ELF rpaths to `$ORIGIN`-relative paths.

`-Duserelocatableinc` is used so `@INC` follows the installed `perl`
executable after the package is copied to another directory. That option is
not compatible with `-Duseshrplib`, so this package keeps the installed
`CORE/libperl.a` archive for Perl embedding and removes other ordinary `.a`
and `.la` files after installation. Linux ELF rpaths are patched to
`$ORIGIN`-relative paths, and the x86_64 build runs a small `Config` smoke
test.
