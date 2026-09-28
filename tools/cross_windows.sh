#!/bin/bash
# tools/cross_windows.sh - build the Windows nython.exe from Linux and run it
# under Wine, to test the Windows build without a Windows machine.
#
#   tools/cross_windows.sh deps     # once: SDL3 + SDL3_ttf + SDL3_image for
#                                   # MinGW into /opt/sdl3-mingw, busybox-w32
#                                   # (a POSIX sh.exe) into /opt/busybox-w32
#   tools/cross_windows.sh build    # build-win/nython.exe, as nython.cbp
#                                   # builds it (same flags and units)
#   build-win/nywin script.ny       # run it under Wine
#   python3 tools/sweep.py --bin build-win/nywin    # the whole sweep on it
#
# Needs: g++-mingw-w64-x86-64-posix, wine (wine64), cmake, ninja, Xvfb, and
# the SDL sources tools/build_sdl3.sh clones into /opt/sdl3-src.
#
# Under Wine: SDL's offscreen video driver (no window is shown), busybox-w32
# as the POSIX shell command strings run through (NY_SH; Git for Windows'
# sh.exe on a real machine), and metric-compatible stand-ins for Arial and
# Consolas in the Wine prefix (Wine ships no Windows fonts). Wine needs an X
# display for its own processes: DISPLAY defaults to :99 (start Xvfb :99).
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-/opt/sdl3-src}
PREFIX=${PREFIX:-/opt/sdl3-mingw}
OUT=${OUT:-$REPO/build-win}
CXX=x86_64-w64-mingw32-g++-posix
JOBS=${JOBS:-$(nproc)}

deps() {
    local tc="$OUT/mingw.cmake"
    mkdir -p "$OUT"
    cat > "$tc" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR x86_64)
set(CMAKE_C_COMPILER x86_64-w64-mingw32-gcc-posix)
set(CMAKE_CXX_COMPILER x86_64-w64-mingw32-g++-posix)
set(CMAKE_RC_COMPILER x86_64-w64-mingw32-windres)
set(CMAKE_FIND_ROOT_PATH /usr/x86_64-w64-mingw32 $PREFIX)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
    [ -d "$SRC/SDL" ] || { echo "run tools/build_sdl3.sh first (it clones the SDL sources)"; exit 1; }
    cd "$SRC"
    cmake -S SDL -B SDL/build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build SDL/build-win -j "$JOBS" && cmake --install SDL/build-win
    cmake -S SDL_ttf -B SDL_ttf/build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLTTF_VENDORED=ON \
        -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
    cmake --build SDL_ttf/build-win -j "$JOBS" && cmake --install SDL_ttf/build-win
    cmake -S SDL_image -B SDL_image/build-win -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLIMAGE_VENDORED=OFF \
        -DSDLIMAGE_BACKEND_STB=ON -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_TIF=OFF \
        -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_SAMPLES=OFF -DSDLIMAGE_TESTS=OFF
    cmake --build SDL_image/build-win -j "$JOBS" && cmake --install SDL_image/build-win
    if [ ! -f /opt/busybox-w32/busybox.exe ]; then
        [ -d /opt/busybox-w32 ] || git clone -q --depth 1 https://github.com/rmyorston/busybox-w32.git /opt/busybox-w32
        (cd /opt/busybox-w32 && make -s mingw64_defconfig && make -s -j "$JOBS" CROSS_COMPILE=x86_64-w64-mingw32-)
    fi
}

build() {
    mkdir -p "$OUT/obj" "$OUT/sh"
    cd "$REPO"
    # The same flags as nython.cbp's Release target (-O1 instead of -O2: a
    # test build, and quicker).
    local flags="-std=c++20 -O1 -Wno-cpp -Wno-misleading-indentation -Wno-trigraphs -DNYTHON_WITH_IDE=1
                 -DSDL_MAIN_HANDLED=1 -D_WIN32_WINNT=0x0600 -march=x86-64 -fno-strict-aliasing -fwrapv
                 -fno-delete-null-pointer-checks -Iinclude -I$PREFIX/include"
    export CXX OUT flags
    ls src/*.cpp src/builtins/*.cpp | xargs -P "$JOBS" -I{} sh -c '
        o="$OUT/obj/$(basename {} .cpp).o"
        if [ ! -f "$o" ] || [ -n "$(find {} include -newer "$o" -name "*.[ch]pp" -print -quit)" ]; then
            $CXX $flags -c {} -o "$o" || { echo "COMPILE FAIL {}"; exit 1; }
        fi'
    $CXX -o "$OUT/nython.exe" "$OUT"/obj/*.o -Wl,--stack,8388608 -L"$PREFIX/lib" -lmingw32 -lSDL3 -lSDL3_ttf -lSDL3_image -lws2_32 -lpthread
    cp "$PREFIX"/bin/*.dll "$OUT/"
    cp /usr/lib/gcc/x86_64-w64-mingw32/*-posix/libstdc++-6.dll /usr/lib/gcc/x86_64-w64-mingw32/*-posix/libgcc_s_seh-1.dll \
       /usr/x86_64-w64-mingw32/lib/libwinpthread-1.dll "$OUT/"
    # busybox-w32 as the POSIX sh, and as the tools Git for Windows keeps
    # beside its sh.exe (busybox picks the applet by its file name).
    if [ -f /opt/busybox-w32/busybox.exe ]; then
        for t in sh echo cat pwd sleep true false printf kill ls grep; do
            cp /opt/busybox-w32/busybox.exe "$OUT/sh/$t.exe"
        done
    fi
    # The Wine prefix, with Arial/Consolas stand-ins (Liberation / DejaVu).
    export WINEPREFIX="$OUT/wineprefix" WINEDEBUG=-all
    [ -d "$WINEPREFIX" ] || DISPLAY=${DISPLAY:-:99} wineboot -i >/dev/null 2>&1 || true
    local fonts="$WINEPREFIX/drive_c/windows/Fonts"
    mkdir -p "$fonts"
    cp /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf "$fonts/arial.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf "$fonts/arialbd.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf "$fonts/consola.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf "$fonts/consolab.ttf" 2>/dev/null || true
    cat > "$OUT/nywin" <<EOF
#!/bin/sh
# Runs build-win/nython.exe under Wine (see tools/cross_windows.sh).
export WINEPREFIX="$OUT/wineprefix" WINEDEBUG=-all DISPLAY=\${DISPLAY:-:99} SDL_VIDEODRIVER=\${SDL_VIDEODRIVER:-offscreen}
[ -f "$OUT/sh/sh.exe" ] && export NY_SH="Z:$OUT/sh/sh.exe"
exec wine "$OUT/nython.exe" "\$@"
EOF
    chmod +x "$OUT/nywin"
    echo "built $OUT/nython.exe; run with $OUT/nywin"
}

case "${1:-build}" in
    deps) deps ;;
    build) build ;;
    *) echo "usage: $0 deps|build"; exit 2 ;;
esac
