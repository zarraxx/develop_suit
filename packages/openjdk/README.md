# openjdk

`packages/openjdk` builds a reusable Linux JDK prefix with Maven.

The package has two build paths:

- `x86_64-unknown-linux-gnu`: package a prebuilt Azul Zulu Linux x64 JDK.
- `aarch64-unknown-linux-gnu`: package a prebuilt Azul Zulu Linux aarch64 JDK.
- `x86_64-w64-windows-gnu`: package a prebuilt Azul Zulu Windows x64 JDK.
- `riscv64-unknown-linux-gnu`, `loongarch64-unknown-linux-gnu`: build OpenJDK
  from source as a cross build.

Windows/MinGW JDKs are intentionally not built from source here.

## Inputs

- x86_64 Linux prebuilt JDK:
  `https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_x64.tar.gz`
- aarch64 Linux prebuilt JDK:
  `https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_aarch64.tar.gz`
- x86_64 Windows prebuilt JDK:
  `https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-win_x64.zip`
- OpenJDK source for `riscv64`:
  `https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz`
- OpenJDK SRPM for `loongarch64`:
  `https://pkg.loongnix.cn/loongnix-server/23.2/os/source/SPackages/java-17-openjdk-17.0.17.0.10-1.lns23.src.rpm`
  - contains `openjdk-17.0.17+10.tar.xz`
  - contains `jdk17-LoongArch64.patch`, which is applied explicitly before
    the local headless/runtime patches
- Maven:
  `https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.zip`
- Boot JDK for source cross builds. The Boot JDK must run on the build host.
- fontconfig dependency package for `riscv64` and `loongarch64` source builds:
  `fontconfig-2.16.0-<target-triple>.tar.xz`
  - provides FreeType, fontconfig, expat, headers, shared libraries, and
    pkg-config metadata for OpenJDK configure
  - if a local archive is not present, `build.sh` downloads it from the
    `fontconfig-2.16.0` GitHub Release
- Info-ZIP `zip` source for source cross builds when the build image does not
  already provide a host `zip` command:
  `https://downloads.sourceforge.net/infozip/zip30.tar.gz`

## Build

```bash
./packages/openjdk/build.sh --target=x86_64 --jobs=8 --clean
./packages/openjdk/build.sh --target=aarch64 --jobs=8 --clean
./packages/openjdk/build.sh --target=mingw64 --jobs=8 --clean
./packages/openjdk/build.sh --target=riscv64 --jobs=8 --clean
./packages/openjdk/build.sh --target=loongarch64 --jobs=8 --clean
```

Useful overrides:

```bash
./packages/openjdk/build.sh \
  --target=x86_64 \
  --x64-jdk-url=https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_x64.tar.gz \
  --maven-version=3.9.16 \
  --clean
```

```bash
./packages/openjdk/build.sh \
  --target=aarch64 \
  --aarch64-jdk-url=https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-linux_aarch64.tar.gz \
  --maven-version=3.9.16 \
  --clean
```

```bash
./packages/openjdk/build.sh \
  --target=mingw64 \
  --mingw64-jdk-url=https://cdn.azul.com/zulu/bin/zulu25.34.17-ca-jdk25.0.3-win_x64.zip \
  --maven-version=3.9.16 \
  --clean
```

```bash
./packages/openjdk/build.sh \
  --target=riscv64 \
  --fontconfig-archive=/path/to/fontconfig-2.16.0-riscv64-unknown-linux-gnu.tar.xz \
  --openjdk-source-url=https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz \
  --boot-jdk-archive=/path/to/jdk-25-linux-x64.tar.gz \
  --zip-url=https://downloads.sourceforge.net/infozip/zip30.tar.gz \
  --maven-version=3.9.16 \
  --jobs=8 \
  --clean
```

```bash
./packages/openjdk/build.sh \
  --target=loongarch64 \
  --openjdk-version=17.0.17 \
  --fontconfig-archive=/path/to/fontconfig-2.16.0-loongarch64-unknown-linux-gnu.tar.xz \
  --loongarch64-openjdk-srpm-url=https://pkg.loongnix.cn/loongnix-server/23.2/os/source/SPackages/java-17-openjdk-17.0.17.0.10-1.lns23.src.rpm \
  --boot-jdk-archive=/path/to/jdk-17-linux-x64.tar.gz \
  --zip-url=https://downloads.sourceforge.net/infozip/zip30.tar.gz \
  --maven-version=3.9.16 \
  --jobs=8 \
  --clean
```

## Source Configure

Source targets use OpenJDK autoconf:

```bash
bash configure \
  --with-conf-name=<repo-target-triple> \
  --with-boot-jdk=<x86_64-linux-boot-jdk> \
  --openjdk-target=<openjdk-linux-gnu-target> \
  --with-toolchain-type=clang \
  --with-toolchain-path=<generated-wrapper-dir> \
  --with-extra-path=<generated-wrapper-dir>:<llvm>/bin \
  --with-sysroot=/opt/sysroot/<repo-target-triple> \
  --enable-headless-only \
  --with-jvm-variants=server \
  --with-debug-level=release \
  --with-native-debug-symbols=none \
  --with-build-user=develop_suit \
  --disable-warnings-as-errors \
  --with-freetype=system \
  --with-freetype-include=<fontconfig-prefix>/include \
  --with-freetype-lib=<fontconfig-prefix>/lib \
  --with-fontconfig=<fontconfig-prefix>
```

Target mapping:

- `riscv64-unknown-linux-gnu` configures as `riscv64-linux-gnu`.
- `loongarch64-unknown-linux-gnu` configures as `loongarch64-linux-gnu`.

OpenJDK 25 recognizes both `riscv64` and `loongarch64` in
`make/autoconf/platform.m4`. The default `loongarch64` source is the Loongnix
OpenJDK 17 SRPM. The package extracts the upstream source tarball from that
SRPM, applies `jdk17-LoongArch64.patch`, and then applies the local package
patches. This provides the LoongArch HotSpot backend and defaults to the
`server` VM. If `loongarch64` is built from an upstream OpenJDK source archive
without a `src/hotspot/cpu/loongarch*` backend, the package falls back to the
`zero` VM unless `OPENJDK_JVM_VARIANTS` is set explicitly.

## Target Dependencies

`riscv64` and `loongarch64` source builds produce a service/runtime-oriented
image for Spring Boot, PostgreSQL `jdbc_fdw`, and PL/Java use. The package
sets `OPENJDK_HEADLESS_RUNTIME_ONLY=true` and patches OpenJDK configure so it
does not check or build desktop/AWT dependencies.

The source-built runtime intentionally excludes `java.desktop`, so it does not
require CUPS, ALSA, or X11. It still consumes the `fontconfig` dependency
prefix during source configuration so OpenJDK has a deterministic FreeType and
fontconfig view instead of probing the host or target sysroot. It also requires
the target libc/runtime sysroot and the staged LLVM toolchain.

By default, source builds pass a service-runtime module list through
`HEADLESS_RUNTIME_MODULES` to avoid `java.desktop` and AWT native libraries.
The default list includes core server modules, JDBC, management, JFR, runtime
tool support, common crypto modules, charsets, localedata, and `jdk.compiler`
so `javac` is available for PL/Java-style workflows. Build-only modules such as
`jdk.jdeps` and `jdk.jlink` are available while constructing the image but are
not installed into the default runtime image. The list can be overridden from
the host environment when a smaller or larger runtime image is needed.

Source builds also require build-host tools. `zip` is required by OpenJDK's
own makefiles for jar/zip/bundle creation. If the container image does not
provide it, this package builds Info-ZIP as a host tool under the temporary
build tools directory. It is not installed into the final JDK package.

## Output

```text
packages/openjdk/build/dist/openjdk-<openjdk-version>-<target-triple>.tar.xz
```

Layout:

```text
openjdk-<version>-<target-triple>/
  README.openjdk
  bin/
    java -> ../jdk/bin/java
    javac -> ../jdk/bin/javac
    mvn -> ../maven/bin/mvn
  jdk/
  maven/
```

The MinGW package uses `java.exe`, `javac.exe`, and `mvn.cmd` entry links under
`bin/`.
