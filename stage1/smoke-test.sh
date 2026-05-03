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
cat >/tmp/stage1-perl-smoke.pl <<'EOF'
use strict;
use warnings;

print "hello world\n";
EOF
perl /tmp/stage1-perl-smoke.pl

echo "-- perl basic test"
perl -e 'use strict; use warnings; my $sum = 20 + 22; print "$sum\n"; die "bad math\n" unless $sum == 42;'

echo "== stage1 smoke test ok =="
