# osxcross package

这个 package 只负责构建 osxcross 相关的四个组件：

- `xar`
- `libtapi`
- `libLTO` 从 LLVM SDK 安装到 osxcross 输出前缀
- `cctools`
- osxcross compiler wrapper
- osxcross CMake helper
- osxcross MacPorts helper
- 上游 osxcross SDK 制作脚本

LLVM SDK 和 LLVM dependency 的构建已经拆到：

- `packages/llvm_dependencies`
- `packages/llvm`

## 构建模型

- build 容器默认使用 `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- host 架构外部依赖来自 `llvm_dependencies` 前缀，只作为 headers/libs 使用
- host 架构 LLVM SDK 只提供 `libLLVM`、`libLTO`、LLVM headers 和 `llvm-config` 信息
- host 架构 LLVM SDK 的 `bin` 不进入 `PATH`
- `libLLVM` / `libLTO` 只从 LLVM SDK 复制到 osxcross 输出前缀，不在 osxcross package 内重新构建 LLVM
- macOS SDK 不进入 release 产物；使用者需要从自己的 Xcode 或 Xcode Command Line
  Tools 制作 `MacOSX13.3.sdk.tar.xz` 后自行解压到 `SDK/`
- 上游源码只从 `upstream/` 复制到容器构建目录，不直接修改
- 需要改上游源码时，只允许通过 `patch` 文件和 `patch` 命令

## 用法

```sh
./packages/osxcross/build.sh --arch=x86_64 --clean --jobs=4
```

默认查找：

```text
packages/llvm_dependencies/build/out/llvm_dependencies-<triple>
packages/llvm_dependencies/build/dist/llvm_dependencies-<triple>.tar.xz
packages/llvm/build/out/llvmsdk-18.1.8-<triple>
packages/llvm/build/dist/llvmsdk-18.1.8-<triple>.tar.xz
```

也可以显式指定：

```sh
./packages/osxcross/build.sh \
  --arch=loongarch64 \
  --llvm-deps-archive=/abs/path/to/llvm_dependencies-loongarch64-unknown-linux-gnu.tar.xz \
  --llvmsdk-archive=/abs/path/to/llvmsdk-18.1.8-loongarch64-unknown-linux-gnu.tar.xz \
  --jobs=4
```

也可以直接指定已解压前缀：

```sh
./packages/osxcross/build.sh \
  --arch=loongarch64 \
  --llvm-deps-dir=/abs/path/to/llvm_dependencies-loongarch64-unknown-linux-gnu \
  --llvmsdk-dir=/abs/path/to/llvmsdk-18.1.8-loongarch64-unknown-linux-gnu \
  --jobs=4
```

## 输出

```text
packages/osxcross/build/out/osxcross-18.1.8-<triple>
packages/osxcross/build/dist/osxcross-18.1.8-<triple>.tar.xz
```

产物里的 `tools/` 目录保留了上游 osxcross 的 SDK 制作脚本：

```sh
./tools/gen_sdk_package.sh
./tools/gen_sdk_package_tools.sh
```

在 macOS 上用自己的 Xcode 或 Command Line Tools 生成 SDK 包后，复制到 Linux
主机并解压：

```sh
mkdir -p osxcross-18.1.8-<triple>/SDK
tar -xf MacOSX13.3.sdk.tar.xz -C osxcross-18.1.8-<triple>/SDK
```
