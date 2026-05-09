# packages

`packages/` 用 stage 阶段产出的 Docker 镜像继续构建可发行的软件包。
这里的包不是 rootfs stage，而是面向后续工具链复用的多架构产物，例如
LLVM 外部依赖、LLVM SDK、osxcross 组件。

## 支持目标

当前统一支持这些目标：

```text
x86_64-unknown-linux-gnu
aarch64-unknown-linux-gnu
riscv64-unknown-linux-gnu
loongarch64-unknown-linux-gnu
x86_64-w64-windows-gnu
```

Linux 目标按交叉编译处理，即使目标架构和构建机同为 `x86_64` 也不要走
特殊 native shortcut。Windows GNU 目标统一使用 `x86_64-w64-windows-gnu`，
不要再新增 `x86_64-w64-mingw32` 作为包名或最终三元组。

## 现有包边界

- `llvm_dependencies`
  构建 LLVM SDK 可复用的外部依赖，例如 zlib、zstd、lz4、bzip2、
  xz/liblzma、libxml2、libiconv、OpenSSL、ncurses/readline、libffi、
  gettext。这个包只产出依赖前缀和 tarball。
- `llvm`
  构建不包含 clang、lld、clang-tools-extra 的 LLVM SDK。外部依赖必须来自
  `llvm_dependencies` 的 tarball。SDK 产出 `libLLVM`、`libLTO`、LLVM headers
  和 LLVM tools。
- `osxcross`
  只负责 osxcross 相关组件：`xar`、`libtapi`、从 LLVM SDK 复制来的
  `libLTO/libLLVM`、`cctools`。它不重新构建 LLVM，也不把 host 架构 LLVM SDK
  的 `bin` 放进 `PATH`。

`packages/*/upstream/**/README*` 属于第三方上游说明，只作为参考，不是本仓库
的构建规范来源。仓库规范以本文件、各 package 的顶层 `README.md` 和
`AGENTS.md` 为准。

## 目录和命名

package 目录名使用下划线，不使用连字符，例如：

```text
packages/llvm_dependencies
```

每个 package 至少包含：

```text
packages/<package>/README.md
packages/<package>/build.sh
packages/<package>/mount_root/
```

推荐结构：

```text
packages/<package>/mount_root/container_linux_native.sh
packages/<package>/mount_root/container_linux_cross.sh
packages/<package>/mount_root/container_mingw64.sh
packages/<package>/mount_root/patch/
packages/<package>/mount_root/templates/
```

如果多个目标入口共用大段逻辑，可以像 `llvm` 和 `llvm_dependencies` 一样把
公共实现放到 `container_<name>.sh`，由 `container_linux_native.sh`、
`container_linux_cross.sh`、`container_mingw64.sh` 转入同一个实现脚本。

公共 shell 逻辑放在：

```text
packages/shell_tools/var.sh
packages/shell_tools/tools.sh
packages/shell_tools/autotools_utils.sh
packages/shell_tools/cmake_utils.sh
```

- `var.sh` 放默认变量，例如默认构建镜像、默认 jobs。
- `tools.sh` 放通用函数，例如 `die`、`require_command`、`render_template`、
  `make_host_writable`、目标三元组解析。
- 新的下载、三元组、autotools、CMake、Meson 辅助逻辑应优先沉到
  `packages/shell_tools/`，不要在每个包里复制一份。

## build.sh 约定

每个 package 的 `build.sh` 是宿主侧唯一入口，负责：

- 解析 `--target` 或 `--arch`
- 解析 `--clean`
- 解析 `--jobs=<n>`
- 解析包需要的版本、镜像、输入 tarball 参数
- 挂载 `packages/shell_tools` 到容器内
- 挂载 package 的 `mount_root`
- 挂载 `cache`
- 挂载该 package 的 `build/work`、`build/out`、`build/dist`
- 调用容器内入口脚本
- 最终从 `build/out/<package-name>` 打包到 `build/dist/<package-name>.tar.xz`

目标解析必须复用 `packages/shell_tools/tools.sh` 里的 `resolve_target` 或与它
保持一致。

默认构建镜像目前统一为：

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## README 必填内容

每个 package 的顶层 `README.md` 必须说明：

- package 的职责边界，特别是它不负责什么
- 输入来源，例如依赖 tarball、上游源码目录、SDK 前缀
- 支持的目标/架构
- 默认构建镜像
- 本地构建命令示例
- 输出目录和 tarball 名称
- 对每个上游软件包实际使用的配置、编译、安装命令

上游软件包命令说明至少要覆盖：

```text
configure/cmake/meson 命令和关键参数
build 命令和参数，例如 make -j4 或 ninja -j4
install 命令和参数，例如 make install DESTDIR=...
额外执行的复制、模板渲染、验证、打包命令
```

如果同一个包在 Linux 和 mingw64 下参数不同，README 必须分开写清楚。文档可以
按软件包分组，不需要把整段构建脚本复制进去，但关键开关必须能从 README 看懂。

## 上游源码修改规则

所有对上游包代码的修改必须使用显式 patch 文件和 `patch` 命令：

```text
packages/<package>/mount_root/patch/*.patch
```

禁止使用 `sed -i`、`perl -pi`、Python、CMake 脚本、shell 重定向生成源码片段
等方式直接或间接修改已解压的上游源码。

生成配置文件、README、pkg-config 文件、wrapper 脚本等本项目自己的文件时，
优先使用：

```text
packages/<package>/mount_root/templates/*.in
render_template
```

不要在 shell 脚本里写大段 here-doc 或 `cat > file` 文本。

## 动态库和静态库政策

包产物优先提供动态库：

- 能关闭静态库构建就关闭。
- 上游不能关闭静态库时，安装后删除普通 `.a` 和 `.la`。
- mingw64 的 import library `*.dll.a` 是动态 DLL 链接所需，必须保留。
- 像 compiler-rt、LLVM component archive 这类确实需要的静态库可以保留，但要在
  对应 README 或脚本上下文里能看出原因。

这样做是为了避免一个程序同时引入静态 `libz` 和动态 `libz` 之类的混合链接问题。

## 当前 release 约定

- LLVM dependencies:
  `llvm_dependencies-<triple>.tar.xz`
- LLVM SDK:
  `llvmsdk-18.1.8-<triple>.tar.xz`
- osxcross:
  `osxcross-18.1.8-<triple>.tar.xz`

GitHub Actions 的 5 架构矩阵应覆盖四个 Linux 目标和一个 mingw64 目标。
osxcross 只覆盖四个 Linux host 目标，不发布 mingw64 目标。
