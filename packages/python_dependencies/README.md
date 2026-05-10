# python_dependencies package

`python_dependencies` 在 `llvm_dependencies-<triple>` 前缀基础上追加构建
Python 解释器和 Python 生态常用模块需要的动态库。它不重新构建 zlib、
OpenSSL、libxml2、libffi、readline、ncurses 等 LLVM dependency 基础库。

## 边界

本包负责追加：

- curl
- util-linux/libuuid (Linux only)
- expat
- sqlite
- gdbm (Linux only)
- libxslt/libexslt
- icu4c

底座必须来自同目标的 `llvm_dependencies-<triple>.tar.xz` 或已解压目录。

## 支持目标

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

所有目标都按交叉编译处理，包括 `x86_64` Linux。Windows GNU 包名和最终输出
统一使用 `x86_64-w64-windows-gnu`。

## 默认镜像

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## 构建

```sh
./packages/python_dependencies/build.sh --target=x86_64 --clean --jobs=4
./packages/python_dependencies/build.sh --target=loongarch64 --clean --jobs=4
./packages/python_dependencies/build.sh --target=mingw64 --clean --jobs=4
```

显式指定底座：

```sh
./packages/python_dependencies/build.sh \
  --target=x86_64 \
  --llvm-deps-archive=packages/llvm_dependencies/build/dist/llvm_dependencies-x86_64-unknown-linux-gnu.tar.xz
```

## 输出

```text
packages/python_dependencies/build/out/python_dependencies-<triple>
packages/python_dependencies/build/dist/python_dependencies-<triple>.tar.xz
```

解压后顶层目录：

```text
python_dependencies-<triple>/
```

## Release 产物

```text
python_dependencies-x86_64-unknown-linux-gnu.tar.xz
python_dependencies-aarch64-unknown-linux-gnu.tar.xz
python_dependencies-riscv64-unknown-linux-gnu.tar.xz
python_dependencies-loongarch64-unknown-linux-gnu.tar.xz
python_dependencies-x86_64-w64-windows-gnu.tar.xz
```

## 上游组件

### curl 8.20.0

Source:

```text
https://curl.se/download/curl-8.20.0.tar.gz
```

Linux configure, following Debian-style autotools packaging:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static --disable-dependency-tracking \
  --with-openssl=<prefix> --with-zlib=<prefix> \
  --disable-ldap --disable-ldaps --disable-docs --disable-manual \
  --without-brotli --without-libidn2 --without-libpsl \
  --without-libssh2 \
  --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
  --without-zstd
```

MinGW configure uses curl's CMake build, following the MSYS2 package direction:

```sh
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_DLL_NAME_WITH_SOVERSION=ON \
  -DCMAKE_UNITY_BUILD=ON \
  -DBUILD_SHARED_LIBS=ON \
  -DBUILD_STATIC_LIBS=OFF \
  -DBUILD_CURL_EXE=ON \
  -DPICKY_COMPILER=OFF \
  -DBUILD_EXAMPLES=OFF \
  -DBUILD_LIBCURL_DOCS=OFF \
  -DBUILD_MISC_DOCS=OFF \
  -DBUILD_TESTING=OFF \
  -DCURL_DISABLE_INSTALL_DOCS=ON \
  -DCURL_DEFAULT_SSL_BACKEND=openssl \
  -DCURL_ENABLE_SSL=ON \
  -DCURL_USE_OPENSSL=ON \
  -DCURL_USE_LIBSSH2=OFF \
  -DCURL_USE_LIBPSL=OFF \
  -DCURL_BROTLI=OFF \
  -DCURL_ZSTD=OFF \
  -DUSE_LIBIDN2=OFF \
  -DUSE_NGHTTP2=OFF \
  -DUSE_NGHTTP3=OFF \
  -DUSE_NGTCP2=OFF \
  -DENABLE_CURL_MANUAL=OFF \
  -DENABLE_UNICODE=OFF \
  -DCURL_USE_SCHANNEL=OFF \
  -DCURL_WINDOWS_SSPI=ON
```

Linux build/install:

```sh
make -j <jobs>
make install
```

MinGW build/install:

```sh
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### util-linux 2.42 libuuid

Linux only. MinGW does not build util-linux/libuuid here; the Windows GNU
Python path follows the MSYS2 convention and leaves UUID handling to Python's
MinGW-side build choices instead of shipping a separate util-linux libuuid.

Source:

```text
https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.tar.xz
```

Configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --disable-all-programs --enable-libuuid \
  --disable-libblkid --disable-libmount --disable-libsmartcols \
  --disable-nls --without-python --without-systemd
```

Build/install:

```sh
make -j <jobs>
make install
```

### expat 2.8.0

Source:

```text
https://github.com/libexpat/libexpat/releases/download/R_2_8_0/expat-2.8.0.tar.xz
```

CMake:

```sh
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DEXPAT_SHARED_LIBS=ON \
  -DEXPAT_BUILD_TOOLS=OFF \
  -DEXPAT_BUILD_EXAMPLES=OFF \
  -DEXPAT_BUILD_TESTS=OFF \
  -DEXPAT_BUILD_DOCS=OFF
```

MinGW additionally passes `-DCMAKE_DLL_NAME_WITH_SOVERSION=ON`.

Build/install:

```sh
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### sqlite 3530000

Source:

```text
https://sqlite.org/2026/sqlite-autoconf-3530000.tar.gz
```

Configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-shared --disable-static \
  --disable-rpath --all --session \
  --disable-readline
```

MinGW additionally passes `--out-implib` to produce the MSYS2-style
`libsqlite3.dll.a` import library. Linux does not pass this option.

Build/install:

```sh
make -j <jobs>
make install
```

### gdbm 1.26

Linux only. The MinGW package does not build gdbm because the upstream
autotools path pulls in POSIX account/network headers that are not part of the
Windows GNU runtime, and the intended MSYS2-style Python dependency set does
not require a separate MinGW gdbm package here.

Source:

```text
https://ftp.gnu.org/gnu/gdbm/gdbm-1.26.tar.gz
```

Configure:

```sh
./configure --build=<build> --host=<host> --prefix=<prefix> \
  --enable-libgdbm-compat \
  --enable-shared --disable-static \
  --disable-nls --disable-dependency-tracking
```

Build/install:

```sh
make -j <jobs>
make install
```

### libxslt 1.1.45

Source:

```text
https://gitlab.gnome.org/GNOME/libxslt/-/archive/v1.1.45/libxslt-v1.1.45.tar.bz2
```

CMake:

```sh
cmake -S <source> -B <build> -G Ninja \
  -DCMAKE_TOOLCHAIN_FILE=<toolchain> \
  -DCMAKE_INSTALL_PREFIX=<prefix> \
  -DCMAKE_PREFIX_PATH=<prefix> \
  -DBUILD_SHARED_LIBS=ON \
  -DLIBXSLT_WITH_CRYPTO=OFF \
  -DLIBXSLT_WITH_DEBUGGER=OFF \
  -DLIBXSLT_WITH_PROGRAMS=OFF \
  -DLIBXSLT_WITH_PYTHON=OFF \
  -DLIBXSLT_WITH_TESTS=OFF \
  -DLibXml2_DIR=<prefix>/lib/cmake/libxml2
```

MinGW additionally passes `-DHAVE_STRXFRM_L=OFF` so libxslt uses its Windows
locale path instead of a POSIX `strxfrm_l` probe that does not match MinGW.

Build/install:

```sh
cmake --build <build> --parallel <jobs>
cmake --install <build>
```

### icu4c 78.3

Source:

```text
https://github.com/unicode-org/icu/releases/download/release-78.3/icu4c-78.3-sources.tgz
```

ICU 交叉编译需要先构建 build 端 ICU 工具，再用 `--with-cross-build` 构建目标库。

Host tools configure:

```sh
icu/source/configure --prefix=<build-tools>/host-icu \
  --disable-rpath \
  --enable-shared --disable-static \
  --disable-samples --disable-tests
```

The host tools build uses the seed LLVM `llvm-ar`, `llvm-ranlib`, and `llvm-strip`
explicitly, because ICU still packages some generated data through `pkgdata`
even when the final target output is shared-library-only.

Target configure:

```sh
icu/source/configure --build=<build> --host=<host> --prefix=<prefix> \
  --with-cross-build=<host-icu-build-dir> \
  --disable-rpath \
  --enable-shared --disable-static \
  --disable-samples --disable-tests
```

MinGW additionally passes `--with-data-packaging=dll`, matching the MSYS2
layout where ICU data is shipped as a DLL (`icudt*.dll`) alongside `icuin*.dll`
and `icuuc*.dll`.

Build/install:

```sh
make -j <jobs>
make install
```

## Linux 与 MinGW 差异

Linux 使用目标三元组作为 autotools `--host`，整体参数取 Debian 风格：
shared-only、关闭 dependency tracking、关闭文档/测试/不需要的可选网络压缩特性，
并在打包前用 `patchelf` 写入相对 `$ORIGIN` rpath。MinGW 使用
`x86_64-w64-mingw32` 作为 autotools host 兼容名，但包名和目录仍保持
`x86_64-w64-windows-gnu`；CMake/autotools 参数优先贴近 MSYS2 MinGW 包的
DLL/import-library 布局。普通静态库和 `.la` 文件在安装后删除；MinGW 的
`*.dll.a` import library 会保留。

从 `llvm_dependencies` 继承来的文本元数据和配置脚本会把旧
`/opt/llvm_dependencies-<triple>` 前缀重写为当前
`/opt/python_dependencies-<triple>` 前缀。
