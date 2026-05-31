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
`aarch64` and `loongarch64` Linux targets use a mounted `qemu-user-static`
runner by default because Perl's `Configure` runs target probe programs.
`riscv64` can use the same path when `qemu-riscv64-static` is installed, or a
custom runner can still be passed explicitly with `--perl-target-runner`.

The MinGW target is part of the package boundary, but it should use a separate
host-side build path. Perl's upstream MinGW build is centered on
`win32/GNUmakefile`; it assumes Windows command syntax, Windows paths, and
running generated Windows executables during the build. It is therefore treated
as a Windows native-style build using the staged clang/mingw64 SDK, the
matching `pyhton_dependencies-3` prefix, and `wine` on the Linux host, not as
the Linux-container Unix `Configure` cross path.

## Build strategy

Linux packages are built on GitHub Linux VMs with `qemu-user-static` installed
for foreign Linux targets. `build.sh` auto-detects the matching host qemu
binary, preferring `qemu-<arch>-static` but also accepting `qemu-<arch>` from
packages such as Ubuntu's `qemu-user`, mounts it into the package container,
and wires Perl `Configure` to run target probe executables through qemu.
Locally, the package prefers `podman` as the container runtime and falls back
to `docker` only when `podman` is unavailable:

```sh
sudo apt-get update
sudo apt-get install -y qemu-user-static

./packages/perl/build.sh \
  --target=loongarch64 \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-loongarch64-unknown-linux-gnu.tar.xz
```

The same pattern applies to `aarch64` and `riscv64` with the corresponding
qemu binary and sysroot path.

If qemu is not installed in a standard host path, pass it explicitly:

```sh
./packages/perl/build.sh \
  --target=aarch64 \
  --container-runtime=podman \
  --qemu-binary=/usr/local/bin/qemu-aarch64-static
```

`--perl-target-runner` is still available for custom setups, but it becomes the
manual override instead of the normal path.

MinGW64 packages should not use the Linux package container path. Instead, the
host should download the staged Windows GNU SDK pieces, unpack them locally,
and run Perl's `win32/GNUmakefile` under `wine` so build-time helpers such as
`miniperl.exe` behave like a Windows native environment.

Required downloads:

- Windows clang SDK asset
  [clang-18.1.8-x86_64-w64-windows-gnu.tar.xz](https://github.com/zarraxx/develop_suit/releases/download/clang-18.1.8/clang-18.1.8-x86_64-w64-windows-gnu.tar.xz)
  which already includes the matching MinGW sysroot
- dependency prefix asset from
  [pyhton_dependencies-3](https://github.com/zarraxx/develop_suit/releases/tag/pyhton_dependencies-3)
  such as `pyhton_dependencies-3-x86_64-w64-windows-gnu.tar.xz`

Host prerequisites:

- `wine` or `wine64`
- `curl`
- `tar`
- `xz`

After unpacking those archives, invoke Perl's `win32/GNUmakefile` as a Windows
native-style MinGW build, using the staged clang/mingw64 tools and installing
into the package prefix that will be archived as:

```text
perl-<version>-x86_64-w64-windows-gnu.tar.xz
```

## Build

Linux:

```sh
./packages/perl/build.sh --target=x86_64 --perl-version=5.42.2 --clean --jobs=4
```

For non-x86_64 Linux targets, install `qemu-user` or `qemu-user-static` on the
host and the runner will be mounted automatically:

```sh
sudo apt-get install -y qemu-user-static

./packages/perl/build.sh \
  --target=aarch64 \
  --container-runtime=podman
```

MinGW64 host-side preparation:

```sh
sudo apt-get update
sudo apt-get install -y wine64

mkdir -p "$HOME/opt"

curl -L \
  -o "$HOME/Downloads/clang-18.1.8-x86_64-w64-windows-gnu.tar.xz" \
  https://github.com/zarraxx/develop_suit/releases/download/clang-18.1.8/clang-18.1.8-x86_64-w64-windows-gnu.tar.xz

# Download this release asset from its tag page:
#   pyhton_dependencies-3-x86_64-w64-windows-gnu.tar.xz
```

Suggested local layout before running the MinGW build:

```text
$HOME/opt/clang-18.1.8-x86_64-w64-windows-gnu
$HOME/opt/pyhton_dependencies-3-x86_64-w64-windows-gnu
```

The MinGW flow should export
`PATH="$HOME/opt/clang-18.1.8-x86_64-w64-windows-gnu/bin:$PATH"`, use the
Windows clang SDK's `x86_64-w64-windows-gnu-clang-gcc.exe` toolchain under
`wine`, and run the generated `miniperl.exe` during the `win32/GNUmakefile`
build. This path is intentionally host-side and does not use the package
container.

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
Perl's `Configure` can derive a stable `targetarch`. For foreign Linux targets,
`build.sh` mounts `qemu-<arch>-static` into the container and sets
`PERL_TARGET_RUNNER` to `env QEMU_LD_PREFIX=/opt/sysroot/<triple> <qemu> -L
/opt/sysroot/<triple>`.

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
  -Duseshrplib \
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

MinGW64 host-side:

```sh
make -f win32/GNUmakefile
make -f win32/GNUmakefile install
```

The MinGW build should be driven from the Linux host with `wine` standing in
for the Windows runtime whenever `miniperl.exe`, `perl.exe`, or other generated
Windows executables must run during the `GNUmakefile` build and install steps.
After install, the package should also copy the Windows clang runtime DLLs that
`perl.exe` and `perl542.dll` depend on, such as `libc++.dll` and
`libunwind.dll`, into `<prefix>/bin`.

When the copied dependency prefix contains `libintl`, `-lintl` is added to
`-Dlibs`. Linux builds also add a temporary absolute rpath for
`<prefix>/lib` so `Configure` can run target probe programs; after install the
package rewrites ELF rpaths to `$ORIGIN`-relative paths.

Linux packages enable `-Duseshrplib` so downstream consumers such as
PostgreSQL `PL/Perl` can link against a shared `libperl`. Ordinary static
archives and `.la` files are removed after installation, so it is acceptable
for the final package to ship without `libperl.a`. Linux ELF rpaths are
patched to `$ORIGIN`-relative paths, and the x86_64 build runs a small
`Config` smoke test.
