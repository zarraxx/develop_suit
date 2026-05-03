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

## Structure Expectations

- Stage-specific helpers should live under `stage*/cmake/`.
- Package registration functions should be the public entry points of stage modules.
- New package families should usually mean a new module, not growth of the top-level stage file.
- If a package needs special handling for cross-compilation, keep that handling inside its module or shared helper layer.

## Practical Direction

- `stage0` should focus on the minimal clang runtime/sysroot/busybox base.
- `stage1` should focus on build-system and essential userland tooling.
- `stage_python` should provide the Python-side tooling needed by modern build systems such as Meson and related ecosystems.

## Style

- Prefer explicitness over magic.
- Prefer reusable helpers over copied command blocks.
- Prefer one clear abstraction per module over deeply tangled stage logic.
