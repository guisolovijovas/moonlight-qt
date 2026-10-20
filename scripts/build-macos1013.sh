#!/bin/bash
#
# Builds Moonlight.app for macOS 10.13 (Intel x86_64) using Qt 5 and the
# 10.13-targeted dependency tree in libs/mac (see setup-deps-macos1013.sh).
#
# Produces build/installer-Release/Moonlight-macOS1013-<version>.dmg
set -euo pipefail

export MACOSX_DEPLOYMENT_TARGET="${MACOS_MIN:-10.13}"

SRC_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG=Release
BUILD_FOLDER="$SRC_ROOT/build/build-$BUILD_CONFIG"
INSTALLER_FOLDER="$SRC_ROOT/build/installer-$BUILD_CONFIG"

if [ -n "${CI_VERSION:-}" ]; then
    VERSION="$CI_VERSION"
else
    VERSION="$(cat "$SRC_ROOT/app/version.txt")"
fi

if [ ! -d "$SRC_ROOT/libs/mac" ]; then
    echo "libs/mac not found; run scripts/setup-deps-macos1013.sh first" >&2
    exit 1
fi

echo "==> Cleaning output directories"
rm -rf "$BUILD_FOLDER" "$INSTALLER_FOLDER"
mkdir -p "$BUILD_FOLDER" "$INSTALLER_FOLDER"

echo "==> Configuring with qmake"
pushd "$BUILD_FOLDER"
qmake "$SRC_ROOT/moonlight-qt.pro" \
    QMAKE_APPLE_DEVICE_ARCHS=x86_64 \
    QMAKE_MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"

echo "==> Compiling Moonlight ($BUILD_CONFIG)"
make -j"$(sysctl -n hw.logicalcpu)" "$(echo "$BUILD_CONFIG" | tr '[:upper:]' '[:lower:]')"
popd

APP_BUNDLE="$BUILD_FOLDER/app/Moonlight.app"

echo "==> Deploying Qt frameworks and QML"
macdeployqt "$APP_BUNDLE" -qmldir="$SRC_ROOT/app/gui" -appstore-compliant

echo "==> Verifying the deployment target of all bundle binaries"
python3 "$SRC_ROOT/scripts/check-macos-minos.py" "$APP_BUNDLE"

echo "==> Verifying bundle Info.plist"
MIN_PLIST="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP_BUNDLE/Contents/Info.plist")"
echo "    LSMinimumSystemVersion = $MIN_PLIST"
if [ "$MIN_PLIST" != "10.13" ]; then
    echo "ERROR: unexpected LSMinimumSystemVersion '$MIN_PLIST' (expected 10.13)" >&2
    exit 1
fi

echo "==> Creating DMG"
STAGING="$BUILD_FOLDER/dmg-staging"
rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP_BUNDLE" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "Moonlight" -srcfolder "$STAGING" -ov -format UDZO \
    "$INSTALLER_FOLDER/Moonlight-macOS1013-$VERSION.dmg"

echo "==> Done: $INSTALLER_FOLDER/Moonlight-macOS1013-$VERSION.dmg"
