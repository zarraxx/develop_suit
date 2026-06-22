# fontconfig

`packages/fontconfig` builds a small dynamic dependency prefix for OpenJDK
source builds.  It consumes `python_dependencies` as the base prefix so `expat`
comes from the same package used by Python-related OpenJDK tooling.  This
package then adds `freetype` and `fontconfig` headers, pkg-config metadata,
shared libraries, and fontconfig configuration files.

The package deliberately does not build fontconfig command-line tools.  OpenJDK
needs the libraries and metadata for headless font support; building tools would
add target executables that are awkward to run during cross compilation.

## Inputs

- python_dependencies: `packages/python_dependencies/build/dist/python_dependencies-<target-triple>.tar.xz`
  - provides `expat`, OpenSSL, curl, and other common runtime libraries
  - if a local archive is not present, `build.sh` downloads
    `pyhton_dependencies-3-<target-triple>.tar.xz` from the
    `pyhton_dependencies-3` GitHub Release
- FreeType: `https://download.savannah.gnu.org/releases/freetype/ft<version-without-dots>.zip`
- fontconfig: `https://www.freedesktop.org/software/fontconfig/release/fontconfig-<version>.tar.xz`
- GNU gperf: `https://ftp.gnu.org/pub/gnu/gperf/gperf-<version>.tar.gz`
  - build-time only, installed under the container work directory
- build image: `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- target sysroot and LLVM cross tools from the build image

Default versions:

- FreeType `2.14.2`
- fontconfig `2.16.0`
- GNU gperf `3.1`

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

Every target is built through the same cross-compilation flow, including
`x86_64-unknown-linux-gnu`.

## Build

```bash
./packages/fontconfig/build.sh --target=x86_64 --clean
./packages/fontconfig/build.sh --target=loongarch64 --jobs=8
./packages/fontconfig/build.sh --target=riscv64 \
  --fontconfig-version=2.16.0 \
  --freetype-version=2.14.2
```

Common options:

- `--target` or `--arch`: package target
- `--fontconfig-version`: fontconfig version
- `--freetype-version`: FreeType version
- `--gperf-version`: build-time GNU gperf version
- `--python-deps-archive`: python_dependencies tarball to use as the base prefix
- `--python-deps-dir`: already extracted python_dependencies prefix
- `--python-deps-release-tag`: release tag to download when no local archive exists
- `--python-deps-asset-prefix`: asset prefix for the downloaded archive
- `--llvm-version`: LLVM toolchain prefix version inside the image
- `--image`: build image
- `--jobs`: parallel build jobs
- `--clean`: remove this target's work/output before building

## Component Build Details

### GNU gperf

Configure:

```bash
./configure --prefix=<build-tools>/gperf
```

Build and install for the build machine:

```bash
make -j <jobs>
make install
```

The installed `gperf` is added to `PATH` before configuring fontconfig.  It is
not copied into the final package.

### python_dependencies Base Prefix

Before entering the container, `build.sh` extracts or copies
`python_dependencies-<target-triple>` into the output prefix and validates:

```text
README.python-dependencies
include/expat.h
lib/pkgconfig/expat.pc
lib/libexpat.so* or MinGW expat DLL/import library
```

`fontconfig` is configured against that existing `expat`; this package does not
download or build expat.

By default, the script first checks local build output, `packages/fontconfig/build/inputs`,
and `tmp/`.  If no matching archive exists, it downloads from the
`pyhton_dependencies-3` release:

```text
pyhton_dependencies-3-<target-triple>.tar.xz
```

### FreeType

Configure:

```bash
cmake -S freetype -B build/freetype -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_TOOLCHAIN_FILE=<generated-toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_INSTALL_LIBDIR=lib \
  -DBUILD_SHARED_LIBS=ON \
  -DFT_DISABLE_ZLIB=TRUE \
  -DFT_DISABLE_BZIP2=TRUE \
  -DFT_DISABLE_PNG=TRUE \
  -DFT_DISABLE_HARFBUZZ=TRUE \
  -DFT_DISABLE_BROTLI=TRUE
```

Build and install:

```bash
cmake --build build/freetype --parallel <jobs>
cmake --install build/freetype
```

### fontconfig

Configure:

```bash
meson setup build/fontconfig fontconfig \
  --cross-file=<generated-meson-cross-file> \
  --wrap-mode=nodownload \
  --prefix=<prefix> \
  --libdir=lib \
  --buildtype=release \
  --default-library=shared \
  -Ddoc=disabled \
  -Ddoc-txt=disabled \
  -Ddoc-man=disabled \
  -Ddoc-pdf=disabled \
  -Ddoc-html=disabled \
  -Dnls=disabled \
  -Dtests=disabled \
  -Dtools=disabled \
  -Dcache-build=disabled \
  -Diconv=disabled \
  -Dxml-backend=expat \
  -Dfontations=disabled
```

Build and install:

```bash
meson compile -C build/fontconfig -j <jobs>
DESTDIR=<stage> meson install -C build/fontconfig
cp -a <stage>/<prefix>/. <prefix>/
```

## Output Layout

The installed prefix contains:

- `include/expat.h`
- `include/freetype2/`
- `include/fontconfig/`
- `lib/pkgconfig/expat.pc`
- `lib/pkgconfig/freetype2.pc`
- `lib/pkgconfig/fontconfig.pc`
- shared libraries under `lib/`
- MinGW DLLs copied to `bin/`
- `share/fontconfig/` and `etc/fonts/` configuration data
- `README.fontconfig`
- `README.python-dependencies`

Static libraries and libtool archives are removed after install.  MinGW
`*.dll.a` import libraries are preserved because they are required for DLL
linking.

## Release Artifacts

```text
packages/fontconfig/build/dist/fontconfig-<fontconfig-version>-<target-triple>.tar.xz
```

Examples:

- `fontconfig-2.16.0-x86_64-unknown-linux-gnu.tar.xz`
- `fontconfig-2.16.0-loongarch64-unknown-linux-gnu.tar.xz`
- `fontconfig-2.16.0-x86_64-w64-windows-gnu.tar.xz`
