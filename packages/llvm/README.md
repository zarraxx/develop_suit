# llvm package

构建不包含 clang、lld、clang-tools-extra 的 LLVM SDK：

- `LLVM`
- `libLLVM`
- `libLTO`
- LLVM tools

外部依赖来自 `packages/llvm_dependencies` 发布的 tarball。

## 用法

先构建同版本 native LLVM helper tools，给后续交叉构建复用：

```sh
./packages/llvm/build_native_tools.sh \
  --llvm-version=22.1.5 \
  --bootstrap-llvm-version=18.1.8 \
  --clean \
  --jobs=4
```

再构建目标 SDK：

```sh
./packages/llvm/build.sh \
  --target=x86_64 \
  --llvm-version=22.1.5 \
  --bootstrap-llvm-version=18.1.8 \
  --dependency-archive=packages/llvm_dependencies/build/dist/llvm_dependencies-x86_64-unknown-linux-gnu.tar.xz \
  --native-tools-archive=packages/llvm/build/dist/native_llvmsdk-22.1.5-x86_64-unknown-linux-gnu.tar.xz \
  --clean \
  --jobs=4
```

默认构建镜像：

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## 输出

```text
packages/llvm/build/out/native_llvmsdk-<version>-x86_64-unknown-linux-gnu
packages/llvm/build/dist/native_llvmsdk-<version>-x86_64-unknown-linux-gnu.tar.xz

packages/llvm/build/out/llvmsdk-<version>-<triple>
packages/llvm/build/dist/llvmsdk-<version>-<triple>.tar.xz
```
