#!/bin/bash
# Build the fork as an installable app folder: the official release tarball of the tag this branch sits on, with
# lib/ appinfo/ templates/ l10n/ img/ from this checkout and a js/ built from it. bin-ext/ (exiftool, go-vod, vips)
# stays as released, so no binary is fetched or built here.
#
#   scripts/facewright-build.sh          no arguments; builds the tag `git describe` finds
#
# Output: build/memories-<tag>-facewright.tar.gz (top directory memories/). build/release/ keeps the unpacked
# official release for comparison. Needs git, curl, tar and docker (Node runs in node:24, as the calling user).
set -euo pipefail
cd "$(dirname "$0")/.."

TAG=$(git describe --tags --abbrev=0)
URL="https://github.com/pulsejet/memories/releases/download/$TAG/memories.tar.gz"
BUILD=build
OVERLAY="lib appinfo templates l10n img js"

# Uncommitted changes in what goes into the build would produce something no commit contains.
if ! git diff --quiet HEAD -- lib appinfo templates l10n img src package.json package-lock.json; then
    echo "lib/ appinfo/ templates/ l10n/ img/ src/ or the package files differ from HEAD; commit or stash first" >&2
    exit 1
fi

mkdir -p "$BUILD"
# A run that stops part-way must not leave the previous run's package lying next to its error.
OUT="$BUILD/memories-$TAG-facewright.tar.gz"
rm -f "$OUT"

# 1. The tarball.
if [ ! -f "$BUILD/memories-$TAG.tar.gz" ]; then
    curl -fL --retry 3 -o "$BUILD/memories-$TAG.tar.gz.part" "$URL"
    mv "$BUILD/memories-$TAG.tar.gz.part" "$BUILD/memories-$TAG.tar.gz"
fi
echo "release $TAG sha256: $(sha256sum "$BUILD/memories-$TAG.tar.gz" | cut -d' ' -f1)"

# 2. Unpack: once untouched (build/release, for comparison), once to overlay (build/memories).
rm -rf "$BUILD/release" "$BUILD/memories"
mkdir "$BUILD/release"
tar --no-same-owner -xzf "$BUILD/memories-$TAG.tar.gz" -C "$BUILD/release"
cp -a "$BUILD/release/memories" "$BUILD/memories"

# 3. Build js/ here, in Node 24 (package.json asks for >= 24). This is `make js-init build-js-production`.
docker run --rm -u "$(id -u):$(id -g)" -e HOME=/tmp -v "$PWD":/src -w /src node:24 \
    sh -c 'npm ci && bash scripts/patch-external.sh && npm run build'

# 4. Replace from this checkout, each directory removed first so nothing of the release's is left inside it.
for d in $OVERLAY; do
    [ -d "$d" ] || { echo "$d/ is missing from the checkout" >&2; exit 1; }
    rm -rf "${BUILD:?}/memories/$d"
    cp -a "$d" "$BUILD/memories/$d"
done

# 5. The store's signature file must not survive next to changed files: Nextcloud would report every one as
# modified. The rm -rf of appinfo/ above removes it; this stops the build if that ever stops being true.
if [ -e "$BUILD/memories/appinfo/signature.json" ]; then
    echo "appinfo/signature.json is still in the build; refusing to package it" >&2
    exit 1
fi

# 6. Package, with the top directory memories/.
tar --owner=0 --group=0 --numeric-owner -czf "$OUT" -C "$BUILD" memories
echo "fork build $OUT sha256: $(sha256sum "$OUT" | cut -d' ' -f1)"
