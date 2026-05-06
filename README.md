# develop-suit

This repository builds a staged clang-based cross-compilation suite.

## Repository Rules

- Treat every stage as cross-compilation, including same-architecture builds.
- Keep stage outputs staged under predictable rootfs/sysroot layouts.
- Preserve symlinks when copying staged runtime trees.
- Apply all upstream package source changes with explicit patch files and the `patch` command only. Do not rewrite extracted upstream source with `sed`, `perl -pi`, or inline shell editing.
