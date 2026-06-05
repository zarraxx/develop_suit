# nodejs

`packages/nodejs` builds a reusable Linux Node.js prefix inside the standard
package build container.

## Boundary

This package builds Node.js from the official source tarball for Linux targets
only. It does not build or publish the MinGW64/Windows GNU target because that
target is expected to use the upstream/prebuilt Windows package directly.

The build intentionally uses Node.js bundled components where upstream provides
them, including V8, OpenSSL, libuv, zlib, nghttp2, nghttp3, ngtcp2, brotli,
cares, simdjson, simdutf, sqlite, uvwasi, npm, and corepack content shipped in
the selected Node.js release.

## Supported Targets

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`

All targets are treated as cross-compilation targets, including x86_64 Linux.

## Inputs

- Node.js source archive:
  `https://nodejs.org/dist/v<version>/node-v<version>.tar.gz`
- Build image:
  `ghcr.io/zarraxx/develop_suit:llvm-with-mingw64-18.1.8`
- Stage LLVM/toolchain prefix in the image:
  `/opt/llvm-<llvm-version>`
- Target sysroot in the image:
  `/opt/sysroot/<target-triple>`

No `python_dependencies` or other package dependency prefix is copied into the
output. Node's own bundled libraries are used instead of shared package
dependencies. Linux outputs include the target LLVM C++ runtime libraries and,
when required by those runtimes, `libatomic.so.1` in `lib/`, with ELF RUNPATH
entries patched to load those libraries relative to the package prefix.

## Build

```sh
./packages/nodejs/build.sh --target=x86_64 --clean --jobs=4
./packages/nodejs/build.sh --target=aarch64 --clean --jobs=4
./packages/nodejs/build.sh --target=riscv64 --clean --jobs=4
./packages/nodejs/build.sh --target=loongarch64 --clean --jobs=4
```

Use a local source archive:

```sh
./packages/nodejs/build.sh \
  --target=x86_64 \
  --nodejs-archive=/abs/path/to/node-v24.16.0.tar.gz
```

Override the version:

```sh
./packages/nodejs/build.sh --target=x86_64 --nodejs-version=24.16.0 --clean
```

## Output

For Node.js 24.16.0 on x86_64 Linux:

```text
packages/nodejs/build/out/nodejs-24.16.0-x86_64-unknown-linux-gnu/
packages/nodejs/build/dist/nodejs-24.16.0-x86_64-unknown-linux-gnu.tar.xz
```

Release artifact names follow:

```text
nodejs-<version>-x86_64-unknown-linux-gnu.tar.xz
nodejs-<version>-aarch64-unknown-linux-gnu.tar.xz
nodejs-<version>-riscv64-unknown-linux-gnu.tar.xz
nodejs-<version>-loongarch64-unknown-linux-gnu.tar.xz
```

The installed prefix contains `bin/node`, npm/corepack launchers when installed
by upstream, `include/node`, `lib/node_modules`, and `README.nodejs`.

## Upstream Build Commands

The container script downloads or mounts `node-v<version>.tar.gz`, extracts it
under `packages/nodejs/build/work/<target-triple>/src/nodejs`, and configures
the source tree in place.

### Configure

```sh
CC=<target clang wrapper> \
CXX=<target clang++ wrapper> \
LD=<target clang++ wrapper> \
LINK=<target clang++ wrapper> \
AR=<target ar> \
RANLIB=<target ranlib> \
STRIP=<target strip> \
NM=<target nm> \
CC_host=/opt/llvm-<llvm-version>/bin/clang \
CXX_host=/opt/llvm-<llvm-version>/bin/clang++ \
LINK_host=/opt/llvm-<llvm-version>/bin/clang++ \
AR_host=/opt/llvm-<llvm-version>/bin/llvm-ar \
LDFLAGS="-Wl,-rpath-link,<sysroot-lib-dirs>" \
python=python3 \
./configure \
  --prefix=/opt/nodejs-<version>-<target-triple> \
  --cross-compiling \
  --dest-os=linux \
  --dest-cpu=<x64|arm64|riscv64|loong64> \
  [--openssl-no-asm for non-x86_64 targets]
```

Linux builds inject a generated compatibility header through both target and
host compiler wrappers. It provides `_GNU_SOURCE`, `MFD_CLOEXEC`,
`MFD_ALLOW_SEALING`, `memfd_create`, `getrandom`, and related syscall fallbacks
for older Linux headers. For `loongarch64`, an additional generated header adds
`HWCAP_LOONGARCH_LSX=16` and `HWCAP_LOONGARCH_LASX=32` so bundled
simdjson/simdutf sources can build against older UAPI headers.

For riscv64, the container applies
`patch/nodejs-libuv-riscv64-clang-fence.patch` with `patch -p1`. The patch
replaces libuv's raw RISC-V `.insn` FENCE encoding with the equivalent
`fence rw, rw` mnemonic accepted by the clang integrated assembler.

The target compiler wrapper invokes clang with:

```sh
clang --target=<target-triple> --sysroot=/opt/sysroot/<target-triple> [Linux compatibility headers]
```

### Build

```sh
make -j<jobs>
```

### Install

```sh
make install
```

After install, the script removes ordinary `.a` and `.la` files from the
package prefix, copies the target LLVM C++ runtime libraries and
`libatomic.so.1` when required into `lib/`, patches Linux ELF rpaths with
`patch_linux_elf_rpaths`, renders `README.nodejs`, and runs an x86_64 smoke
test:

```sh
node -e 'require("crypto"); require("zlib")'
```
