# stage0

`stage0` 用来生成后续阶段可复用的最小基础层。当前这层的目标很明确：

- `glibc` 基础 sysroot
- LLVM target runtimes: `compiler-rt;libcxx;libcxxabi;libunwind`
- `busybox`

也就是说，`stage0` 最终产物不是完整工具链，而是一个最小 target rootfs / sysroot 基础层，供后续阶段继续扩展。

## 当前设计

当前实现采用下面这条链路：

1. 使用一个已经能在宿主机运行的 `clang/lld` 作为外部工具链输入。
2. 解包目标架构的基础 `glibc sysroot`。
3. 从 `llvm-project` 源码为目标 triple 分三阶段构建 LLVM runtimes。
4. 先安装 `compiler-rt`，产出 `libclang_rt.builtins.a` 和 `clang_rt.crtbegin/crtend.o`。
5. 把这些文件整理成 clang 自己能识别的 target resource/crt 布局，而不是伪造 `lib/gcc/<triple>/...`。
6. 第二轮只构建 `libunwind`。
7. 第三轮再构建 `libc++abi/libc++`，并继续使用同一个 `clang --target=... --sysroot=...` 构建安装 `busybox`。

这里有一个重要边界：

- `stage0` 当前不会从源码构建 host 侧 `clang`、`lld`、binutils。
- `stage0` 当前会把 `llvm-project` 源码当作必需外部依赖，用它来构建 target runtimes。
- `busybox` 构建顺序固定在 runtimes 之后。

这正对应你现在想要的最小闭环：

`glibc + clang rt + busybox`

## 为什么这样拆

这是为了把“host 上运行的编译器”和“target 上运行的 runtime”分开：

- `clang/lld` 必须先是 host 可执行程序，否则它无法驱动交叉编译。
- `compiler-rt/libc++/libc++abi/libunwind` 如果要进入 target sysroot，就必须按 target triple 单独构建。
- 真正的交叉场景里，`libunwind/libc++abi/libc++` 不能假设 host clang 自带对应 target 的 `crtbeginS.o/crtendS.o/libclang_rt.builtins.a`，所以这里先用 `compiler-rt` 补齐 target startup/builtins，再继续后两轮。
- `busybox` 是 target 产物，应当在 target sysroot 已就绪之后再编译安装。

所以对 `stage0` 而言，更合适的模型不是“先在这里完整自举一套 LLVM”，而是：

- 输入一个 host 可执行的 LLVM 工具链
- 输出一个最小 target rootfs

## 外部依赖

当前约定的输入如下：

| 组件 | 作用 | URL |
| --- | --- | --- |
| `llvm-project source` | 必需，用于构建 target LLVM runtimes | `https://github.com/llvm/llvm-project/releases/download/llvmorg-18.1.8/llvm-project-18.1.8.src.tar.xz` |
| `compiler-llvm-18.1.8-linux-x86_64.tar.gz` | x86_64 host 可执行 clang/lld 预构建包 | `https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-x86_64.tar.gz` |
| `compiler-llvm-18.1.8-linux-aarch64.tar.gz` | aarch64 host 可执行 clang/lld 预构建包 | `https://github.com/zarraxx/package_builder/releases/download/compiler-llvm-18.1.8/compiler-llvm-18.1.8-linux-aarch64.tar.gz` |
| `sysroot-15.2.0-linux.tar.xz` | 基础 target sysroot，包含 glibc 等内容 | `https://github.com/zarraxx/package_builder/releases/download/sysroot-15.2.0/sysroot-15.2.0-linux.tar.xz` |
| `busybox-1.37.0.tar.bz2` | 最小用户态工具集 | `https://busybox.net/downloads/busybox-1.37.0.tar.bz2` |

注意：

- `llvm-project` 源码包现在是必需输入，不再只是“未来可能用到”。
- 预构建 clang 包只负责提供 host 可执行的 `clang/lld/llvm-ar/...`。
- target runtime 来自源码构建，而不是直接从 host 工具链里拷贝。
- 如果这些压缩包不在 `cache/` 里，CMake 默认会自动下载到 `cache/`。

## 目标架构

计划支持：

- `x86_64`
- `aarch64`
- `riscv64`
- `loongarch64`

当前 CMake 没有把 host 架构或 target 架构写死：

- host 侧 LLVM 预构建包默认按当前宿主机架构自动挑选
- target 侧完全由 `STAGE0_TARGET_TRIPLE` 驱动
- sysroot 路径从解压结果中按 target triple 推导

## 目录约定

建议的工作目录结构：

| 路径 | 用途 |
| --- | --- |
| `cache/` | 依赖压缩包缓存 |
| `build/<arch>/` | 每个架构的 CMake 构建目录 |
| `dist/sysroot/<arch>/` | 最终发布/消费用产物 |
| `stage0-work/prebuild/` | 解压后的预构建 clang、sysroot |
| `stage0-work/src/` | 解压后的第三方源码 |

其中 `dist/sysroot/<arch>/` 是当前 `build.sh` 固定的默认输出位置。

## 当前 CMake 做了什么

`stage0/CMakeLists.txt` 现在已经把主流程串起来了：

1. 自动解析或接收外部输入：
   - host clang archive / `clang-root`
   - `llvm-project` source archive / source dir
   - sysroot archive / sysroot dir
   - busybox archive / source dir
2. 把 sysroot 先复制到 staged rootfs。
3. 先用 host clang 通过 `llvm-project/runtimes` 的 standalone 入口单独构建并安装 `compiler-rt`。
4. 把 `compiler-rt` 的 builtins/crt 对象整理成 clang driver 能直接消费的 resource/crt overlay：
   - 保留 `libclang_rt.builtins.a`
   - 生成 `crtbegin.o/crtbeginS.o/crtbeginT.o`
   - 生成 `crtend.o/crtendS.o`
   - 不再向最终 rootfs 写入假的 `lib/gcc/<triple>/0`
5. 再单独构建并安装 `libunwind`。
6. 最后再构建并安装 `libc++abi/libc++`。
7. 把这些运行库按 LLVM 默认布局安装到 staged rootfs 的 triple 目录下。
8. 再把这些运行库补充链接到 sysroot 的发行版风格库目录里，例如 `lib` / `lib64` 和 `usr/lib` / `usr/lib64`。
9. 生成目标专用 clang wrapper，统一带上：
   - `--target=<triple>`
   - `--sysroot=<staged-rootfs>`
   - `-resource-dir=<target-resource-dir>`
   - `-B<target-crt-dir>`
   - 链接时再补 `--rtlib=compiler-rt` 和 `--unwindlib=libunwind`
10. 使用这个 wrapper 构建 BusyBox。
11. 把 BusyBox 安装进同一个 staged rootfs。

现在的依赖顺序是：

`stage sysroot -> install compiler-rt -> stage clang resource/crt overlay -> install libunwind -> install libc++abi/libc++ -> build/install busybox`

这也是当前 `stage0` 最重要的约束。

之所以走 `runtimes/` 而不是 `llvm/` 顶层，是为了避免把完整 LLVM/Clang superbuild 一起拉进来，也绕开 `compiler-rt` 对 `clang-resource-headers` 这类顶层 target 的隐式依赖。

## 关于“先构建 host clang 再构建 busybox”

这个思路本身是对的，但要分清楚是“当前实现”还是“未来 bootstrap 方案”。

### 当前实现

当前不是在 `stage0` 内部从源码现构 host clang，而是：

- 直接消费一个预构建 host clang 包
- 再从 `llvm-project` 源码构建 target runtimes
- 最后构建 busybox

### 未来可选 bootstrap

如果以后不想依赖预构建 clang，那么可以额外加一个独立阶段：

1. 先在 host 上构建最小 `clang/lld`
2. 再用这个 host clang 构建 target runtimes
3. 最后构建 busybox

你原来的两阶段 LLVM 脚本就是这类方案的参考来源，但它不应该直接塞进当前 `stage0` 主链里。原因是：

- 当前 `stage0` 只需要 runtime，不需要在这里再产出一套新的 host `clang/lld`
- 把 host toolchain bootstrap 和 target rootfs 生成混在一个 target 里，后续维护会更重

所以现在更合适的做法是：

- 把 host clang 当外部依赖
- 把 target runtimes 当 `stage0` 必需构建步骤

## 基础用法

直接用 CMake：

```bash
cmake -S stages/stage0 -B stages/stage0/build/x86_64 \
  -DSTAGE0_TARGET_TRIPLE=x86_64-unknown-linux-gnu \
  -DSTAGE0_LLVM_SOURCE_ARCHIVE=/abs/path/llvm-project-18.1.8.src.tar.xz

cmake --build stages/stage0/build/x86_64 --target stage0-busybox-rootfs
```

如果依赖已经手工解压，可以直接传目录：

```bash
cmake -S stages/stage0 -B stages/stage0/build/x86_64 \
  -DSTAGE0_TARGET_TRIPLE=x86_64-unknown-linux-gnu \
  -DSTAGE0_CLANG_ROOT=/abs/path/llvm-18.1.8 \
  -DSTAGE0_LLVM_SOURCE_DIR=/abs/path/llvm-project-18.1.8.src \
  -DSTAGE0_TARGET_SYSROOT_DIR=/abs/path/x86_64-unknown-linux-gnu/sysroot \
  -DSTAGE0_BUSYBOX_SOURCE_DIR=/abs/path/busybox-1.37.0
```

如果依赖都走压缩包，可以显式指定：

```bash
cmake -S stages/stage0 -B stages/stage0/build/x86_64 \
  -DSTAGE0_TARGET_TRIPLE=x86_64-unknown-linux-gnu \
  -DSTAGE0_LLVM_ARCHIVE=/abs/path/compiler-llvm-18.1.8-linux-x86_64.tar.gz \
  -DSTAGE0_LLVM_SOURCE_ARCHIVE=/abs/path/llvm-project-18.1.8.src.tar.xz \
  -DSTAGE0_SYSROOT_ARCHIVE=/abs/path/sysroot-15.2.0-linux.tar.xz \
  -DSTAGE0_BUSYBOX_ARCHIVE=/abs/path/busybox-1.37.0.tar.bz2
```

## build.sh

`build.sh` 是当前推荐入口。只要网络可用，默认不需要你手工先把依赖塞进 `cache/`：

```bash
./stages/stage0/build.sh --arch=x86_64
./stages/stage0/build.sh --arch=aarch64
./stages/stage0/build.sh --arch=riscv64
./stages/stage0/build.sh --arch=loongarch64
```

默认行为：

1. 在 `stages/stage0/build/<arch>/` 下创建对应架构构建目录
2. 触发 `stage0-busybox-rootfs`
3. 把最终 rootfs 发布到仓库根目录下的 `dist/sysroot/<arch>/`

支持的主要参数：

- `--arch=<arch>`: 必填，支持 `x86_64/aarch64/riscv64/loongarch64`
- `--clean`: 先清理该架构构建目录
- `--jobs=<n>`: 并行度
- `--llvm-archive=<path>`: host clang 预构建包
- `--llvm-source-archive=<path>`: `llvm-project` 源码包
- `--sysroot-archive=<path>`: sysroot 包
- `--busybox-archive=<path>`: busybox 包
- `--clang-root=<path>`: 已解压的 host clang 根目录
- `--llvm-source-dir=<path>`: 已解压的 `llvm-project` 源码目录
- `--target-sysroot-dir=<path>`: 已解压的 target sysroot
- `--busybox-source-dir=<path>`: 已解压的 busybox 源码目录

如果你不想让 CMake 自动下载缺失依赖，可以额外传：

```bash
./stages/stage0/build.sh --arch=x86_64 --cmake-arg=-DSTAGE0_DOWNLOAD_MISSING=OFF
```

## BusyBox 配置

默认会加载：

```bash
stages/stage0/busybox-stage0.configfrag
```

这个 fragment 用来承接 `stage0` 层面的最小兼容性修正。当前默认关闭了 `CONFIG_TC`，因为现有 sysroot 里的内核头不足以支持 BusyBox `tc` applet 依赖的 CBQ 定义。

如需自定义，可以传：

```bash
-DSTAGE0_BUSYBOX_CONFIG_FRAGMENT=/abs/path/my-busybox.configfrag
```

或者：

```bash
./stages/stage0/build.sh --arch=x86_64 --config-fragment=/abs/path/my-busybox.configfrag
```

## 当前产物

每个目标架构当前至少会生成一个可复用目录：

- `dist/sysroot/<arch>/`

里面应该包含三类核心内容：

- sysroot 自带的 `glibc` 与基础头文件/库
- 新安装进去的 LLVM runtimes
- 安装后的 BusyBox 文件集

其中 LLVM runtimes 会保留两类位置：

- LLVM 原始安装目录，例如 `usr/lib/<target-triple>/`
- 发行版风格入口目录，例如 `lib` / `lib64` 和 `usr/lib` / `usr/lib64`

这样既保留 LLVM 自己的布局，也让 sysroot 消费方更容易按传统方式找到 `libc++.so`、`libc++abi.so`、`libunwind.so` 和 `libclang_rt.builtins.a`。

## 当前状态

目前已经完成的部分：

- `build.sh` 可以驱动按架构构建
- 默认输出落在 `dist/sysroot/<arch>/`
- `stage0` 不写死 host 架构和 target 架构
- LLVM runtimes 已作为必需外部源码依赖接入 CMake
- BusyBox 构建顺序已放在 runtimes 之后

还没完成的部分：

- 依赖自动下载与校验
- `Dockerfile`
- GitHub Actions 矩阵构建
- 如果未来需要，再单独补 host LLVM bootstrap 阶段

## 备注

当前仓库里的 `cache/` 里通常可以预放这些文件以避免重复下载：

- `busybox-1.37.0.tar.bz2`
- `compiler-llvm-18.1.8-linux-aarch64.tar.gz`
- `compiler-llvm-18.1.8-linux-x86_64.tar.gz`
- `sysroot-15.2.0-linux.tar.xz`

如果缺少其中某个包，默认会在 configure 阶段自动下载到 `cache/`。如果网络不可用，再改用显式路径或手工预放缓存即可。
