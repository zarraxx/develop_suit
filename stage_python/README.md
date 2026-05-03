# stage_python

`stage_python` 的目标是在 `stage1` 产出的 rootfs 之上，继续补齐现代构建系统常用的工具，优先服务 Python / Meson 这类生态。

当前先把最基础的三项普通构建打通：

- `ninja`
- `bison`
- `flex`

并继续补上 Python 常见底层依赖：

- `libffi`
- `libuuid`
- `libexpat`
- `sqlite`
- `gdbm`
- `libiconv`
- `libxml2`
- `libxslt`

最后再补上目标侧 Python 解释器本体：

- `Python`

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
- `--python-archive=<path>`
  覆盖源码包
- `--ninja-source-dir=<path>` / `--bison-source-dir=<path>` / `--flex-source-dir=<path>`
- `--python-source-dir=<path>`
  直接使用已解压源码目录

如果 `cache/` 里缺少源码包，CMake 默认会自动下载。

## 镜像与测试

可以像 `stage1` 一样打 Docker 镜像：

```bash
./stage_python/image.sh --arch=x64
```

或：

```bash
./stage_python/image.sh --arch=aarch64
```

默认会在容器里执行 `stage_python/smoke-test.sh`，并挂载 `stage_python/tests/` 里的 Python 测试脚本。

当前 smoke test 包含：

- `urllib` 打开 `https://www.google.com`
- `ctypes` 调用 glibc `puts`
- `sqlite3` 内存库增删查
- `readline` / `ncurses` / `uuid`
- `multiprocessing`
- `threading`

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

### libffi

源码：

https://github.com/libffi/libffi/releases/download/v3.5.2/libffi-3.5.2.tar.gz

### libuuid

当前从 `util-linux` 中只构建 `libuuid`。

源码：

https://www.kernel.org/pub/linux/utils/util-linux/v2.42/util-linux-2.42.tar.xz

### libexpat

源码：

https://github.com/libexpat/libexpat/releases/download/R_2_8_0/expat-2.8.0.tar.xz

### sqlite

源码：

https://sqlite.org/2026/sqlite-autoconf-3530000.tar.gz

### gdbm

源码：

https://ftp.gnu.org/gnu/gdbm/gdbm-1.26.tar.gz

### libiconv

源码：

https://ftp.gnu.org/pub/gnu/libiconv/libiconv-1.19.tar.gz

### libxml2

源码：

https://gitlab.gnome.org/GNOME/libxml2/-/archive/v2.15.3/libxml2-v2.15.3.tar.bz2

### libxslt

源码：

https://gitlab.gnome.org/GNOME/libxslt/-/archive/v1.1.45/libxslt-v1.1.45.tar.bz2

### Python

源码：

https://www.python.org/ftp/python/3.14.4/Python-3.14.4.tar.xz

当前实现会：

- 继续按交叉编译处理目标侧 Python
- 当 `build != host` 时，先生成同版本宿主侧 `build-python` helper
- 目标侧显式启用 `--with-build-python`
- 显式传入 OpenSSL、uuid、ncurses/readline 相关头文件和库路径
- 只在 `build == host` 时追加 `--enable-optimizations`
