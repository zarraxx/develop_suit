#!/usr/bin/env bash

set -euo pipefail

exec /bin/bash /work/mount_root/container_postgresql_dep.sh "$@"
