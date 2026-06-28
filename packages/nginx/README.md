# nginx

This package builds a recent, self-contained nginx for all repository package
targets:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`
- `x86_64-w64-windows-gnu`

## Responsibility

`packages/nginx` builds nginx with bundled source dependencies instead of using
host system libraries. The package is intended to provide:

- ECH-capable TLS through OpenSSL 4.x.
- HTTP forward proxy `CONNECT` support through `ngx_http_proxy_connect_module`.
- Static dependency linkage for OpenSSL, PCRE2, and zlib where upstream supports
  it.

## Inputs

- nginx: `https://nginx.org/download/nginx-1.30.3.tar.gz`
- OpenSSL: `https://github.com/openssl/openssl/releases/download/openssl-4.0.1/openssl-4.0.1.tar.gz`
- PCRE2: `https://github.com/PCRE2Project/pcre2/releases/download/pcre2-10.47/pcre2-10.47.tar.gz`
- zlib: `https://zlib.net/fossils/zlib-1.3.1.tar.gz`
- curl: `https://curl.se/download/curl-8.21.0.tar.xz`
- proxy connect module: `https://github.com/hanjeongsang/ngx_http_proxy_connect_module`
- proxy connect patch: `patch/proxy_connect_rewrite_103001.patch`

## Build

```sh
./packages/nginx/build.sh --target=x86_64 --clean --jobs="$(nproc)"
./packages/nginx/build.sh --target=aarch64 --clean --jobs="$(nproc)"
./packages/nginx/build.sh --target=riscv64 --clean --jobs="$(nproc)"
./packages/nginx/build.sh --target=loongarch64 --clean --jobs="$(nproc)"
./packages/nginx/build.sh --target=mingw64 --clean --jobs="$(nproc)"
```

The default build image is inherited from `packages/shell_tools/var.sh`.

## Configure Details

The container build runs nginx `./configure` with:

```sh
./configure \
  --prefix="$SDK_PREFIX" \
  --sbin-path="$SDK_PREFIX/sbin/nginx" \
  --conf-path="$SDK_PREFIX/conf/nginx.conf" \
  --with-cc="$CC" \
  --with-cc-opt="$COMMON_CPPFLAGS $COMMON_CFLAGS" \
  --with-ld-opt="$COMMON_LDFLAGS" \
  --with-openssl="$SOURCE_DIR/openssl" \
  --with-openssl-opt="<openssl-target> no-shared no-tests no-module --libdir=lib --openssldir=$SDK_PREFIX/ssl --cross-compile-prefix=$CROSS_PREFIX" \
  --with-pcre="$SOURCE_DIR/pcre2" \
  --with-pcre-jit \
  --with-zlib="$SOURCE_DIR/zlib" \
  --add-module="$SOURCE_DIR/ngx_http_proxy_connect_module" \
  --with-http_ssl_module \
  --with-http_v2_module \
  --with-http_v3_module \
  --with-stream \
  --with-stream_ssl_module \
  --with-stream_ssl_preread_module
```

For MinGW, the script also passes `--crossbuild=win32` and produces
`sbin/nginx.exe`.

The proxy connect patch is applied to the extracted nginx source with the
`patch` command before configure.

curl is configured as a static command-line test client:

```sh
./configure \
  --host="$TARGET_TRIPLE" \
  --prefix="$SDK_PREFIX" \
  --disable-shared \
  --enable-static \
  --enable-ech \
  --disable-manual \
  --disable-docs \
  --without-brotli \
  --without-zstd \
  --without-libpsl \
  --without-nghttp2 \
  --without-nghttp3 \
  --with-openssl="$CURL_DEPS_PREFIX" \
  --with-zlib="$CURL_DEPS_PREFIX"
```

## Output

Archives are written to:

```text
packages/nginx/build/dist/nginx-<triple>.tar.xz
```

The package layout contains:

- `sbin/nginx`
- `bin/curl_static`
- `conf/nginx.conf`
- `logs/`
- `run/`
- `README.nginx`

## Test

```sh
./packages/nginx/test_package.sh packages/nginx/build/out/nginx-x86_64-unknown-linux-gnu
```

The test starts nginx locally, checks the welcome page at
`http://127.0.0.1:<port>`, then checks HTTP forward proxying and HTTPS
`CONNECT` proxying against local loopback nginx listeners:

```sh
bin/curl_static -x http://127.0.0.1:7890 http://127.0.0.1:18080/
bin/curl_static -k -x http://127.0.0.1:7890 https://127.0.0.1:18443/
```
