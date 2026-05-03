# stage1

`stage1` 的目标是在 `stage0` 产出的最小 rootfs 之上，继续放入一批“目标机可运行”的开发工具。

当前这一层先不追求一次把所有工具都堆满，重点是先把一套可复用的交叉编译框架搭好。

当前 `autotools` 这组工具按下面这个范围来规划：

- make
- m4
- autoconf
- automake
- libtool
- pkg-config

其中现在已经接入并启用构建的是：

- GNU make
- GNU m4
- autoconf
- automake
- libtool
- pkg-config

这些包都通过 CMake 统一调度，但真正的构建方式仍然是各自原生的 autotools 流程。这样后面继续接 `bison`、`flex`、`cmake`、`ninja`、`openssl` 之类包时，不需要把顶层 `CMakeLists.txt` 写成面条。

## 设计思路

`stage1` 复用 `stage0` 已经准备好的能力：

- 输入 sysroot/rootfs：`dist/sysroot/<arch>`
- host clang 工具链：沿用 `cache/compiler-llvm-18.1.8-linux-<host>.tar.gz`
- 目标运行时：沿用 `stage0` 已经放进去的 glibc、compiler-rt、libunwind、libc++、libc++abi

当前 `stage1` 的 clang wrapper 已经改成直接消费 LLVM runtime，本层不再依赖 `llvm-gcc-overlay-staged` 那套 GCC 兼容壳来找 `libgcc.a / crtbeginS.o`。
做法是为每个 target triple 生成一个 synthetic clang `resource-dir`，把：

- host clang 自带的 builtin headers
- `stage0` rootfs 里的 `clang_rt.crtbegin.o`
- `stage0` rootfs 里的 `clang_rt.crtend.o`
- `stage0` rootfs 里的 `libclang_rt.builtins.a`

组合给 clang 使用。

构建时会先把 `stage0` rootfs 拷贝到当前 build 目录下，再往里面安装 `stage1` 的包。最终产物输出到：

`dist/stage1/<arch>`

目标机内的默认安装前缀是：

`/usr`

## 目录结构

- [CMakeLists.txt](/home/zarra/Documents/projects/develop-suit/stage1/CMakeLists.txt)
  负责顶层编排、rootfs staging、包注册
- [cmake/Stage1Helpers.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1Helpers.cmake)
  下载、选包、解压、host LLVM 解析等公共函数
- [cmake/Stage1Autotools.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1Autotools.cmake)
  通用 `stage1_add_autotools_package(...)`
- [cmake/Stage1CompressionPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1CompressionPackages.cmake)
  压缩库模块：`zlib / zstd / lz4 / bzip2 / xz`
- [cmake/Stage1CryptoPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1CryptoPackages.cmake)
  加密库模块：`openssl / ca-certificates`
- [cmake/Stage1ScriptingPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1ScriptingPackages.cmake)
  脚本语言模块：`perl`
- [cmake/perl-cross-local-ssh.sh.in](/home/zarra/Documents/projects/develop-suit/stage1/cmake/perl-cross-local-ssh.sh.in)
  Perl 专用的 local cross transport wrapper
- [cmake/Stage1TerminalPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1TerminalPackages.cmake)
  终端库模块：`ncurses / readline`
- [cmake/Stage1UtilityPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1UtilityPackages.cmake)
  实用工具模块：`patchelf / curl`
- [cmake/clang-target.sh.in](/home/zarra/Documents/projects/develop-suit/stage1/cmake/clang-target.sh.in)
  为 autotools 生成目标侧 clang/clang++ wrapper
- [prepare.sh](/home/zarra/Documents/projects/develop-suit/stage1/prepare.sh)
  安装 stage1 宿主依赖、host glibc、qemu/binfmt
- [build.sh](/home/zarra/Documents/projects/develop-suit/stage1/build.sh)
  命令行入口
- [image.sh](/home/zarra/Documents/projects/develop-suit/stage1/image.sh)
  基于 `dist/stage1/<arch>` 构建 Docker 镜像，可导出 tar 或直接推送 registry
- [Dockerfile](/home/zarra/Documents/projects/develop-suit/stage1/Dockerfile)
  通用 rootfs 镜像模板，通过 `ARG STAGE1_ARCH` 选择复制目录

## 目前实现的包

### autotools 组

这一组的目标范围是：

- GNU make
- GNU m4
- autoconf
- automake
- libtool
- pkg-config

当前已经实现并默认启用的是：

- GNU make
- GNU m4
- autoconf
- automake
- libtool
- pkg-config

GNU make 源码：

https://ftp.gnu.org/gnu/make/make-4.3.tar.gz

GNU m4 源码：

https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz

autoconf 源码：

https://ftp.gnu.org/gnu/autoconf/autoconf-2.73.tar.xz

automake 源码：

https://ftp.gnu.org/gnu/automake/automake-1.18.tar.xz

GNU libtool 源码：

https://ftpmirror.gnu.org/libtool/libtool-2.5.4.tar.gz

pkg-config 当前使用 `pkgconf` 提供，源码：

https://distfiles.ariadne.space/pkgconf/pkgconf-2.5.1.tar.xz

### ncurses

源码：

https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz

### readline

源码：

https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz

### openssl

源码：

https://github.com/openssl/openssl/releases/download/openssl-3.0.20/openssl-3.0.20.tar.gz

### ca-certificates

默认使用的 CA bundle 下载地址：

https://curl.se/ca/cacert.pem

### perl

源码：

https://cpan.metacpan.org/authors/id/S/SH/SHAY/perl-5.42.2.tar.gz

### 实用工具

patchelf 源码：

https://github.com/NixOS/patchelf/releases/download/0.15.5/patchelf-0.15.5.tar.gz

curl 源码：

https://curl.se/download/curl-8.20.0.tar.gz

## 构建方式

如果是第一次在新宿主机上跑，先准备依赖：

```bash
./stage1/prepare.sh
```

这个脚本当前会自动区分：

- 本机 Ubuntu 26.04：安装 `qemu-user + qemu-user-binfmt`
- GitHub Actions 常见 Ubuntu 24.04：安装 `qemu-user-static`

直接调用：

```bash
./stage1/build.sh --arch=aarch64 --clean --jobs=4
```

或：

```bash
./stage1/build.sh --arch=x86_64 --clean --jobs=4
```

构建对应架构的 Docker 镜像 tar：

```bash
./stage1/image.sh --arch=aarch64
```

或：

```bash
./stage1/image.sh arch=loongarch64
```

默认输出到：

`dist/images/stage1-image-<arch>.tar`

镜像构建成功后，`image.sh` 会自动拉起一个容器做 smoke test，当前覆盖：

- `make --version`
- `autoconf --version`
- `automake --version`
- `pkg-config --version`
- `pkg-config --cflags --libs openssl zlib libcurl`
- `curl https://api.ipify.org`
- `perl -v`
- `perl hello world`
- 一个基础 Perl 算术脚本测试

如果只想构建镜像、不跑测试：

```bash
./stage1/image.sh --arch=aarch64 --skip-test
```

如果要直接推送到 GHCR 或其他 registry：

```bash
./stage1/image.sh \
  --arch=aarch64 \
  --push \
  --tag=ghcr.io/<owner>/<repo>:stage1-2026-05-03
```

常用参数：

- `--input-rootfs-dir=<path>`
  指定 `stage0` 输出，默认是 `dist/sysroot/<arch>`
- `--dist-dir=<path>`
  指定最终输出目录，默认是 `dist/stage1/<arch>`
- `--install-prefix=<path>`
  指定目标机内安装前缀，默认 `/usr`
- `--llvm-archive=<path>` / `--clang-root=<path>`
  覆盖 host clang 来源
- `--make-archive=<path>` / `--m4-archive=<path>` / `--autoconf-archive=<path>` / `--automake-archive=<path>`
  覆盖 autotools 相关源码包
- `--libtool-archive=<path>` / `--pkg-config-archive=<path>`
  覆盖源码包
- `--patchelf-archive=<path>` / `--curl-archive=<path>`
  覆盖实用工具源码包
- `--make-source-dir=<path>` / `--m4-source-dir=<path>` / `--autoconf-source-dir=<path>` / `--automake-source-dir=<path>`
  直接使用已解压的 autotools 相关源码
- `--libtool-source-dir=<path>` / `--pkg-config-source-dir=<path>`
  直接使用已解压源码
- `--patchelf-source-dir=<path>` / `--curl-source-dir=<path>`
  直接使用已解压的实用工具源码

如果 `cache/` 里缺少源码包，CMake 默认会自动下载。

## GitHub Actions

工作流文件：

- [.github/workflows/stage1-rootfs.yml](/home/zarra/Documents/projects/develop-suit/.github/workflows/stage1-rootfs.yml)

当前 workflow 会：

- 先用 `build.sh` 分别构建 `x86_64 / aarch64 / riscv64 / loongarch64` 四套 rootfs
- 最终只发布一个给客户端使用的多架构 GHCR tag：
  `ghcr.io/<owner>/<repo>:stage1-YYYY-MM-DD`
- `docker` / `podman` 客户端会按自身架构自动拉取对应镜像

workflow 内部仍会使用一次性的临时架构 tag 来拼 multi-arch manifest，但这不是对外约定的最终 tag。

如果勾选 `publish_release`，workflow 仍然会把四套 `rootfs` 压缩包发布到 GitHub Release。

## 交叉编译实现方式

`stage1` 不是写死某个架构，而是围绕 `STAGE1_TARGET_TRIPLE` 组织：

- `CC` / `CXX` 使用 clang wrapper
- wrapper 自动带上 `--target=<triple>`
- wrapper 自动带上 `--sysroot=<stage1-rootfs>`
- wrapper 自动补：
  - `--rtlib=compiler-rt`
  - `--unwindlib=libunwind`
  - `-resource-dir=<generated-resource-dir>`
  - `-L<rootfs>/usr/lib/<triple>`
- `clang++` wrapper 额外补：
  - `-stdlib=libc++`

通用 autotools 包函数会统一执行：

- `configure --host=<target> --build=<host>`
- `make`
- `make DESTDIR=<rootfs> install`

`perl` 比普通 autotools 包更特殊一些。当前模块里已经把它单独收口，并且 native / cross 都统一走 Perl 自己的 cross 流程：

- `./Configure -des -Dusecrosscompile`
- 模块会自动生成一个本地 `ssh + cp` transport，让 Perl 的 `Cross/run-* / to-* / from-*` 机制真正跑起来
- `Configure` 阶段不会继承通用 `CC/CXX` 环境变量，而是只通过 `-Dcc/-Dld/-Dar/-Dnm/-Dranlib` 指定 target 工具链，避免把 `host/miniperl` 误编译成 target 程序
- native 构建已经可以直接跑通
- 真正的 foreign-arch 交叉编译，要求目标程序在宿主机上可执行，通常需要 `binfmt_misc + qemu-user` 或等价机制；必要时可以通过 `STAGE1_PERL_LOCAL_SSH_PRELUDE` 补充本地运行前置环境

`perl` 不是所有 `stage1` 包都必须依赖的。像 `make`、压缩库、`openssl` 这类包并不要求目标 rootfs 里先有 Perl。
但如果你的目标是把一套可运行的 autotools 生态放进 rootfs，那么 Perl 仍然建议保留，因为 `autoconf`、`automake` 本身和后面很多传统 GNU 包都会直接或间接依赖它。

## 当前限制

`autoconf`、`automake`、`libtool` 这些包虽然已经可以作为目标包交叉编译并安装进 rootfs，但要在目标机真正“好用”，还需要补齐它们的运行时依赖，至少包括：

- `perl`
- `m4`
- POSIX shell 及常见基础工具

所以当前 `stage1` 的重点是先验证“通用交叉编译框架”成立，不代表整套 autotools 生态已经完全自举完成。

另外，宿主机构建这些包时也需要一些基础工具。当前已明确依赖：

- `perl`
- `m4`

如果宿主机没有 `m4`，`make` 和 `pkg-config` 仍然可以先构建，但 `autoconf/automake/libtool` 大概率会失败。

## 后续候选包

下面这些仍然是后续阶段准备继续接入的候选项，还没有在当前 `stage1` CMake 里全部实现。

其中压缩相关的 4 个包已经单独收敛到：

- [cmake/Stage1CompressionPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1CompressionPackages.cmake)

当前这个模块里先统一维护它们的 archive/source/url 变量：

- zlib
- zstd
- bzip2
- xz

终端相关包已经单独收敛到：

- [cmake/Stage1TerminalPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1TerminalPackages.cmake)

当前这个模块里先统一维护：

- ncurses
- readline

加密相关包已经单独收敛到：

- [cmake/Stage1CryptoPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1CryptoPackages.cmake)

当前这个模块里先统一维护：

- openssl
- ca-certificates

脚本语言相关包已经单独收敛到：

- [cmake/Stage1ScriptingPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1ScriptingPackages.cmake)

实用工具相关包已经单独收敛到：

- [cmake/Stage1UtilityPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1UtilityPackages.cmake)

patchelf
https://github.com/NixOS/patchelf/releases/download/0.15.5/patchelf-0.15.5.tar.gz

curl
https://curl.se/download/curl-8.20.0.tar.gz


- llvm + clang + lld
  https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz

如果后面要扩包，优先建议继续复用 `stage1_add_autotools_package(...)`；只有碰到 CMake 项目、Meson 项目或者特殊 bootstrap 包，再分别加新的 helper 模块。
