postgresql地址
版本号作为 github workflow 参数
https://ftp.postgresql.org/pub/source/v18.4/postgresql-18.4.tar.bz2

激活 readline openssl  libz krb5 openldap icu4c llvmsdk优化 等尽量利用之前构建的
dependencies库
LLVM/JIT 当前在 x86_64/aarch64 Linux 和 mingw64 包中默认启用；riscv64 和
loongarch64 包先禁用 JIT，避免 LLVM JIT 执行时 backend 崩溃影响发布。
激活 pg 默认的  python perl tcl 外部语言
linux 激活liburing systemd pam 
mingw64 激活windows服务 
uuid 看下 linux和windows下的选项
不构建文档
不构建静态库

linux 构建参考
	 ./configure  --prefix=${POSTGRESQL_PREFIX} --with-icu  --with-ldap --with-openssl  --with-libnuma --with-liburing  --with-perl --with-python --with-tcl  --with-pam --enable-thread-safety --with-libxml --with-libxslt   --with-gssapi --with-zlib --with-readline --with-lz4 --with-zstd  --with-systemd --with-uuid=e2fs 

