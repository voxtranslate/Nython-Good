#!/bin/bash
# tools/build_sdl3.sh - build the real SDL3, SDL3_ttf and SDL3_image from
# source into a prefix, for containers where no SDL3 package exists (Ubuntu
# 24.04 has none). Nython then builds against it:
#
#   tools/build_sdl3.sh                     # -> /opt/sdl3 (sources in /opt/sdl3-src)
#   PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make cli BUILD=build-sdl NYTHON_SDL_STUB=0
#   PKG_CONFIG_PATH=/opt/sdl3/lib/pkgconfig make     BUILD=build-sdl NYTHON_SDL_STUB=0
#
# The binaries find the libraries through an rpath (see the Makefile). They
# run on a real display, under Xvfb (SDL_VIDEODRIVER=x11 DISPLAY=:99), or with
# no display at all (SDL_VIDEODRIVER=offscreen); tools/ide_e2e.py drives them
# with NY_IDE_BINARY=build-sdl/nython (HANDOFF.md, "Real SDL3").
#
# Needs git, cmake, ninja, a C/C++ compiler and the X11 development headers
# (libx11-dev libxext-dev). Optional X11 extensions and Wayland/KMSDRM are
# switched off so nothing else is required. SDL3_ttf is built as the release
# binaries are: with its vendored FreeType and HarfBuzz. Without HarfBuzz,
# SDL_ttf applies pair kerning as a per-glyph draw offset that the following
# glyphs do not follow, so "Text" draws as "Te xt" - visibly so at 2x.
set -e
PREFIX=${PREFIX:-/opt/sdl3}
SRC=${SRC:-/opt/sdl3-src}
JOBS=${JOBS:-$(nproc)}
mkdir -p "$SRC"
cd "$SRC"
for spec in "SDL release-3.4.8" "SDL_ttf release-3.2.2" "SDL_image release-3.4.6"; do
  set -- $spec
  [ -d "$1" ] || git clone -q --depth 1 --branch "$2" "https://github.com/libsdl-org/$1.git" "$1"
done
(cd SDL_ttf && git submodule update --init --depth 1 external/freetype external/harfbuzz)

cmake -S SDL -B SDL/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_WAYLAND=OFF -DSDL_KMSDRM=OFF \
  -DSDL_X11_XCURSOR=OFF -DSDL_X11_XDBE=OFF -DSDL_X11_XINPUT=OFF -DSDL_X11_XFIXES=OFF \
  -DSDL_X11_XRANDR=OFF -DSDL_X11_XSCRNSAVER=OFF -DSDL_X11_XSHAPE=OFF -DSDL_X11_XSYNC=OFF \
  -DSDL_X11_XTEST=OFF
cmake --build SDL/build -j "$JOBS" && cmake --install SDL/build

cmake -S SDL_ttf -B SDL_ttf/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLTTF_VENDORED=ON -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF \
  -DSDLTTF_SAMPLES=OFF
cmake --build SDL_ttf/build -j "$JOBS" && cmake --install SDL_ttf/build

cmake -S SDL_image -B SDL_image/build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLIMAGE_VENDORED=OFF -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF \
  -DSDLIMAGE_TIF=OFF -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_SAMPLES=OFF -DSDLIMAGE_TESTS=OFF
cmake --build SDL_image/build -j "$JOBS" && cmake --install SDL_image/build
echo "SDL3 installed in $PREFIX"
