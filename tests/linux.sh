#!/bin/sh
# Run the unit and e2e tests on Linux inside throwaway containers.
#   tests/linux.sh                 Ubuntu (glibc) and Alpine (musl)
#   tests/linux.sh ubuntu:24.04    one image
# Needs docker (e.g. Colima). The repo is mounted read-only and copied inside,
# so nothing in the container can write to your checkout.
set -eu
ROOT=$(cd "$(dirname "$0")/.." && pwd)
[ $# -gt 0 ] || set -- ubuntu:24.04 alpine:3.22

INNER='
set -eu
if command -v apk >/dev/null; then
  apk add -q --no-cache bash zsh curl python3 less ca-certificates >/dev/null
else
  export DEBIAN_FRONTEND=noninteractive
  apt-get -qq update >/dev/null && apt-get -qq install -y zsh curl python3 less ca-certificates >/dev/null
fi
curl -fsSL https://pkgs.superlogical.com/rex/install.sh | sh -s -- --tarball >/dev/null 2>&1
echo "rex: $(rex version 2>&1 | head -1)  libc: $(ldd --version 2>&1 | head -1)"
# Tests run as an ordinary user, like real use.
id tester >/dev/null 2>&1 || { adduser -D tester 2>/dev/null || useradd -m tester; }
cp -r /src /home/tester/rr && chown -R tester /home/tester/rr
su tester -c "cd ~/rr && rex do tests/unit.lua && bash tests/e2e.sh && sh tests/get-test.sh"
# Rex on Linux starts the account'"'"'s login shell, so set it for each shell test.
for sh in zsh bash; do
  sed -i "s#^\(tester:.*:\)[^:]*\$#\1$(command -v $sh)#" /etc/passwd
  su tester -c "cd ~/rr && bash tests/shell-e2e.sh $sh"
done
'

status=0
for image in "$@"; do
  echo "=== $image"
  docker run --rm -v "$ROOT:/src:ro" "$image" sh -c "$INNER" || status=1
done
exit $status
