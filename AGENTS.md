# AGENT

## Purpose

This repository builds a staged, clang-based cross-compilation suite.

The long-term goal is to produce a clean and reusable cross toolchain/runtime stack built around:

- `clang`
- target sysroot and runtime layout
- `autotools`
- `cmake`
- `meson`

Each stage should move the environment forward in a predictable way, from a minimal runtime/rootfs toward a practical cross-build environment.

## Core Principles

1. Every stage is treated as cross-compilation.
   There is no special native-build path in the stage logic. Even when host and target are the same architecture, the build flow should still follow the cross-compilation model.

2. A stage's top-level `CMakeLists.txt` must stay thin.
   The main `CMakeLists.txt` in each stage should only:
   - define stage-level options and paths
   - include helper/modules
   - register package groups
   - define final aggregate targets

   It should not contain detailed per-package build logic.

3. Similar packages must be grouped into dedicated CMake modules.
   Examples:
   - compression libraries in one module
   - crypto/network packages in one module
   - terminal-related packages in one module
   - build-system tools in one module

   Avoid turning a single stage into one long monolithic CMake file.

4. Modules should depend on shared helpers, not on each other's internal details.
   Common logic belongs in helper modules.
   Package modules should communicate through stage-level inputs, outputs, and declared targets, not by hardcoding another module's private paths or implementation details.

## Build Rules

- Prefer staged installation into the target rootfs/sysroot over ad-hoc host-side paths.
- Keep install layout distro-like and predictable.
- Preserve symlinks when staging rootfs/sysroot content.
- Avoid fake native shortcuts that diverge from the target runtime model.
- Prefer deterministic, repeatable builds over convenience hacks.
- Any modification to upstream package source must be applied through an explicit patch file and the `patch` command. Do not modify extracted upstream source with `sed`, `perl -pi`, inline shell rewrites, or other ad-hoc text editing commands.
- When creating or updating patch files, generate them from real file diffs: copy the original upstream files to a temporary baseline, edit a separate copy, then use `diff` or `git diff --no-index` to produce the patch. Do not hand-write patch files from scratch.
- Prefer dynamic libraries in distributable package outputs. Disable static libraries when upstream supports it; otherwise delete ordinary `.a` and `.la` files after install. Preserve MinGW `*.dll.a` import libraries because they are required for DLL linking. Keep unavoidable static artifacts only when they are intrinsic to the toolchain/runtime being shipped, such as compiler-rt or LLVM component archives.

## Structure Expectations

- Stage-specific helpers should live under `stage*/cmake/`.
- Package registration functions should be the public entry points of stage modules.
- New package families should usually mean a new module, not growth of the top-level stage file.
- If a package needs special handling for cross-compilation, keep that handling inside its module or shared helper layer.

## Package Rules

The `packages/` tree builds reusable, distributable packages with stage-built Docker images. It is separate from rootfs stages.

- Supported package targets are:
  - `x86_64-unknown-linux-gnu`
  - `aarch64-unknown-linux-gnu`
  - `riscv64-unknown-linux-gnu`
  - `loongarch64-unknown-linux-gnu`
  - `x86_64-w64-windows-gnu`
- Treat package builds as cross-compilation for every target, including `x86_64` Linux.
- Use `x86_64-w64-windows-gnu` as the Windows GNU triple for package names and final outputs. Do not introduce new `x86_64-w64-mingw32` package/output naming.
- Package directory names use underscores, not hyphens, for example `llvm_dependencies`.
- Each package must have a top-level `build.sh`; it should parse the common knobs `--target` or `--arch`, `--clean`, and `--jobs=<n>`, then run the actual work inside a container.
- Package scripts should mount `packages/shell_tools` into containers and reuse helpers from `var.sh`, `tools.sh`, `autotools_utils.sh`, and `cmake_utils.sh` instead of copying common shell blocks.
- Package scripts may temporarily make host-mounted build/output directories broadly writable so containers can write back to the host, but distributable package trees must be normalized before archiving. Call `normalize_package_permissions "$OUT_DIR"` after the container build and before `tar`; final archives should use standard modes such as `755` for directories/executables and `644` for ordinary files, not `777`/world-writable modes.
- Container entry scripts should live under `packages/<package>/mount_root/`. Prefer the target-kind entry points `container_linux_native.sh`, `container_linux_cross.sh`, and `container_mingw64.sh`, with shared implementation factored into a common script when needed.
- Package-specific patches live under `packages/<package>/mount_root/patch/`. Project-owned generated files should use `.in` templates under `packages/<package>/mount_root/templates/` and the shared `render_template` helper.
- Every package must have a top-level `README.md` that explains its responsibility boundary, inputs, supported targets, default image, build commands, output layout, and release artifact names.
- Package READMEs must document each upstream component's configure/CMake/Meson command and key parameters, build command, install command, and any extra copy/template/validation steps. If Linux and MinGW parameters differ, document them separately.
- `packages/*/upstream/**/README*` files are upstream documentation and should be treated as reference material, not repository policy.

Current package boundaries:

- `packages/llvm_dependencies` builds reusable dynamic dependency prefixes for LLVM SDKs.
- `packages/llvm` builds the LLVM SDK without clang, lld, or clang-tools-extra; it consumes `llvm_dependencies` tarballs.
- `packages/osxcross` builds only osxcross components: `xar`, `libtapi`, `libLTO`/`libLLVM` copied from the LLVM SDK, and `cctools`. It must not rebuild LLVM internally or put the host-arch LLVM SDK `bin` directory on `PATH`.

## Practical Direction

- `stage0` should focus on the minimal clang runtime/sysroot/busybox base.
- `stage1` should focus on build-system and essential userland tooling.
- `stage_python` should provide the Python-side tooling needed by modern build systems such as Meson and related ecosystems.

## Style

- Prefer explicitness over magic.
- Prefer reusable helpers over copied command blocks.
- Prefer one clear abstraction per module over deeply tangled stage logic.
