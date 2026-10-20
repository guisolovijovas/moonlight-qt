#!/bin/bash
#
# Builds all Moonlight macOS dependencies from source with a macOS 10.13
# deployment target and stages them into libs/mac (the layout expected by
# app/app.pro). This replaces setup-deps.py, whose prebuilt libraries are
# compiled for macOS 13.0 and will not load on older systems.
#
# x86_64 (Intel) only: macOS 10.13 only ever ran on Intel Macs.
#
# Source revisions are pinned to the same commits used by the upstream
# moonlight-stream/moonlight-qt-deps repo at DEPS_REV, so the resulting
# libraries have the same sonames that app.pro links against
# (libavcodec.63, libavutil.61, libswscale.10, libssl.3, ...).
set -euo pipefail

MACOS_MIN="${MACOS_MIN:-10.13}"
ARCH="x86_64"
JOBS="$(sysctl -n hw.logicalcpu)"

# Revision of moonlight-stream/moonlight-qt-deps that produced the v19 prebuilts
DEPS_REV="79621271459ebb945343f58d7acd6ad24d402c38"

FFMPEG_REV="946fcce07b6dcd0331c8cc609192aeff5e1924f8"   # FFmpeg release/9.0
OPENSSL_REV="c8bd5a57108599ac650bbae77fcabe3109dab2e8"  # OpenSSL 3.6
OPUS_REV="22244de5a79bd1d6d623c32e72bf1954b56235be"     # Opus
DISCORD_RPC_REV="7bcf3b3fdd02d4d5072971ef1d5b4e6dd3a765dc" # cgutman/discord-rpc
SDLTTF_REV="a883e490e30fb44a5336ea3dcb990c6982c5216f"   # SDL_ttf (SDL2 branch)
SDL2_REV="release-2.32.10"                              # Genuine SDL2 release

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$REPO_ROOT/deps-src"
OUT="$REPO_ROOT/deps-out"
LIBDIR="$REPO_ROOT/libs/mac"

export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

# nasm is required for FFmpeg's hand-written x86 assembly but is not
# preinstalled on the runner image.
if ! command -v nasm > /dev/null; then
    echo "==> Installing nasm"
    brew install nasm
fi

rm -rf "$LIBDIR"
mkdir -p "$SRC" "$OUT" "$LIBDIR/lib" "$LIBDIR/include/SDL2"

fetch() {
    local name="$1" url="$2"
    if [ ! -d "$SRC/$name" ]; then
        echo "==> Fetching $name"
        mkdir -p "$SRC/$name"
        curl -fsSL "$url" | tar xz -C "$SRC/$name" --strip-components=1
    fi
}

echo "==> Fetching sources"
fetch FFmpeg "https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/$FFMPEG_REV"
fetch openssl "https://codeload.github.com/openssl/openssl/tar.gz/$OPENSSL_REV"
fetch opus "https://codeload.github.com/xiph/opus/tar.gz/$OPUS_REV"
fetch discord-rpc "https://codeload.github.com/cgutman/discord-rpc/tar.gz/$DISCORD_RPC_REV"
fetch SDL_ttf "https://codeload.github.com/libsdl-org/SDL_ttf/tar.gz/$SDLTTF_REV"
fetch SDL2 "https://codeload.github.com/libsdl-org/SDL/tar.gz/$SDL2_REV"

#
# FFmpeg (libavcodec/libavutil/libswscale + VideoToolbox hwaccels)
# Same minimal configuration as upstream's build-ffmpeg-macos.sh, but without
# Vulkan/dav1d/AV1 (irrelevant on 10.13-era hardware and Vulkan requires
# macOS 12+ via MoltenVK).
#
echo "==> Building FFmpeg"
pushd "$SRC/FFmpeg"
curl -fsSL "https://raw.githubusercontent.com/moonlight-stream/moonlight-qt-deps/$DEPS_REV/patches/ffmpeg_metal_vt.patch" | patch -p1
./configure --prefix="$OUT/ffmpeg" \
    --extra-cflags="-mmacosx-version-min=$MACOS_MIN -arch $ARCH" \
    --extra-ldflags="-mmacosx-version-min=$MACOS_MIN -arch $ARCH" \
    --cc=clang --arch=$ARCH --enable-cross-compile \
    --install-name-dir=@loader_path/../Frameworks \
    --enable-pic --fatal-warnings --enable-shared --disable-static \
    --disable-all --disable-autodetect \
    --enable-avcodec --enable-avformat --enable-swscale \
    --enable-decoder=h264 --enable-decoder=hevc \
    --enable-videotoolbox --enable-hwaccel=h264_videotoolbox --enable-hwaccel=hevc_videotoolbox
make -j"$JOBS"
make install
popd
cp -a "$OUT/ffmpeg"/lib/libavcodec.6*.dylib "$OUT/ffmpeg"/lib/libavutil.6*.dylib "$OUT/ffmpeg"/lib/libswscale.10*.dylib "$LIBDIR/lib/"
cp -a "$OUT/ffmpeg"/include/libavcodec "$OUT/ffmpeg"/include/libavformat "$OUT/ffmpeg"/include/libavutil "$OUT/ffmpeg"/include/libswscale "$LIBDIR/include/"

#
# OpenSSL 3 (libssl.3/libcrypto.3)
# Flags mirror upstream's build-openssl.sh.
#
echo "==> Building OpenSSL"
pushd "$SRC/openssl"
./Configure --prefix="$OUT/openssl" --openssldir="$OUT/openssl" \
    "darwin64-$ARCH-cc" -mmacosx-version-min="$MACOS_MIN" \
    no-tests no-engine no-apps no-legacy no-dso
make -j"$JOBS"
make install_sw
popd
install_name_tool -id @loader_path/../Frameworks/libcrypto.3.dylib "$OUT/openssl/lib/libcrypto.3.dylib"
install_name_tool -id @loader_path/../Frameworks/libssl.3.dylib "$OUT/openssl/lib/libssl.3.dylib"
install_name_tool -change "$OUT/openssl/lib/libcrypto.3.dylib" @loader_path/../Frameworks/libcrypto.3.dylib "$OUT/openssl/lib/libssl.3.dylib"
cp -a "$OUT/openssl"/lib/libssl.3.dylib "$OUT/openssl"/lib/libcrypto.3.dylib "$LIBDIR/lib/"
cp -a "$OUT/openssl/include/openssl" "$LIBDIR/include/"

#
# Opus
#
echo "==> Building Opus"
cmake -S "$SRC/opus" -B "$SRC/opus/build" \
    -DOPUS_BUILD_SHARED_LIBRARY=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_INSTALL_PREFIX="$OUT/opus" > /dev/null
cmake --build "$SRC/opus/build" -j "$JOBS" > /dev/null
cmake --install "$SRC/opus/build" > /dev/null
OPUS_DYLIB="$(find "$OUT/opus/lib" -name 'libopus.*.dylib' -type f | head -n 1)"
install_name_tool -id @rpath/libopus.0.dylib "$OPUS_DYLIB"
cp -a "$OPUS_DYLIB" "$LIBDIR/lib/libopus.0.dylib"
cp -a "$OUT/opus"/include/opus/*.h "$LIBDIR/include/"

#
# SDL2 (genuine SDL2, unlike upstream which wraps SDL3 via sdl2-compat;
# SDL2 natively supports ancient macOS versions).
#
echo "==> Building SDL2"
cmake -S "$SRC/SDL2" -B "$SRC/SDL2/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DSDL_TEST=OFF -DSDL_TESTS=OFF \
    -DCMAKE_INSTALL_PREFIX="$OUT/SDL2" > /dev/null
cmake --build "$SRC/SDL2/build" -j "$JOBS" > /dev/null
cmake --install "$SRC/SDL2/build" > /dev/null
SDL2_DYLIB="$(find "$OUT/SDL2/lib" -name 'libSDL2-*.dylib' -type f | head -n 1)"
install_name_tool -id @rpath/libSDL2.dylib "$SDL2_DYLIB"
cp -a "$SDL2_DYLIB" "$LIBDIR/lib/libSDL2.dylib"
cp -a "$SRC/SDL2"/include/*.h "$LIBDIR/include/SDL2/"

#
# SDL2_ttf (with vendored/freestatically-linked freetype)
#
echo "==> Building SDL2_ttf"
cmake -S "$SRC/SDL_ttf" -B "$SRC/SDL_ttf/build" \
    -DSDL2TTF_VENDORED=ON -DSDL2TTF_SAMPLES=OFF \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" \
    -DCMAKE_PREFIX_PATH="$OUT/SDL2" \
    -DCMAKE_INSTALL_PREFIX="$OUT/SDL2_ttf" > /dev/null
cmake --build "$SRC/SDL_ttf/build" -j "$JOBS" > /dev/null
cmake --install "$SRC/SDL_ttf/build" > /dev/null
TTF_DYLIB="$(find "$OUT/SDL2_ttf/lib" -name 'libSDL2_ttf*.dylib' -type f | head -n 1)"
install_name_tool -id @rpath/libSDL2_ttf.dylib "$TTF_DYLIB"
cp -a "$TTF_DYLIB" "$LIBDIR/lib/libSDL2_ttf.dylib"
cp -a "$SRC/SDL_ttf/SDL_ttf.h" "$LIBDIR/include/SDL2/SDL_ttf.h"

#
# discord-rpc
#
echo "==> Building discord-rpc"
cmake -S "$SRC/discord-rpc" -B "$SRC/discord-rpc/build" \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DBUILD_SHARED_LIBS=ON \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES="$ARCH" \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOS_MIN" > /dev/null
cmake --build "$SRC/discord-rpc/build" -j "$JOBS" > /dev/null
DISCORD_DYLIB="$(find "$SRC/discord-rpc/build" -name 'libdiscord-rpc*.dylib' -type f | head -n 1)"
install_name_tool -id @rpath/libdiscord-rpc.dylib "$DISCORD_DYLIB"
cp -a "$DISCORD_DYLIB" "$LIBDIR/lib/libdiscord-rpc.dylib"
cp -a "$SRC/discord-rpc"/include/*.h "$LIBDIR/include/"

#
# Bundle any extra dylib dependencies that ended up referenced by absolute
# build-tree paths (e.g. a shared freetype from the vendored SDL2_ttf build).
#
echo "==> Staging extra dylib dependencies"
for dylib in "$LIBDIR"/lib/*.dylib; do
    while read -r dep; do
        depname="$(basename "$dep")"
        if [ ! -f "$LIBDIR/lib/$depname" ]; then
            echo "  Bundling extra dependency: $depname (needed by $(basename "$dylib"))"
            install_name_tool -id "@rpath/$depname" "$dep"
            cp -a "$dep" "$LIBDIR/lib/"
            install_name_tool -change "$dep" "@rpath/$depname" "$dylib"
        fi
    done < <(otool -L "$dylib" | tail -n +2 | awk '{print $1}' | grep -v '^/usr/lib/\|^/System/' || true)
done

echo "==> Verifying deployment targets"
python3 "$REPO_ROOT/scripts/check-macos-minos.py" "$LIBDIR/lib"

echo "==> Staged dependencies:"
ls -l "$LIBDIR/lib"
