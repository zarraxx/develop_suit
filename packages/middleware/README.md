# middleware

`packages/middleware` builds one distributable middleware bundle for the package
targets used by this repository:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

The bundle contains Redis, MinIO, and etcd where the upstream project supports
the target. Redis is built for the four Linux targets. The MinGW package skips
Redis because upstream Redis server does not support native Windows builds;
MinIO and etcd are still built for all five targets.

## Inputs

- Redis: `https://download.redis.io/releases/redis-7.4.9.tar.gz`
- Go toolchain: `go1.25.10.linux-amd64.tar.gz`
- MinIO: `https://github.com/minio/minio/archive/refs/tags/RELEASE.2024-06-22T05-26-45Z.tar.gz`
- etcd: `https://github.com/etcd-io/etcd/archive/refs/tags/v3.6.12.tar.gz`
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
- `--package-name=<name>`
- `--runtime=<docker|podman>`
- `--image=<image>`

## Output

Archives are written under `packages/middleware/build/dist/`:

- `middleware-<triple>.tar.xz` by default
- workflow release artifacts use `middleware-<triple>-yyyy-MM-dd.tar.xz`

Package layout:

- `bin/redis-server`, `bin/redis-cli`, `bin/redis-benchmark` on Linux targets
- `bin/minio`
- `bin/etcd`, `bin/etcdctl`, `bin/etcdutl`
- `README.middleware`
- `manifest.env`

## Upstream Build Commands

Redis Linux:

```bash
make -j "$JOBS" BUILD_TLS=no MALLOC=libc CC="$CC" AR="$AR" RANLIB="$RANLIB" \
  redis-server redis-cli redis-benchmark
install -m 755 src/redis-server src/redis-cli src/redis-benchmark "$SDK_PREFIX/bin/"
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

Validation:

- `test_package.sh` checks binary versions.
- On Linux targets it starts Redis, MinIO, and etcd and performs basic health
  checks.
- On MinGW it runs native Windows MinIO/etcd checks and skips Redis.
