# stage1

`stage1` 的目标是在 `stage0` 产出的最小 rootfs 之上，继续放入一批“目标机可运行”的开发工具。

当前这一层先不追求一次把所有工具都堆满，重点是先把一套可复用的交叉编译框架搭好。现在已经接入的是：

- GNU make
- autoconf
- automake

这些包都通过 CMake 统一调度，但真正的构建方式仍然是各自原生的 autotools 流程。这样后面继续接 `bison`、`flex`、`m4`、`pkg-config`、`cmake`、`ninja`、`openssl` 之类包时，不需要把顶层 `CMakeLists.txt` 写成面条。

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

另外，在 rootfs staging 时会额外写入：

`/etc/profile.d/stage1-env.sh`

里面会补一份最小环境，包括：

- `PATH`
- `LD_LIBRARY_PATH`

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
  加密库模块：`openssl`
- [cmake/Stage1TerminalPackages.cmake](/home/zarra/Documents/projects/develop-suit/stage1/cmake/Stage1TerminalPackages.cmake)
  终端库模块：`ncurses / readline`
- [cmake/clang-target.sh.in](/home/zarra/Documents/projects/develop-suit/stage1/cmake/clang-target.sh.in)
  为 autotools 生成目标侧 clang/clang++ wrapper
- [build.sh](/home/zarra/Documents/projects/develop-suit/stage1/build.sh)
  命令行入口

## 目前实现的包

### GNU make

源码：

https://ftp.gnu.org/gnu/make/make-4.3.tar.gz

### autoconf

源码：

https://ftp.gnu.org/gnu/autoconf/autoconf-2.73.tar.xz

### automake

源码：

https://ftp.gnu.org/gnu/automake/automake-1.18.tar.xz

### ncurses

源码：

https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz

### readline

源码：

https://ftp.gnu.org/gnu/readline/readline-8.3.tar.gz

### openssl

源码：

https://github.com/openssl/openssl/releases/download/openssl-3.0.20/openssl-3.0.20.tar.gz

## 构建方式

直接调用：

```bash
./stage1/build.sh --arch=aarch64 --clean --jobs=4
```

或：

```bash
./stage1/build.sh --arch=x86_64 --clean --jobs=4
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
- `--make-archive=<path>` / `--autoconf-archive=<path>` / `--automake-archive=<path>`
  覆盖源码包
- `--make-source-dir=<path>` / `--autoconf-source-dir=<path>` / `--automake-source-dir=<path>`
  直接使用已解压源码

如果 `cache/` 里缺少源码包，CMake 默认会自动下载。

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

## 当前限制

`autoconf` 和 `automake` 虽然已经可以作为目标包交叉编译并安装进 rootfs，但要在目标机真正“好用”，还需要补齐它们的运行时依赖，至少包括：

- `perl`
- `m4`
- POSIX shell 及常见基础工具

所以当前 `stage1` 的重点是先验证“通用交叉编译框架”成立，不代表整套 autotools 生态已经完全自举完成。

另外，宿主机构建这些包时也需要一些基础工具。当前已明确依赖：

- `perl`
- `m4`

如果宿主机没有 `m4`，`make` 仍然可以先构建，但 `autoconf/automake` 大概率会失败。

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

m4
https://ftp.gnu.org/gnu/m4/m4-1.4.21.tar.xz

perl:
https://cpan.metacpan.org/authors/id/S/SH/SHAY/perl-5.42.2.tar.gz


pkg-config:
https://distfiles.ariadne.space/pkgconf/pkgconf-2.5.1.tar.xz

- cmake 4
  https://github.com/Kitware/CMake/releases/download/v4.3.2/cmake-4.3.2.tar.gz
- cmake 3
  https://cmake.org/files/v3.27/cmake-3.27.9.tar.gz
- ninja
  https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.2.tar.gz
- bison
  https://ftp.gnu.org/gnu/bison/bison-3.8.tar.xz
- flex
  https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz
- llvm + clang + lld
  https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz

如果后面要扩包，优先建议继续复用 `stage1_add_autotools_package(...)`；只有碰到 CMake 项目、Meson 项目或者特殊 bootstrap 包，再分别加新的 helper 模块。
