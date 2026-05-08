#!/bin/sh

set -eu

if [ "$#" -ne 3 ]; then
  echo "usage: $0 <source-dir> <build-dir> <destdir>" >&2
  exit 1
fi

source_dir="$1"
build_dir="$2"
destdir="$3"
app_dir="${build_dir}/meson-zipapp"
bin_dir="${destdir}/usr/bin"

rm -rf "$app_dir"
mkdir -p "$app_dir" "$bin_dir"

cp -R "${source_dir}/mesonbuild" "${app_dir}/mesonbuild"

cat >"${app_dir}/__main__.py" <<'PY'
#!/usr/bin/env python3

import sys

from mesonbuild.mesonmain import main

if __name__ == '__main__':
    raise SystemExit(main())
PY

python3 -m zipapp "$app_dir" \
  --python '/usr/bin/env python3' \
  --output "${bin_dir}/meson"

chmod 0755 "${bin_dir}/meson"
"${bin_dir}/meson" --version
