# osxcross package

这个 package 只负责构建 osxcross 相关的四个组件：

- `xar`
- `libtapi`
- `libLTO` 从 LLVM SDK 安装到 osxcross 输出前缀
- `cctools`

LLVM SDK 和 LLVM dependency 的构建已经拆到：

- `packages/llvm_dependencies`
- `packages/llvm`

## 构建模型

- build 容器默认使用 `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- host 架构依赖来自本地 LLVM SDK 前缀，只作为 headers/libs 使用
- host 架构 LLVM SDK 的 `bin` 不进入 `PATH`
- `libLLVM` / `libLTO` 只从 LLVM SDK 复制到 osxcross 输出前缀，不在 osxcross package 内重新构建 LLVM
- 上游源码只从 `upstream/` 复制到容器构建目录，不直接修改
- 需要改上游源码时，只允许通过 `patch` 文件和 `patch` 命令

## 用法

```sh
./packages/osxcross/build.sh --arch=x86_64 --clean --jobs=4
```

默认查找：

```text
packages/llvm/build/out/llvmsdk-18.1.8-<triple>
packages/llvm/build/dist/llvmsdk-18.1.8-<triple>.tar.xz
```

也可以显式指定：

```sh
./packages/osxcross/build.sh \
  --arch=loongarch64 \
  --llvmsdk-dir=/abs/path/to/llvmsdk-18.1.8-loongarch64-unknown-linux-gnu \
  --jobs=4
```

## 输出

```text
packages/osxcross/build/out/<arch>/osxcross
```
