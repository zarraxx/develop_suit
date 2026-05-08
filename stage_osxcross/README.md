build.sh 是一个构建 osxcross 的实验 基本成功，但是有很多不完善的地方

需要构建 custom_build.sh 和  container_custom_build.sh 修改 osxcross的 build.sh

当前 custom 构建模型：
- build 容器固定优先使用 x86_64 的 stage_llvm 镜像
- host 架构的 /usr 依赖来自 stage_python rootfs，只作为 headers/libs 使用
- host 架构的 /usr/bin 不进入 PATH，Python 等构建期工具必须使用 build 容器自身的 x86_64 工具

LLVM SDK 实验构建：
- `build_llvm_sdk.sh` 构建一个不包含 clang、lld、clang-tools-extra 的 LLVM SDK。
- 容器内先通过 `mount_root/container_llvm_dep.sh` 构建 host 侧依赖：
  zlib、zstd、libxml2、libiconv、ncursesw、readline、libffi、gettext。
- 再通过 `mount_root/container_llvm_sdk.sh` 构建 LLVM、libLLVM、libLTO 和 LLVM 工具。
- Linux SDK 会把 stage_llvm 里对应 triple 的
  `libc++.so*`、`libc++abi.so*`、`libunwind.so*` 一起复制到 SDK `lib/`，
  配合 LLVM 工具的 `$ORIGIN/../lib` runpath 直接运行。
- LLVM 默认构建 `LLVM_TARGETS_TO_BUILD=all` 和
  `LLVM_EXPERIMENTAL_TARGETS_TO_BUILD=all`，由 LLVM 18.1.8 自己展开全部稳定后端和实验后端。
- Linux 产物名：
  `llvmsdk-18.1.8-<arch>-unknown-linux-gnu.tar.xz`
- 同时发布可复用依赖包：
  `llvm_dependencies-<triple>.tar.xz`
- Windows GNU 产物使用 target triple：
  `x86_64-w64-windows-gnu`

1 尽可能的支持 用 build x86_64的  clang 交叉编译 host=aarch64 riscv64 和 loongarch64 的xar libtapi 和 cctools
我试了在 native loongarch64 好像 版本老  xar 不能configure

2 修复 需要 手动 的问题
ln -sf libtinfow.so libtinfo.so
ln -sf libncursesw.so libncurses.so
使libtapi 支持  libtinfow.so  libncursesw.so 
3 处理需要 

ln -s $LLVM_HOME/bin/clang $LLVM_HOME/bin/gcc
ln -s $LLVM_HOME/bin/clang++ $LLVM_HOME/bin/g++
ln -s $LLVM_HOME/bin/llvm-ar $LLVM_HOME/bin/ar
ln -s $LLVM_HOME/bin/llvm-ranlib $LLVM_HOME/bin/ranlib
ln -s $LLVM_HOME/bin/llvm-strip $LLVM_HOME/bin/strip
ln -s $LLVM_HOME/bin/llvm-strings $LLVM_HOME/bin/strings
ln -s $LLVM_HOME/bin/llvm-as $LLVM_HOME/bin/as
ln -s $LLVM_HOME/bin/lld $LLVM_HOME/bin/ld
ln -s $LLVM_HOME/bin/llvm-size $LLVM_HOME/bin/size

的问题 和交叉编译一并处理

4 缓存MacOSX13.3.sdk.tar.xz  ，如果 全局变量 和 .env 没有 url 和 pass 在cli 询问

5 本osxcross 因为 授权原因，不在action 构建，发布release 前 检查 删除mac os sdk
并提供 从apple 下载和创建sdk的说明 参考 osxcross

6 upstream 是 git clone 的上游文件 已经checkout 对应的分支，在容器内复制到 /build
不要修改upstream 内的文件
使用patch 修改upsteam 文件，不用 sed shell 修改
