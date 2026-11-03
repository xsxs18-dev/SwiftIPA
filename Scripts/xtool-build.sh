#!/usr/bin/env bash
# Local build with xtool (https://xtool.sh), e.g. on Linux.
#   Scripts/xtool-build.sh           unsigned IPA in xtool/SwiftIPA.ipa
#   Scripts/xtool-build.sh install   build, sign and install on the connected iPhone (xtool dev)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f Vendor/zsign/src/bundle.cpp ] || [ ! -d Vendor/openssl-include/openssl ]; then
  ./Scripts/fetch-dependencies.sh
fi
ln -sfn ../Vendor/zsign/src ZSignKit/zsign

export PKG_CONFIG_PATH="$ROOT/Support/pkgconfig"

if [ "${1:-}" = "install" ]; then
  exec xtool dev
fi
xtool dev build --ipa "$@"
