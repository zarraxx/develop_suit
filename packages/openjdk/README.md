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
- OpenJDK source:
  `https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz`
- Maven:
  `https://dlcdn.apache.org/maven/maven-3/3.9.16/binaries/apache-maven-3.9.16-bin.zip`
- Boot JDK for source cross builds. The Boot JDK must run on the build host.
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
  --openjdk-source-url=https://openjdk-sources.osci.io/openjdk25/openjdk-25.0.3-ga.tar.xz \
  --boot-jdk-archive=/path/to/jdk-25-linux-x64.tar.gz \
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
  --disable-warnings-as-errors
```

Target mapping:

- `riscv64-unknown-linux-gnu` configures as `riscv64-linux-gnu`.
- `loongarch64-unknown-linux-gnu` configures as `loongarch64-linux-gnu`.

OpenJDK 25 recognizes both `riscv64` and `loongarch64` in
`make/autoconf/platform.m4`. The remaining risk is target sysroot completeness,
not CPU name support.

## Target Dependencies

`riscv64` and `loongarch64` source builds produce a service/runtime-oriented
image for Spring Boot, PostgreSQL `jdbc_fdw`, and PL/Java use. The package
sets `OPENJDK_HEADLESS_RUNTIME_ONLY=true` and patches OpenJDK configure so it
does not check or build desktop/AWT dependencies.

The source-built runtime intentionally excludes `java.desktop`, so it does not
require CUPS, freetype, fontconfig, ALSA, or X11. It still requires the target
libc/runtime sysroot and the staged LLVM toolchain.

The default module set includes server-side modules such as `java.sql`,
`java.naming`, `java.management`, `java.instrument`, `java.net.http`,
`jdk.unsupported`, `jdk.crypto.ec`, `jdk.compiler`, and `jdk.jdwp.agent`.

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
