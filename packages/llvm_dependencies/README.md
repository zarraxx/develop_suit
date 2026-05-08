# llvm_dependencies package

构建 LLVM SDK 可复用的外部依赖：

- zlib
- zstd
- libxml2
- libiconv
- OpenSSL
- ncurses/readline
- libffi
- gettext

Linux 目标的 ncurses/readline 使用 Debian 类似参数；mingw64 目标使用 MSYS2 类似参数。

## 用法

```sh
./packages/llvm_dependencies/build.sh --target=x86_64 --clean --jobs=4
./packages/llvm_dependencies/build.sh --target=mingw64 --clean --jobs=4
```

默认构建镜像：

```text
ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8
```

## 输出

```text
packages/llvm_dependencies/build/out/llvm_dependencies-<triple>
packages/llvm_dependencies/build/dist/llvm_dependencies-<triple>.tar.xz
```
