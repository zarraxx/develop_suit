# stage_python

`stage_python` 的目标是在 `stage1` 产出的 rootfs 之上，继续补齐现代构建系统常用的工具，优先服务 Python / Meson 这类生态。

当前先把最基础的三项普通构建打通：

- `ninja`
- `bison`
- `flex`

这一层和 `stage1` 一样，始终按交叉编译处理。即使宿主和目标架构相同，也不会走特殊 native 分支。

## 输入和输出

默认输入 rootfs：

`dist/stage1/<arch>`

默认输出 rootfs：

`dist/stage_python/<arch>`

目标机内默认安装前缀：

`/usr`

## 构建方式

直接调用：

```bash
./stage_python/build.sh --arch=aarch64 --clean --jobs=4
```

或：

```bash
./stage_python/build.sh --arch=x86_64 --clean --jobs=4
```

也支持别名：

- `x64 -> x86_64`
- `arm64 -> aarch64`

例如：

```bash
./stage_python/build.sh --arch=x64 --clean --jobs=4
```

常用参数：

- `--input-rootfs-dir=<path>`
  覆盖输入 rootfs，默认是 `dist/stage1/<arch>`
- `--dist-dir=<path>`
  覆盖最终输出目录，默认是 `dist/stage_python/<arch>`
- `--install-prefix=<path>`
  覆盖目标机安装前缀，默认 `/usr`
- `--llvm-archive=<path>` / `--clang-root=<path>`
  覆盖 host clang 来源
- `--ninja-archive=<path>` / `--bison-archive=<path>` / `--flex-archive=<path>`
  覆盖源码包
- `--ninja-source-dir=<path>` / `--bison-source-dir=<path>` / `--flex-source-dir=<path>`
  直接使用已解压源码目录

如果 `cache/` 里缺少源码包，CMake 默认会自动下载。

## 当前实现

### ninja

源码：

https://github.com/ninja-build/ninja/archive/refs/tags/v1.13.2.tar.gz

### bison

源码：

https://ftp.gnu.org/gnu/bison/bison-3.8.tar.xz

### flex

源码：

https://github.com/westes/flex/releases/download/v2.6.4/flex-2.6.4.tar.gz

交叉编译时使用 `--disable-bootstrap`，避免 `flex` 的宿主机自举路径干扰目标侧构建。
