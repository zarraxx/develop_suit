# llvm package

构建不包含 clang、lld、clang-tools-extra 的 LLVM SDK：

- `LLVM`
- `libLLVM`
- `libLTO`
- LLVM tools

外部依赖来自 `packages/llvm_dependencies` 发布的 tarball。

## 用法

```sh
./packages/llvm/build.sh \
  --target=x86_64 \
  --dependency-archive=packages/llvm_dependencies/build/dist/llvm_dependencies-x86_64-unknown-linux-gnu.tar.xz \
  --clean \
  --jobs=4
```

默认构建镜像：

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## 输出

```text
packages/llvm/build/out/llvmsdk-18.1.8-<triple>
packages/llvm/build/dist/llvmsdk-18.1.8-<triple>.tar.xz
```
