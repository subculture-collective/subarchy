#!/usr/bin/env bash
# Build/check/stage the pinned Pult recipe without Arch or a host install.
# Downloads only its checksum-pinned source and catalog (about 3 MB).
set -euo pipefail

root=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

# Keep the recipe's build() and check() authoritative, including ldflags,
# catalog embedding, upstream tests and the Subarchy app-target checks.
startdir=$root/packaging/pult
srcdir=$work/src
pkgdir=$work/pkg
mkdir -p "$srcdir" "$pkgdir"
# shellcheck source-path=SCRIPTDIR/../..
# shellcheck source=packaging/pult/PKGBUILD
source "$startdir/PKGBUILD"
export GOMAXPROCS=${GOMAXPROCS:-2}
export GOFLAGS="${GOFLAGS:+$GOFLAGS }-p=2"

for i in "${!source[@]}"; do
  url=${source[$i]}
  name=${url##*/}
  if [[ $url == *::* ]]; then
    name=${url%%::*}
    url=${url#*::}
  fi
  curl --fail --location --silent --show-error --max-time 120 "$url" -o "$srcdir/$name"
  printf '%s  %s\n' "${sha256sums[$i]}" "$srcdir/$name" | sha256sum --check
done
tar -xzf "$srcdir/pult-${_commit}.tar.gz" -C "$srcdir"
build
check
package
"$pkgdir/usr/bin/pult" version
for path in usr/share/licenses/pult/LICENSE usr/share/licenses/pult/MIT.txt usr/share/doc/pult/README.md; do
  test -s "$pkgdir/$path"
done
echo 'pult-package-test: ok (recipe build, upstream tests, app targets, staged files)'
