#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
ZSIGN_DIR="$VENDOR/zsign"
ZSIGN_REPO="https://github.com/zhlynn/zsign.git"
# Pinned so a change on zsign's master can't break the build or signing unnoticed.
# To update: set a newer commit here, build, sign a few apps, then commit.
ZSIGN_REF="${ZSIGN_REF:-9299685bab7ef99827e06e5dfda93af747386590}"
OPENSSL_INCLUDE_DIR="$VENDOR/openssl-include/openssl"
# Must match the OpenSSL package version in project.yml and Package.swift.
OPENSSL_TAG="${OPENSSL_TAG:-3.6.5000}"
OPENSSL_RELEASE_API="https://api.github.com/repos/krzyzanowskim/OpenSSL/releases/tags/$OPENSSL_TAG"

mkdir -p "$VENDOR"

if [ ! -d "$ZSIGN_DIR/.git" ]; then
  echo "==> Cloning zsign"
  rm -rf "$ZSIGN_DIR"
  git init -q "$ZSIGN_DIR"
  git -C "$ZSIGN_DIR" remote add origin "$ZSIGN_REPO"
fi
echo "==> Checking out zsign $ZSIGN_REF"
git -C "$ZSIGN_DIR" fetch -q --depth 1 origin "$ZSIGN_REF"
git -C "$ZSIGN_DIR" checkout -q FETCH_HEAD

# The SwiftPM/xtool build (Package.swift) expects zsign's sources here.
ln -sfn ../Vendor/zsign/src "$ROOT/ZSignKit/zsign"

echo "==> Checking the sources SwiftIPA expects"
for file in src/bundle.cpp src/bundle.h src/openssl.cpp src/openssl.h src/macho.cpp src/macho.h src/archo.cpp src/archo.h src/signing.cpp src/signing.h src/common/common.h src/common/mach-o.h; do
  if [ ! -f "$ZSIGN_DIR/$file" ]; then
    echo "    missing: $file (zsign moved things around again, check ZSignBridge.mm and project.yml)" >&2
  fi
done

echo "==> Fetching OpenSSL headers for zsign's #include <openssl/...>"
rm -rf "$VENDOR/openssl-include"
mkdir -p "$OPENSSL_INCLUDE_DIR"

TMP_ZIP="$(mktemp)"
TMP_EXTRACT="$(mktemp -d)"
trap 'rm -f "$TMP_ZIP"; rm -rf "$TMP_EXTRACT"' EXIT

AUTH_HEADER=()
if [ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]; then
  AUTH_HEADER=(-H "Authorization: Bearer ${GH_TOKEN:-$GITHUB_TOKEN}")
fi

curl_retry() {
  local attempt
  for attempt in 1 2 3 4 5; do
    if curl -fsSL -A "SwiftIPA-fetch-dependencies" "${AUTH_HEADER[@]}" "$@"; then
      return 0
    fi
    echo "    curl attempt $attempt failed, retrying in $((attempt * 3))s..." >&2
    sleep $((attempt * 3))
  done
  return 1
}

DOWNLOAD_URL=$(curl_retry "$OPENSSL_RELEASE_API" | grep -o '"browser_download_url": *"[^"]*OpenSSL.xcframework.zip"' | head -1 | sed -E 's/.*"(https[^"]+)"/\1/')
if [ -z "$DOWNLOAD_URL" ]; then
  echo "    could not resolve the latest OpenSSL.xcframework.zip release asset" >&2
  exit 1
fi

curl_retry -o "$TMP_ZIP" "$DOWNLOAD_URL"
unzip -q "$TMP_ZIP" -d "$TMP_EXTRACT" "OpenSSL.xcframework/ios-arm64/OpenSSL.framework/Headers/*"

HEADERS_SRC="$TMP_EXTRACT/OpenSSL.xcframework/ios-arm64/OpenSSL.framework/Headers"
if [ ! -d "$HEADERS_SRC" ]; then
  echo "    OpenSSL's xcframework layout changed, check Scripts/fetch-dependencies.sh" >&2
  exit 1
fi

cp "$HEADERS_SRC"/*.h "$OPENSSL_INCLUDE_DIR/"

echo
echo "Done. Now run:"
echo "  xcodegen generate && open SwiftIPA.xcodeproj    (Xcode)"
echo "  Scripts/xtool-build.sh                           (xtool, e.g. on Linux)"
