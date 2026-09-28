#!/bin/bash
# tools/cross_windows.sh - build nython.exe from Linux exactly as nython.cbp
# builds it in Code::Blocks, and run it under Wine, to test the Windows build
# without a Windows machine.
#
#   tools/cross_windows.sh deps     # once per ARCH: SDL3 + SDL3_ttf + SDL3_image
#                                   # for MinGW, and busybox-w32 (a POSIX sh.exe)
#   tools/cross_windows.sh build    # nython.exe from nython.cbp's Release target
#   build-win/nywin script.ny       # run it under Wine
#   python3 tools/sweep.py --bin build-win/nywin    # the whole sweep on it
#
#   ARCH=i686 tools/cross_windows.sh deps|build     # the 32-bit build
#   (w64devkit's i686 edition, 32-bit MSYS2); output in build-win32/
#
# The units, compiler flags, linker options and libraries all come from
# nython.cbp (tools/cbp.py), so a source file the project does not list, or a
# flag only the project sets, shows up here as it does for a Code::Blocks
# user. Compiler warnings are kept in $OUT/warnings.log and summarised.
#
# Needs: g++-mingw-w64-{x86-64,i686}-posix, wine (and wine32:i386 for i686),
# cmake, ninja, Xvfb, and the SDL sources tools/build_sdl3.sh clones into
# /opt/sdl3-src.
#
# Under Wine: SDL's offscreen video driver (no window is shown), busybox-w32
# as the POSIX shell command strings run through (NY_SH; Git for Windows'
# sh.exe on a real machine), and metric-compatible stand-ins for Arial and
# Consolas in the Wine prefix (Wine ships no Windows fonts). Wine needs an X
# display for its own processes: DISPLAY defaults to :99 (start Xvfb :99).
# Each build runs under its own loader (with wine32 installed, a plain `wine`
# picks the 32-bit one, which cannot open a 64-bit prefix).
set -e
REPO=$(cd "$(dirname "$0")/.." && pwd)
SRC=${SRC:-/opt/sdl3-src}
ARCH=${ARCH:-x86_64}
case "$ARCH" in
    x86_64) TRIPLE=x86_64-w64-mingw32; PREFIX=${PREFIX:-/opt/sdl3-mingw};   OUT=${OUT:-$REPO/build-win}
            WINEARCH_=win64; BB_CONFIG=mingw64_defconfig; LOADER=/usr/lib/wine/wine64 ;;
    i686)   TRIPLE=i686-w64-mingw32;   PREFIX=${PREFIX:-/opt/sdl3-mingw32}; OUT=${OUT:-$REPO/build-win32}
            WINEARCH_=win32; BB_CONFIG=mingw32_defconfig; LOADER=/usr/lib/wine/wine ;;
    *) echo "ARCH must be x86_64 or i686"; exit 2 ;;
esac
CXX=$TRIPLE-g++-posix
JOBS=${JOBS:-$(nproc)}
BUSYBOX=/opt/busybox-w32-$ARCH

deps() {
    local tc="$OUT/mingw.cmake"
    mkdir -p "$OUT"
    cat > "$tc" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR $ARCH)
set(CMAKE_C_COMPILER $TRIPLE-gcc-posix)
set(CMAKE_CXX_COMPILER $TRIPLE-g++-posix)
set(CMAKE_RC_COMPILER $TRIPLE-windres)
set(CMAKE_FIND_ROOT_PATH /usr/$TRIPLE $PREFIX)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
    [ -d "$SRC/SDL" ] || { echo "run tools/build_sdl3.sh first (it clones the SDL sources)"; exit 1; }
    cd "$SRC"
    local b="build-win-$ARCH"
    cmake -S SDL -B SDL/$b -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF
    cmake --build SDL/$b -j "$JOBS" && cmake --install SDL/$b
    cmake -S SDL_ttf -B SDL_ttf/$b -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLTTF_VENDORED=ON \
        -DSDLTTF_HARFBUZZ=ON -DSDLTTF_PLUTOSVG=OFF -DSDLTTF_SAMPLES=OFF
    cmake --build SDL_ttf/$b -j "$JOBS" && cmake --install SDL_ttf/$b
    cmake -S SDL_image -B SDL_image/$b -G Ninja -DCMAKE_TOOLCHAIN_FILE="$tc" -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" -DCMAKE_PREFIX_PATH="$PREFIX" -DSDLIMAGE_VENDORED=OFF \
        -DSDLIMAGE_BACKEND_STB=ON -DSDLIMAGE_AVIF=OFF -DSDLIMAGE_JXL=OFF -DSDLIMAGE_TIF=OFF \
        -DSDLIMAGE_WEBP=OFF -DSDLIMAGE_SAMPLES=OFF -DSDLIMAGE_TESTS=OFF
    cmake --build SDL_image/$b -j "$JOBS" && cmake --install SDL_image/$b
    if [ ! -f "$BUSYBOX/busybox.exe" ]; then
        [ -d "$BUSYBOX" ] || git clone -q --depth 1 https://github.com/rmyorston/busybox-w32.git "$BUSYBOX"
        (cd "$BUSYBOX" && make -s $BB_CONFIG && make -s -j "$JOBS" CROSS_COMPILE=$TRIPLE-)
    fi
}

build() {
    mkdir -p "$OUT/obj" "$OUT/sh"
    cd "$REPO"
    python3 tools/cbp.py check
    local flags ldflags
    flags=$(python3 tools/cbp.py cxxflags Release --sdl "$PREFIX")
    ldflags=$(python3 tools/cbp.py ldflags Release --sdl "$PREFIX")
    # OPT overrides the project's optimisation level (e.g. OPT=-O1 for a
    # quicker test build); by default the project's own flags are used.
    [ -n "$OPT" ] && flags="$(echo "$flags" | sed 's/ -O[0-3s]\b//g') $OPT"
    export CXX OUT flags
    : > "$OUT/warnings.log"
    # Recompile a unit when it, or any header, is newer than its object.
    python3 tools/cbp.py units | xargs -P "$JOBS" -I{} sh -c '
        o="$OUT/obj/$(echo {} | tr / _ | sed "s/\.cpp$/.o/")"
        if [ ! -f "$o" ] || [ -n "$(find {} include -newer "$o" -name "*.[ch]pp" -print -quit)" ]; then
            $CXX $flags -c {} -o "$o" 2> "$o.log" || { cat "$o.log"; echo "COMPILE FAIL {}"; exit 1; }
        fi'
    cat "$OUT"/obj/*.o.log >> "$OUT/warnings.log" 2>/dev/null || true
    local objs
    objs=$(python3 tools/cbp.py units | tr / _ | sed "s|\.cpp$|.o|; s|^|$OUT/obj/|")
    $CXX -o "$OUT/nython.exe" $objs $ldflags
    # x64: no function whose unwind info the Windows unwinder misreads
    # (frame pointer set before the allocation, XMM saves) - see the tool.
    [ "$ARCH" = x86_64 ] && python3 tools/pe_unwind_check.py "$OUT/nython.exe" "$TRIPLE-"
    local nw
    nw=$(grep -c "warning:" "$OUT/warnings.log" || true)
    echo "warnings: $nw (unique sites: $(grep -o '^[^ ]*:[0-9]*:[0-9]*: warning: .*' "$OUT/warnings.log" | sort -u | wc -l); $OUT/warnings.log)"
    cp "$PREFIX"/bin/*.dll "$OUT/"
    local gcc_rt=/usr/lib/gcc/$TRIPLE/*-posix
    cp $gcc_rt/libstdc++-6.dll "$OUT/"
    cp $gcc_rt/libgcc_s_*.dll "$OUT/" 2>/dev/null || true
    cp /usr/$TRIPLE/lib/libwinpthread-1.dll "$OUT/"
    # busybox-w32 as the POSIX sh, and as the tools Git for Windows keeps
    # beside its sh.exe (busybox picks the applet by its file name). The
    # 64-bit one serves a 32-bit build too.
    local bb="$BUSYBOX/busybox.exe"
    [ -f "$bb" ] || bb=/opt/busybox-w32-x86_64/busybox.exe
    [ -f "$bb" ] || bb=/opt/busybox-w32/busybox.exe
    if [ -f "$bb" ]; then
        for t in sh echo cat pwd sleep true false printf kill ls grep; do
            cp "$bb" "$OUT/sh/$t.exe"
        done
    fi
    # The Wine prefix, with Arial/Consolas stand-ins (Liberation / DejaVu).
    export WINEPREFIX="$OUT/wineprefix" WINEDEBUG=-all
    [ -x "$LOADER" ] || LOADER=$(command -v wine)
    [ -d "$WINEPREFIX" ] || WINEARCH=$WINEARCH_ WINELOADER=$LOADER DISPLAY=${DISPLAY:-:99} "$LOADER" wineboot -i >/dev/null 2>&1 || true
    local fonts="$WINEPREFIX/drive_c/windows/Fonts"
    mkdir -p "$fonts"
    cp /usr/share/fonts/truetype/liberation/LiberationSans-Regular.ttf "$fonts/arial.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/liberation/LiberationSans-Bold.ttf "$fonts/arialbd.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf "$fonts/consola.ttf" 2>/dev/null || true
    cp /usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf "$fonts/consolab.ttf" 2>/dev/null || true
    cat > "$OUT/nywin" <<EOF
#!/bin/sh
# Runs $OUT/nython.exe under Wine (see tools/cross_windows.sh).
export WINEPREFIX="$OUT/wineprefix" WINEDEBUG=-all DISPLAY=\${DISPLAY:-:99} SDL_VIDEODRIVER=\${SDL_VIDEODRIVER:-offscreen}
[ -f "$OUT/sh/sh.exe" ] && export NY_SH="Z:$OUT/sh/sh.exe"
export WINELOADER="$LOADER"
exec "$LOADER" "$OUT/nython.exe" "\$@"
EOF
    chmod +x "$OUT/nywin"
    echo "built $OUT/nython.exe ($ARCH); run with $OUT/nywin"
}

case "${1:-build}" in
    deps) deps ;;
    build) build ;;
    *) echo "usage: [ARCH=x86_64|i686] $0 deps|build"; exit 2 ;;
esac
