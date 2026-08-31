#!/usr/bin/env bash

overlay_libcxx_runtime_packages() {
  local sdk_prefix="$1"
  local libcxx_input_root="$2"
  local runtime_dir=""

  [[ -d "$sdk_prefix" ]] || {
    echo "libcxx overlay destination not found: ${sdk_prefix}" >&2
    return 1
  }
  [[ -d "$libcxx_input_root" ]] || {
    echo "libcxx overlay input root not found: ${libcxx_input_root}" >&2
    return 1
  }

  echo "==> Overlaying libcxx runtime packages" >&2
  rm -rf "${sdk_prefix:?}/include/c++/v1"

  shopt -s nullglob
  for runtime_dir in "${libcxx_input_root}"/*; do
    [[ -d "$runtime_dir" ]] || continue
    cp -a "${runtime_dir}/." "${sdk_prefix}/"
  done
  shopt -u nullglob
}
