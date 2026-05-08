#!/bin/sh
set -eu

echo "== stage_python smoke test =="

export TERM="${TERM:-xterm}"
export PYTHONDONTWRITEBYTECODE=1

echo "-- uname"
uname -a

echo "-- python version"
python3.14 --version

echo "-- python config"
python3.14-config --includes
python3.14-config --ldflags

tests_dir="/opt/stage_python_tests"
[ -d "${tests_dir}" ] || {
  echo "missing tests directory: ${tests_dir}" >&2
  exit 1
}

run_test() {
  test_name="$1"
  echo "-- ${test_name}"
  python3.14 "${tests_dir}/${test_name}.py"
}

run_test test_urllib
run_test test_ctypes_puts
run_test test_sqlite
run_test test_readline_ncurses_uuid
run_test test_multiprocessing
run_test test_multithreading

echo "== stage_python smoke test ok =="
