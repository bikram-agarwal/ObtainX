#!/bin/bash
set -euo pipefail
# Convenience script — invoke with "build" to build only, or no args for sync+build.

CURR_DIR="$(pwd)"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)"
trap "cd \"$CURR_DIR\"" EXIT
cd "$SCRIPT_DIR"

SYNC_MODE=false
if [ "${1:-build}" != "build" ]; then
    SYNC_MODE=true
fi

if $SYNC_MODE; then
    git fetch && git merge origin/main && git push
fi

# Update local Flutter
git submodule update --remote
cd .flutter
git fetch
git checkout stable
git pull
FLUTTER_GIT_URL="https://github.com/flutter/flutter/" ./bin/flutter upgrade
cd ..

# Keep global Flutter, if any, in sync
if [ -f ~/flutter/bin/flutter ]; then
    cd ~/flutter
    ./bin/flutter channel stable
    ./bin/flutter upgrade
    cd "$SCRIPT_DIR"
fi

if [ -z "$(which flutter)" ]; then
    export PATH="$PATH:$SCRIPT_DIR/.flutter/bin"
fi

# flutter pub upgrade --tighten --major-versions

flutter clean
flutter pub get
APP_VERSION="$(grep '^version: ' pubspec.yaml | sed 's/version: //; s/+.*//' | head -1)"
DART_DEFINE="--dart-define=APP_VERSION=$APP_VERSION"
# Release AOT flags: keep the Dart symbol table out of the APK
# (--split-debug-info), which shrinks libapp.so.
# --extra-gen-snapshot-options=--strip was dropped after measuring it: with
# --split-debug-info already in place the resulting libapp.so is byte-identical
# with and without it.
# Deliberately no --obfuscate: class names are persisted (AppSource.
# sourceIdentifier is runtimeType.toString(), App.overrideSource stores it),
# so mangling them would break tracked apps, backups and cross-flavor installs
# on the next release. Symbols are kept for line-number symbolication only.
# The universal and per-ABI builds write to separate directories: both emit
# app.android-*.symbols, and one run would otherwise overwrite the other's.
AOT_FLAGS="--release --split-debug-info=./debug_symbols/universal"
AOT_FLAGS_PER_ABI="--release --split-debug-info=./debug_symbols/split"
# TODO: Remove once Flutter's libdartjni.so no longer embeds a non-reproducible build ID
sed -i -E 's/^(-Wl,)(--build-id=none,)?/\1--build-id=none,/' ${PUB_CACHE:-$HOME/.pub-cache}/hosted/*/jni-*/src/CMakeLists.txt

flutter build apk $DART_DEFINE $AOT_FLAGS --flavor normal && flutter build apk $DART_DEFINE $AOT_FLAGS_PER_ABI --split-per-abi --flavor normal
for file in ./build/app/outputs/flutter-apk/app-*normal*.apk*; do mv "$file" "${file//-normal/}"; done
# Do the same for the F-Droid flavour. No AOT_FLAGS here: F-Droid rebuilds this
# flavour independently and must reproduce it byte for byte, so it stays on the
# plain release build the fdroiddata recipe uses.
flutter build apk $DART_DEFINE --flavor fdroid -t lib/main_fdroid.dart && \
    flutter build apk $DART_DEFINE --split-per-abi --flavor fdroid -t lib/main_fdroid.dart
for file in ./build/app/outputs/flutter-apk/*.sha1; do gpg --sign --detach-sig "$file"; done
rsync -r ./build/app/outputs/flutter-apk/ ~/Downloads/Obtainium-build/
cd ~/Downloads/Obtainium-build/
for apk in *.apk; do
    PREFIX="$(echo "$apk" | head -c -5)"
    zip "$PREFIX" "$PREFIX"*
done
mkdir -p zips
shopt -s nullglob
mv *.zip zips/
