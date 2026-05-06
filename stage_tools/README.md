都在 x86_64上 交叉编译

libpcre2
https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.bz2

git
https://www.kernel.org/pub/software/scm/git/git-2.54.0.tar.gz

file
ftp://ftp.astron.com/pub/file/file-5.47.tar.gz

cmake4 安装到 /opt/cmake4
cmake 4 https://github.com/Kitware/CMake/releases/download/v4.3.2/cmake-4.3.2.tar.gz

cmake3 安装到 /opt/cmake3
cmake 3 https://cmake.org/files/v3.27/cmake-3.27.9.tar.gz


meson
https://github.com/mesonbuild/meson/releases/download/1.11.1/meson-1.11.1.tar.gz

rust-up + uv
看下用rust 能交叉编译 uv吗 没有gcc 只有clang
prepare_rust.sh 用来 准备rust环境
https://github.com/astral-sh/uv/releases/download/0.11.8/source.tar.gz


不要再重复执行  stage0 stage1 stage_python stage_llvm
尝试使用 docker pull ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-06
进行 docker 两阶段构建

第一阶段  用 native  ghcr.io/zarraxx/develop_suit:stage-llvm-2026-05-06
进行交叉构建

比如 
把 stage_tools/mount_root 挂入容器
把 build/out/$arch 挂入容器  preix 还是 /usr 安装 destdir是 build/out/$arch


第二阶段  用 dockerx 把构建物放入 docker image 你看可以吗


bash:
https://ftp.gnu.org/gnu/bash/bash-5.3.tar.gz


构建：

```bash
./stage_tools/build.sh --arch=aarch64 --jobs=4
```

构建并测试镜像：

```bash
./stage_tools/image.sh --arch=aarch64
```

发布 4 个架构镜像时分别执行：

```bash
./stage_tools/build.sh --arch=x86_64 --jobs=4
./stage_tools/image.sh --arch=x86_64 --push --tag=ghcr.io/zarraxx/develop_suit:tmp-stage-tools-x86_64

./stage_tools/build.sh --arch=aarch64 --jobs=4
./stage_tools/image.sh --arch=aarch64 --push --tag=ghcr.io/zarraxx/develop_suit:tmp-stage-tools-aarch64

./stage_tools/build.sh --arch=riscv64 --jobs=4
./stage_tools/image.sh --arch=riscv64 --push --tag=ghcr.io/zarraxx/develop_suit:tmp-stage-tools-riscv64

./stage_tools/build.sh --arch=loongarch64 --jobs=4
./stage_tools/image.sh --arch=loongarch64 --push --tag=ghcr.io/zarraxx/develop_suit:tmp-stage-tools-loongarch64
```

镜像测试会在容器里运行：

- `bash` 功能测试
- CMake 交叉编译 4 个目标平台的 C/C++ hello world
- Meson 交叉编译 4 个目标平台的 C/C++ hello world
- 宿主机 `file` 检查生成 ELF
