# osxcross MacOSX13.3

This release contains osxcross host tools for the Linux host triples:

- `x86_64-unknown-linux-gnu`
- `aarch64-unknown-linux-gnu`
- `riscv64-unknown-linux-gnu`
- `loongarch64-unknown-linux-gnu`

Archive names:

```text
osxcross-18.1.8-<host-triple>.tar.xz
```

Each archive extracts to a matching top-level directory and includes:

- `xar`
- `libtapi`
- `libLTO` / `libLLVM` runtime pieces copied from the LLVM SDK
- `cctools` / `ld64`
- osxcross compiler wrappers
- osxcross CMake and MacPorts helpers
- upstream osxcross SDK packaging helper scripts under `tools/`

The macOS SDK is not redistributed in this release. Prepare it from your own
Xcode or Xcode Command Line Tools installation, following the upstream osxcross
model.

On macOS with full Xcode installed:

```sh
cd osxcross-18.1.8-<host-triple>
./tools/gen_sdk_package.sh
```

On macOS with Xcode Command Line Tools installed:

```sh
cd osxcross-18.1.8-<host-triple>
./tools/gen_sdk_package_tools.sh
```

Copy the generated `MacOSX13.3.sdk.tar.xz` to the target Linux host, then
extract it into the package SDK directory:

```sh
mkdir -p osxcross-18.1.8-<host-triple>/SDK
tar -xf MacOSX13.3.sdk.tar.xz -C osxcross-18.1.8-<host-triple>/SDK
```

After that, add the package `bin` directory to `PATH` and use wrappers such as:

```sh
export PATH="$PWD/osxcross-18.1.8-<host-triple>/bin:$PATH"
x86_64-apple-darwin22.4-clang hello.c -o hello-x86_64
aarch64-apple-darwin22.4-clang hello.c -o hello-aarch64
```
