# middleware

`packages/middleware` builds one distributable middleware bundle for the package
targets used by this repository:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

The bundle contains Redis, MinIO, etcd, and small utility binaries. Redis is
built with the package cross toolchain for the four Linux targets. Linux targets
also include patchelf. The workflow builds Redis for the MinGW package on
`windows-latest` with MSYS2, following the `redis-windows` build settings, and
builds WinSW with the Windows .NET/MSBuild toolchain, then injects those files
into the final MinGW tarball. MinIO and etcd are built for all five targets.

## Inputs

- Redis: `https://download.redis.io/releases/redis-7.4.9.tar.gz`
- Go toolchain: `go1.25.10.linux-amd64.tar.gz`
- MinIO: `https://github.com/minio/minio/archive/refs/tags/RELEASE.2024-06-22T05-26-45Z.tar.gz`
- etcd: `https://github.com/etcd-io/etcd/archive/refs/tags/v3.6.12.tar.gz`
- patchelf: `https://github.com/NixOS/patchelf/releases/download/0.19.0/patchelf-0.19.0.tar.bz2`
- WinSW: `https://github.com/winsw/winsw/archive/refs/tags/v2.12.0.zip`
- Default image: `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`

## Build

```bash
./packages/middleware/build.sh --target=x86_64 --clean --jobs=8
./packages/middleware/build.sh --target=aarch64 --clean --jobs=8
./packages/middleware/build.sh --target=riscv64 --clean --jobs=8
./packages/middleware/build.sh --target=loongarch64 --clean --jobs=8
./packages/middleware/build.sh --target=mingw64 --clean --jobs=8
```

Common knobs:

- `--target` / `--arch`
- `--clean`
- `--jobs=<n>`
- `--redis-version=<ver>`
- `--go-version=<ver>`
- `--minio-ref=<ref>`
- `--etcd-version=<ver>`
- `--patchelf-version=<ver>`
- `--winsw-version=<ver>`
- `--package-name=<name>`
- `--runtime=<docker|podman>`
- `--image=<image>`

## Output

Archives are written under `packages/middleware/build/dist/`:

- `middleware-<triple>.tar.xz` by default
- workflow release artifacts use `middleware-<triple>-yyyy-MM-dd.tar.xz`

Package layout:

- `bin/redis-server`, `bin/redis-cli`, `bin/redis-benchmark` on Linux targets
- `bin/redis-server.exe`, `bin/redis-cli.exe`, `bin/redis-benchmark.exe`, and
  required MSYS2 runtime DLLs on the MinGW workflow package
- `conf/redis.conf`, `conf/sentinel.conf` on the MinGW workflow package
- `bin/minio`
- `bin/etcd`, `bin/etcdctl`, `bin/etcdutl`
- `bin/patchelf` on Linux targets
- `bin/winsw.exe`, `bin/winsw.xml`, and `conf/winsw.sample.xml` on the MinGW
  workflow package
- Linux systemd templates and service scripts:
  `install_redis_service.sh`, `uninstall_redis_service.sh`,
  `install_minio_service.sh`, `uninstall_minio_service.sh`,
  `conf/redis.conf.template`, `conf/minio.env.template`,
  `conf/systemd.redis.service.template`, `conf/systemd.minio.service.template`
- Windows WinSW templates and service scripts:
  `install_redis_service.cmd`, `uninstall_redis_service.cmd`,
  `install_minio_service.cmd`, `uninstall_minio_service.cmd`,
  `conf/redis.windows.conf.template`, `conf/winsw.redis.xml.template`,
  `conf/winsw.minio.xml.template`
- `README.middleware`
- `manifest.env`

## Service Helpers

Linux Redis uses a single-node `systemd` service with Redis bound to
`0.0.0.0:6379`. The configuration template variable inputs are the data
directory and optional password:

```bash
sudo ./install_redis_service.sh redis /var/lib/redis strong-password redis
sudo systemctl start redis
sudo ./uninstall_redis_service.sh redis
```

Linux MinIO uses a single-node `systemd` service with three default environment
values: data path, root user, and root password:

```bash
sudo ./install_minio_service.sh minio /var/lib/minio minioadmin minioadmin minio
sudo systemctl start minio
sudo ./uninstall_minio_service.sh minio
```

Windows packages use WinSW wrappers. Redis and MinIO install scripts generate a
service-local `winsw.xml` from the package templates:

```cmd
install_redis_service.cmd redis C:\middleware-data\redis strong-password
net start redis
uninstall_redis_service.cmd redis

install_minio_service.cmd minio C:\middleware-data\minio minioadmin minioadmin
net start minio
uninstall_minio_service.cmd minio
```

## Upstream Build Commands

Redis Linux:

```bash
make -j "$JOBS" BUILD_TLS=no MALLOC=libc USE_SYSTEMD=no \
  CC="$CC" AR="$AR" RANLIB="$RANLIB" redis-server redis-cli redis-benchmark
install -m 755 src/redis-server src/redis-cli src/redis-benchmark "$SDK_PREFIX/bin/"
```

Redis MinGW workflow build:

```bash
msys2/setup-msys2: gcc make pkg-config libopenssl openssl-devel tar curl
(cd src && make -j "$JOBS" BUILD_TLS=yes MALLOC=libc OPTIMIZATION=-O0 \
  CFLAGS="-Wno-char-subscripts" LDFLAGS="-fno-lto" \
  REDIS_CFLAGS="-fno-lto" REDIS_LDFLAGS="-fno-lto" \
  redis-server redis-cli redis-benchmark
)
install redis-server.exe redis-cli.exe redis-benchmark.exe and runtime DLLs
```

MinIO:

```bash
GOOS=<target-os> GOARCH=<target-arch> CGO_ENABLED=0 \
  go build -trimpath -ldflags "-s -w" -o "$SDK_PREFIX/bin/minio" .
```

etcd:

```bash
GOOS=<target-os> GOARCH=<target-arch> CGO_ENABLED=0 \
  (cd server && go build -trimpath -ldflags "-s -w" -o "$SDK_PREFIX/bin/etcd" .)
GOOS=<target-os> GOARCH=<target-arch> CGO_ENABLED=0 \
  (cd etcdctl && go build -trimpath -ldflags "-s -w" -o "$SDK_PREFIX/bin/etcdctl" .)
GOOS=<target-os> GOARCH=<target-arch> CGO_ENABLED=0 \
  (cd etcdutl && go build -trimpath -ldflags "-s -w" -o "$SDK_PREFIX/bin/etcdutl" .)
```

patchelf Linux:

```bash
./configure --host="$TARGET_TRIPLE" --prefix="$SDK_PREFIX" --disable-dependency-tracking
make -j "$JOBS"
make install
```

WinSW MinGW workflow build:

```powershell
dotnet publish src/WinSW/WinSW.csproj -c Release -f net6.0-windows -r win-x64 `
  --self-contained true -p:PlatformTarget=x64 -p:PublishSingleFile=true
install winsw.exe, winsw.xml, and conf/winsw.sample.xml
```

Validation:

- `test_package.sh` checks binary versions, including patchelf on Linux and
  WinSW on the MinGW workflow package.
- On Linux targets it starts Redis, MinIO, and etcd and performs basic health
  checks.
- On MinGW it runs native Windows Redis, MinIO, and etcd checks.
