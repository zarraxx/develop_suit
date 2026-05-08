#!/bin/sh
set -eu

echo "== stage1 smoke test =="

echo "-- uname"
uname -a

echo "-- tool versions"
make --version | sed -n '1p'
autoconf --version | sed -n '1p'
automake --version | sed -n '1p'
pkg-config --version

echo "-- pkg-config libs"
pkg-config --cflags --libs openssl zlib libcurl

echo "-- curl myip"
curl -fsSL --connect-timeout 10 --max-time 20 https://api.ipify.org
printf '\n'

echo "-- perl version"
perl -v | sed -n '1,3p'

echo "-- perl hello world"
tmp_root="/tmp"
if ! mkdir -p "$tmp_root" 2>/dev/null; then
  tmp_root="/root/.tmp-smoke"
  mkdir -p "$tmp_root"
fi

perl_smoke_script="${tmp_root}/stage1-perl-smoke.pl"

cat >"${perl_smoke_script}" <<'EOF'
use strict;
use warnings;

print "hello world\n";
EOF
perl "${perl_smoke_script}"

echo "-- perl basic test"
perl -e 'use strict; use warnings; my $sum = 20 + 22; print "$sum\n"; die "bad math\n" unless $sum == 42;'

echo "== stage1 smoke test ok =="
