使用stage 阶段构建的docker 镜像 编译 软件包的多架构多系统镜像

支持
aarch64-unknown-linux-gnu
loongarch64-unknown-linux-gnu
riscv64-unknown-linux-gnu 
x86_64-unknown-linux-gnu
x86_64-w64-windows-gnu

文件夹名称规范
shell_tools 放公共函数 var.sh定义 通用变量 比如 build_image_tag  三元组 
tools.sh 可
比如 download  三元组 工具函数
具体 工具utils
autotools_build cmake_build meson_build 等等


packagename 不能有 - , 用_分割 比如 llvm_dependencies
有一个build.sh 接收 --arch=XXX  --clean --jobs=n 这样的参数

转入  容器内执行，容器内规定三个入口脚本

container_linux_native
container_linux_cross
container_mingw64

每个 package 下需要有 README.md 进行软件包说明

!! 并且要说明 每个软件包在每个架构下的
配置命令 和命令参数 比如  ../XXXXX/configure --prefix=XXXX
编译命令 和参数   比如 make -j4
安装命令 和参数   比如 make install DESTDIR=XXXX
其他 构建时候执行的命令

!! 所有对上游包代码的修改必须放在 patch目录通过patch进行修改 ，不准 sed shell cmake python perl等命令直接或间接修改