# postgresql_dependencies package

`postgresql_dependencies` 在 `python_dependencies-<triple>` 前缀基础上追加
PostgreSQL 18 及其常用可选功能需要的动态库。它不重新构建
`llvm_dependencies` 或 `python_dependencies` 已经提供的基础库，例如 zlib、
zstd、OpenSSL、libxml2、libxslt、ICU、readline、ncurses、curl、sqlite、
libffi、libuuid 等。

## 边界

本包负责追加 PostgreSQL 侧依赖，不负责构建 PostgreSQL 本体。

Linux 目标尽量提供完整 PostgreSQL 可选依赖：

- krb5
- keyutils
- cyrus-sasl
- OpenLDAP
- json-c
- libxcrypt
- libevent
- liburing
- Linux-PAM
- libsystemd

`x86_64-unknown-linux-gnu` 以 CentOS 7 / glibc 2.17 为基线，`libsystemd`
降到 CentOS 7.9 的 `systemd-libs/systemd-devel 219-78.el7_9.9` RPM SDK
文件。其它 Linux 架构继续从 systemd 源码构建 `libsystemd` SDK。

MinGW64 目标只构建适合 Windows GNU 环境且能以动态库形式稳定交叉构建的依赖子集：

- json-c
- libevent

以下依赖是 Linux 机制、Linux 发行版集成能力，或当前上游 autotools 路线不能在
MinGW64 下稳定输出动态库，MinGW64 不构建：

- krb5
- cyrus-sasl
- OpenLDAP
- keyutils
- libxcrypt
- liburing
- Linux-PAM
- libsystemd

OSSP uuid 不作为本包依赖。PostgreSQL 18 的 `uuid-ossp` 扩展可以使用
`--with-uuid=e2fs` 链接 libuuid；Linux 侧 libuuid 已由 `python_dependencies`
通过 util-linux 提供。OSSP uuid 版本老、维护弱，不作为默认路线。

## 支持目标

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

所有目标都按交叉编译处理，包括 `x86_64` Linux。Windows GNU 包名和最终输出
统一使用 `x86_64-w64-windows-gnu`，不使用 `x86_64-w64-mingw32` 作为产物名。

## 默认镜像

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## 输入

底座必须来自同目标的 Python dependency 前缀：

```text
python_dependencies-<triple>.tar.xz
```

该底座已经包含 PostgreSQL 常用基础库：

```text
zlib, zstd, OpenSSL, libxml2, libxslt, ICU, readline, ncursesw,
libffi, curl, sqlite, expat, libuuid(Linux)
```

## 构建

计划命令：

```sh
./packages/postgresql_dependencies/build.sh --target=x86_64 --clean --jobs=4
./packages/postgresql_dependencies/build.sh --target=loongarch64 --clean --jobs=4
./packages/postgresql_dependencies/build.sh --target=mingw64 --clean --jobs=4
```

显式指定底座：

```sh
./packages/postgresql_dependencies/build.sh \
  --target=x86_64 \
  --python-deps-archive=packages/python_dependencies/build/dist/python_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

## 输出

```text
packages/postgresql_dependencies/build/out/postgresql_dependencies-<triple>
packages/postgresql_dependencies/build/dist/postgresql_dependencies-<triple>.tar.xz
```

解压后顶层目录：

```text
postgresql_dependencies-<triple>/
```

## Release 产物

默认 release tag：

```text
postgresql_dependencies-18
```

该 release 下包含五个目标资产：

```text
postgresql_dependencies-18-x86_64-unknown-linux-gnu.tar.xz
postgresql_dependencies-18-aarch64-unknown-linux-gnu.tar.xz
postgresql_dependencies-18-riscv64-unknown-linux-gnu.tar.xz
postgresql_dependencies-18-loongarch64-unknown-linux-gnu.tar.xz
postgresql_dependencies-18-x86_64-w64-windows-gnu.tar.xz
```

## PostgreSQL 18 对应选项

Linux 侧目标是支持 PostgreSQL 18 的这些常用配置方向：

```sh
./configure \
  --with-openssl \
  --with-libxml \
  --with-libxslt \
  --with-icu \
  --with-readline \
  --with-zlib \
  --with-zstd \
  --with-gssapi \
  --with-ldap \
  --with-pam \
  --with-systemd \
  --with-uuid=e2fs \
  --with-liburing
```

MinGW64 侧参考 MSYS2 的 Windows GNU 包构建取舍，目标是支持：

```sh
./configure \
  --with-openssl \
  --with-libxml \
  --with-libxslt \
  --with-icu \
  --with-zlib \
  --with-zstd
```

Windows GNU 侧不启用 PAM、systemd、liburing、keyutils、GSSAPI、OpenLDAP。

## 上游组件

### krb5 1.22.2

Linux only.

Source:

```text
https://kerberos.org/dist/krb5/1.22/krb5-1.22.2.tar.gz
```

Linux configure:

```sh
cd src
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static \
  --without-system-verto \
  --without-tcl
```

Build/install:

```sh
make -j <jobs>
make install
```

### keyutils 1.6.1

Linux only.

Source:

```text
https://people.redhat.com/dhowells/keyutils/keyutils-1.6.1.tar.bz2
```

Build/install:

```sh
make -j <jobs> CC=<cc> AR=<ar> RANLIB=<ranlib> \
  CFLAGS="<cflags>" LDFLAGS="<ldflags>" \
  NO_ARLIB=1
make install DESTDIR=<staging> PREFIX=<prefix> LIBDIR=<prefix>/lib
```

Install step copies the staged files into `<prefix>`. Static archives are not
shipped.

### cyrus-sasl 2.1.28

Linux only.

Source:

```text
https://github.com/cyrusimap/cyrus-sasl/releases/download/cyrus-sasl-2.1.28/cyrus-sasl-2.1.28.tar.gz
```

Linux configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static \
  --disable-sample \
  --disable-sql \
  --disable-otp \
  --disable-srp \
  --disable-srp-setpass \
  --disable-krb4 \
  --with-openssl=<prefix> \
  --with-gss_impl=mit \
  --with-krb5=<prefix>
```

Build/install:

```sh
make -j <jobs>
make install
```

### OpenLDAP 2.6.13

Linux only.

Source:

```text
https://www.openldap.org/software/download/OpenLDAP/openldap-release/openldap-2.6.13.tgz
```

Linux configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static \
  --disable-slapd \
  --disable-backends \
  --disable-overlays \
  --with-tls=openssl \
  --with-cyrus-sasl \
  --with-threads
```

Build/install:

```sh
make depend
make -j <jobs>
make install
```

### json-c 0.18

Source:

```text
https://github.com/json-c/json-c/releases/download/json-c-0.18-20240915/json-c-0.18-20240915.tar.gz
```

CMake:

```sh
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DBUILD_TESTING=OFF \
  -DDISABLE_WERROR=ON
```

MinGW additionally uses `-DCMAKE_DLL_NAME_WITH_SOVERSION=ON` and
`-DDISABLE_BSYMBOLIC=ON`; a local patch prevents json-c from adding ELF-only
`-Bsymbolic-functions` and `--version-script` linker flags for Windows targets.

Build/install:

```sh
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### libxcrypt 4.5.2

Linux only.

Source:

```text
https://github.com/besser82/libxcrypt/releases/download/v4.5.2/libxcrypt-4.5.2.tar.xz
```

Configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static \
  --disable-obsolete-api \
  --disable-failure-tokens
```

Build/install:

```sh
make -j <jobs>
make install
```

### libevent 2.1.12-stable

Source:

```text
https://github.com/libevent/libevent/releases/download/release-2.1.12-stable/libevent-2.1.12-stable.tar.gz
```

CMake:

```sh
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DEVENT__LIBRARY_TYPE=SHARED \
  -DEVENT__DISABLE_SAMPLES=ON \
  -DEVENT__DISABLE_TESTS=ON \
  -DEVENT__DISABLE_BENCHMARK=ON \
  -DEVENT__DISABLE_REGRESS=ON \
  -DEVENT__DISABLE_OPENSSL=OFF \
  -DEVENT__DISABLE_THREAD_SUPPORT=OFF
```

MinGW additionally uses `-DCMAKE_DLL_NAME_WITH_SOVERSION=ON` and
`-DEVENT__DISABLE_CLOCK_GETTIME=ON`; a local patch raises libevent's Windows
API baseline to `_WIN32_WINNT=0x0600` for current MinGW headers.

Build/install:

```sh
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### liburing 2.14

Linux only.

Source:

```text
https://github.com/axboe/liburing/archive/refs/tags/liburing-2.14.tar.gz
```

Configure:

```sh
./configure --prefix=<prefix> --cc=<cc> --cxx=<cxx>
```

Build/install:

```sh
make -j <jobs>
make install
```

Static archives are removed after install.

### Linux-PAM 1.7.2

Linux only.

Source:

```text
https://github.com/linux-pam/linux-pam/releases/download/v1.7.2/Linux-PAM-1.7.2.tar.xz
```

Meson:

```sh
meson setup <build> <source> \
  --cross-file=<cross-file> \
  --prefix=<prefix> \
  --buildtype=release \
  --default-library=shared \
  -Ddocs=disabled \
  -Dexamples=false \
  -Dxtests=false \
  -Di18n=disabled \
  -Deconf=disabled \
  -Dlogind=disabled \
  -Delogind=disabled \
  -Dopenssl=disabled \
  -Dselinux=disabled \
  -Daudit=disabled \
  -Dnis=disabled \
  -Dpam_userdb=disabled \
  -Dpam_unix=disabled
```

Build/install:

```sh
meson compile -C <build> -j <jobs>
meson install -C <build>
```

Install validation keeps only SDK files needed by PostgreSQL:

```text
include/security/*
lib/libpam.so*
lib/libpamc.so*
lib/libpam_misc.so*
lib/pkgconfig/pam*.pc
```

PAM modules, `/etc/pam.d`, service/runtime integration directories, examples,
and docs are removed after install.

### libsystemd SDK

Linux only. This package only needs `libsystemd` and headers for PostgreSQL
`--with-systemd`; it must not install system services, init files, or host
integration assets.

#### x86_64 Linux: CentOS 7.9 RPM SDK

`x86_64-unknown-linux-gnu` is the CentOS 7 compatibility target. It extracts
SDK files from CentOS 7.9 update RPMs instead of building modern systemd from
source:

```text
https://vault.centos.org/7.9.2009/updates/x86_64/Packages/systemd-libs-219-78.el7_9.9.x86_64.rpm
https://vault.centos.org/7.9.2009/updates/x86_64/Packages/systemd-devel-219-78.el7_9.9.x86_64.rpm
```

Installed files:

```text
include/systemd/*
lib/libsystemd.so
lib/libsystemd.so.0
lib/libsystemd.so.0.6.0
lib/pkgconfig/libsystemd.pc
```

The RPM `libsystemd.pc` is not copied verbatim; the package renders a local
template so `pkg-config` resolves `${prefix}/include` and `${prefix}/lib`
inside the distributable prefix.

#### Other Linux targets: systemd 260.1

Source:

```text
https://github.com/systemd/systemd/archive/refs/tags/v260.1.tar.gz
```

Meson:

```sh
meson setup <build> <source> \
  --cross-file=<cross-file> \
  --prefix=<prefix> \
  --buildtype=release \
  --auto-features=disabled \
  -Dstatic-libsystemd=false \
  -Dtests=false \
  -Dslow-tests=false \
  -Dfuzz-tests=false \
  -Dinstall-tests=false \
  -Dman=disabled \
  -Dhtml=disabled \
  -Dtranslations=false \
  -Dpam=disabled \
  -Dacl=disabled \
  -Daudit=disabled \
  -Dblkid=disabled \
  -Dfdisk=disabled \
  -Dkmod=disabled \
  -Dseccomp=disabled \
  -Dselinux=disabled \
  -Dapparmor=disabled \
  -Dpolkit=disabled \
  -Dlibcrypt=disabled \
  -Dlibcryptsetup=disabled \
  -Dlibcurl=disabled \
  -Dopenssl=disabled \
  -Dzlib=disabled \
  -Dbzip2=disabled \
  -Dxz=disabled \
  -Dlz4=disabled \
  -Dzstd=disabled \
  -Dpcre2=disabled \
  -Dlibarchive=disabled \
  -Dlibmount=disabled \
  -Dfirstboot=false \
  -Dinitrd=false \
  -Dutmp=false \
  -Dhibernate=false \
  -Dldconfig=false \
  -Dresolve=false \
  -Defi=false \
  -Dtpm=false \
  -Denvironment-d=false \
  -Dbinfmt=false \
  -Drepart=disabled \
  -Dsysupdate=disabled \
  -Dsysupdated=disabled \
  -Dcoredump=false \
  -Dpstore=false \
  -Doomd=false \
  -Dlogind=false \
  -Dhostnamed=false \
  -Dlocaled=false \
  -Dmachined=false \
  -Dportabled=false \
  -Dsysext=false \
  -Dmountfsd=false \
  -Duserdb=false \
  -Dhomed=disabled \
  -Dnetworkd=false \
  -Dtimedated=false \
  -Dtimesyncd=false \
  -Dremote=disabled \
  -Dcreate-log-dirs=false \
  -Dnsresourced=false \
  -Dnss-myhostname=false \
  -Dnss-mymachines=disabled \
  -Dnss-resolve=disabled \
  -Dnss-systemd=false \
  -Drandomseed=false \
  -Dbacklight=false \
  -Dvconsole=false \
  -Dvmspawn=disabled \
  -Dquotacheck=false \
  -Dsysusers=false \
  -Dtmpfiles=false \
  -Dimportd=disabled \
  -Dhwdb=false \
  -Drfkill=false \
  -Dxdg-autostart=false \
  -Dnspawn=disabled \
  -Dinstall-sysconfdir=false \
  -Drpmmacrosdir=no \
  -Dkernel-install=false \
  -Dukify=disabled \
  -Danalyze=false \
  -Dmode=release
```

Build/install:

```sh
meson compile -C <build> libsystemd.so -j <jobs>
meson install -C <build>
```

Install validation must ensure only `libsystemd` runtime/development files are
kept in the package prefix.

## Packaging cleanup

Distributable output prefers dynamic libraries:

- Disable static libraries when upstream supports it.
- Delete ordinary `.a` and `.la` files after install.
- Preserve MinGW `*.dll.a` import libraries.
- Copy MinGW DLLs into `<prefix>/bin`.
- Patch Linux ELF RPATH to `$ORIGIN/../lib` before packaging.
- Remove docs, man pages, tests, examples, and host integration files that are
  not needed by downstream PostgreSQL builds.
