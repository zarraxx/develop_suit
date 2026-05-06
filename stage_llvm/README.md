# stage_llvm

`stage_llvm` 从 `stage_python` 的 rootfs 出发，产出一个 host clang 工具链 rootfs：

- clang 本体运行在 `--arch` 指定的 host 架构上
- clang 的默认 target 是这个 host 自己的 triple
- 同时把 4 个 Linux target 的 sysroot 和 LLVM runtimes 一起放进去

当前目标 target 固定为：

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`

## 输出布局

默认输出目录：

- `dist/stage_llvm/<arch>`

其中关键内容是：

- `/opt/llvm-18.1.8`
- `/opt/sysroot/<triple>`

LLVM 工具链里会包含：

- `bin/clang`
- `bin/clang++`
- `bin/lld`
- `bin/ld.lld`
- `bin/<triple>-clang-gcc`
- `bin/<triple>-clang-g++`

target driver 的 clang `.cfg` 配置会自动补：

- `--target=<triple>`
- `--sysroot=/opt/sysroot/<triple>`
- `-B.../lib/clang/18/lib/<triple>`
- `--rtlib=compiler-rt`
- `--unwindlib=libunwind`

`clang-g++` C++ 入口还会补 `-stdlib=libc++`。

## 运行方式

和 `stage1` / `stage_python` 一样，直接跑：

```bash
./stage_llvm/build.sh --arch=x86_64 --clean --jobs=4
```

比如从当前机器交叉产出一个 `aarch64` host clang：

```bash
./stage_llvm/build.sh --arch=aarch64 --clean --jobs=4
```

构建镜像：

```bash
./stage_llvm/image.sh --arch=x86_64
```

构建完成后可以直接跑冒烟测试，检查 `helloworld.c` / `helloworld.cpp` 是否都能编成 4 个平台的 ELF：

```bash
./stage_llvm/smoke-test.sh dist/stage_llvm/x86_64/opt/llvm-18.1.8
```

也可以指定输出目录，脚本会把 8 个 hello world ELF 写到这里，方便在宿主机继续用 `file` 检查：

```bash
./stage_llvm/smoke-test.sh dist/stage_llvm/x86_64/opt/llvm-18.1.8 /tmp/stage_llvm-smoke-out
file /tmp/stage_llvm-smoke-out/*
```

如果不传参数，脚本会默认找：

```text
dist/stage_llvm/<当前机器架构>/opt/llvm-18.1.8
```

GitHub Actions workflow 也已经对齐 `stage1` / `stage_python`，可以发布：

- rootfs artifact
- GHCR 多架构镜像
- 可选 GitHub Release

默认镜像 tag 形如：

```text
stage-llvm-YYYY-MM-DD
```

## 设计约定

- `--arch` 表示“生成出来的 clang 自己运行在哪个 host 架构上”
- 这不是“我要给哪个 target 编译程序”
- 所以 `--arch=x86_64` 产出的 clang 默认 target 就是 `x86_64-unknown-linux-gnu`
- 但它仍然会带上 4 个 target 的 sysroot 和 runtimes

换句话说：

- `x86_64` host clang 默认编 `x86_64`
- `aarch64` host clang 默认编 `aarch64`
- 但它们都可以继续编另外 3 个 target

## 默认输入

默认会使用：

- 输入 rootfs：`dist/stage_python/<arch>`
- LLVM 源码：`cache/llvm-project-18.1.8.src.tar.xz`
- sysroot 包：优先 `prebuild/sysroot-15.2.0`，否则 `cache/sysroot-15.2.0-linux.tar.xz`
- bootstrap clang：优先本地 `prebuild/compiler-llvm-18.1.8/llvm-18.1.8`，否则 `cache/compiler-llvm-18.1.8-linux-<arch>.tar.gz`

如果找不到 bootstrap clang，这一版会退回系统里的 `cc/c++` 来构建 host LLVM。

## 注意

- 这一步生成的是 host clang，但构建过程本身仍然按 cross 模型走
- 例如可以在 `x86_64` 机器上运行 `--arch=aarch64`，产出能在 `aarch64` 上运行的 clang
- 构建 host clang 时，LLVM/clang/compiler-rt/libunwind/libc++ 仍然是由当前 build machine 驱动完成
- 最终产物会把 4 个 target 的 sysroot/runtime 一起打包进去
