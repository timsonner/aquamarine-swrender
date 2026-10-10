#!/usr/bin/env bash
# Rebuild pinned Hyprland 0.56.2 and Aquamarine 0.15.1 with the headless shm patches.
# Installs a private prefix under .build/prefix. Does not touch /usr.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREFIX="${PREFIX:-$ROOT/.build/prefix}"
SRC="${SRC:-$ROOT/.build/src}"
BUILD="${BUILD:-$ROOT/.build/build}"
CMAKE="${CMAKE:-$ROOT/.build/cmake/bin/cmake}"
JOBS="${JOBS:-2}"

export CC="${CC:-gcc-15}"
export CXX="${CXX:-g++-15}"
export PATH="$ROOT/.build/cmake/bin:$PREFIX/bin:${PATH}"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig:$PREFIX/lib/x86_64-linux-gnu/pkgconfig:$PREFIX/share/pkgconfig:${PKG_CONFIG_PATH:-}"
export CMAKE_PREFIX_PATH="$PREFIX${CMAKE_PREFIX_PATH:+:$CMAKE_PREFIX_PATH}"
export LD_LIBRARY_PATH="$PREFIX/lib:$PREFIX/lib/x86_64-linux-gnu${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

HYPRUTILS_REV="5a7b8cf221914ce4714407950e4ffbdddcd8b66f"
HYPRSCANNER_REV="b8632713a6beaf28b56f2a7b0ab2fb7088dbb404"
HYPRLANG_REV="090117506ddc3d7f26e650ff344d378c2ec329cc"
HYPRCURSOR_REV="39435900785d0c560c6ae8777d29f28617d031ef"
HYPRGRAPHICS_REV="8699c38f0e4a1ca3bfc84f84ba020509ced1f133"
HYPRPROTO_REV="1cb6db5fd6bb8aee419f4457402fa18293ace917"
HYPRWIRE_REV="7d935bb54674aa0fbd327d2a6888bd0630079ed0"
AQUAMARINE_REV="f31c47a1b9d300847d8fc3108ad959448103dfc1"
HYPRLAND_REV="efb50993780079460b0cbed1363e2166a2de1d9f"

mkdir -p "$PREFIX" "$SRC" "$BUILD"

if [[ ! -x "$CMAKE" ]]; then
    wget -q -O /tmp/cmake-3.31.8-linux-x86_64.tar.gz \
        https://github.com/Kitware/CMake/releases/download/v3.31.8/cmake-3.31.8-linux-x86_64.tar.gz
    tar -C "$ROOT/.build" -xzf /tmp/cmake-3.31.8-linux-x86_64.tar.gz
    mv "$ROOT/.build/cmake-3.31.8-linux-x86_64" "$ROOT/.build/cmake"
fi

clone_tag() {
    local url="$1" dir="$2" tag="$3"
    if [[ ! -d "$dir/.git" ]]; then
        git clone --depth 1 --branch "$tag" "$url" "$dir"
    fi
}

clone_rev() {
    local url="$1" dir="$2" rev="$3"
    if [[ ! -d "$dir/.git" ]]; then
        git clone --filter=blob:none "$url" "$dir"
    fi
    git -C "$dir" fetch --depth 1 origin "$rev"
    git -C "$dir" checkout --detach --force FETCH_HEAD
    git -C "$dir" clean -fdq
}

apply_patch() {
    local dir="$1" patch="$2"
    patch -d "$dir" -p1 --forward < "$patch"
}

meson_install() {
    local dir="$1"
    shift
    rm -rf "$dir/build"
    meson setup "$dir/build" "$dir" --prefix "$PREFIX" "$@"
    meson compile -C "$dir/build" -j "$JOBS"
    meson install -C "$dir/build"
}

cmake_install() {
    local dir="$1"
    local bdir="$2"
    shift 2
    rm -rf "$bdir"
    "$CMAKE" -S "$dir" -B "$bdir" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$PREFIX" \
        -DCMAKE_PREFIX_PATH="$PREFIX" \
        -DCMAKE_LIBRARY_PATH="$PREFIX/lib/x86_64-linux-gnu;$PREFIX/lib" \
        -DCMAKE_INSTALL_RPATH="$PREFIX/lib;$PREFIX/lib/x86_64-linux-gnu" \
        -DCMAKE_BUILD_RPATH="$PREFIX/lib;$PREFIX/lib/x86_64-linux-gnu" \
        -DCMAKE_C_COMPILER="$CC" \
        -DCMAKE_CXX_COMPILER="$CXX" \
        "$@"
    "$CMAKE" --build "$bdir" -j "$JOBS"
    "$CMAKE" --install "$bdir"
}

if ! meson --version | awk -F. '{ exit !($1 > 1 || ($1 == 1 && $2 >= 4)) }'; then
    python3 -m pip install --user 'meson>=1.7' >/dev/null
    export PATH="$HOME/.local/bin:$PATH"
fi

echo "prefix $PREFIX"
echo "cc $($CC --version | head -1)"
echo "cmake $($CMAKE --version | head -1)"
echo "meson $(meson --version)"

if ! pkg-config --atleast-version=1.23 wayland-server; then
    clone_tag https://gitlab.freedesktop.org/wayland/wayland.git "$SRC/wayland" 1.24.0
    meson_install "$SRC/wayland" -Ddocumentation=false -Dtests=false
fi

if ! pkg-config --atleast-version=1.49 wayland-protocols; then
    clone_tag https://gitlab.freedesktop.org/wayland/wayland-protocols.git "$SRC/wayland-protocols" 1.49
    meson_install "$SRC/wayland-protocols" -Dtests=false
fi

if ! pkg-config --atleast-version=1.11 xkbcommon; then
    clone_tag https://github.com/xkbcommon/libxkbcommon.git "$SRC/libxkbcommon" xkbcommon-1.13.2
    meson_install "$SRC/libxkbcommon" -Denable-docs=false -Denable-x11=false
fi

if ! pkg-config --atleast-version=1.29 libinput; then
    clone_tag https://gitlab.freedesktop.org/libinput/libinput.git "$SRC/libinput" 1.31.3
    meson_install "$SRC/libinput" -Ddocumentation=false -Dtests=false -Dlibwacom=false -Ddebug-gui=false
fi

if ! pkg-config --exists 'lua >= 5.5 lua < 5.6'; then
    if [[ ! -d "$SRC/lua-5.5.0" ]]; then
        wget -q -O /tmp/lua-5.5.0.tar.gz https://www.lua.org/ftp/lua-5.5.0.tar.gz
        tar -C "$SRC" -xzf /tmp/lua-5.5.0.tar.gz
    fi
    make -C "$SRC/lua-5.5.0" -j "$JOBS" linux
    make -C "$SRC/lua-5.5.0" INSTALL_TOP="$PREFIX" install
    if ! pkg-config --exists 'lua >= 5.5'; then
        mkdir -p "$PREFIX/lib/pkgconfig"
        cat > "$PREFIX/lib/pkgconfig/lua.pc" << EOF
prefix=$PREFIX
exec_prefix=\${prefix}
libdir=\${prefix}/lib
includedir=\${prefix}/include
Name: Lua
Description: Lua language engine
Version: 5.5.0
Libs: -L\${libdir} -llua -lm
Cflags: -I\${includedir}
EOF
    fi
fi

clone_rev https://github.com/hyprwm/hyprutils.git "$SRC/hyprutils" "$HYPRUTILS_REV"
cmake_install "$SRC/hyprutils" "$BUILD/hyprutils"

clone_rev https://github.com/hyprwm/hyprwayland-scanner.git "$SRC/hyprwayland-scanner" "$HYPRSCANNER_REV"
cmake_install "$SRC/hyprwayland-scanner" "$BUILD/hyprwayland-scanner"

clone_rev https://github.com/hyprwm/hyprlang.git "$SRC/hyprlang" "$HYPRLANG_REV"
cmake_install "$SRC/hyprlang" "$BUILD/hyprlang"

clone_rev https://github.com/hyprwm/hyprcursor.git "$SRC/hyprcursor" "$HYPRCURSOR_REV"
cmake_install "$SRC/hyprcursor" "$BUILD/hyprcursor"

clone_rev https://github.com/hyprwm/hyprgraphics.git "$SRC/hyprgraphics" "$HYPRGRAPHICS_REV"
cmake_install "$SRC/hyprgraphics" "$BUILD/hyprgraphics"

clone_rev https://github.com/hyprwm/hyprland-protocols.git "$SRC/hyprland-protocols" "$HYPRPROTO_REV"
cmake_install "$SRC/hyprland-protocols" "$BUILD/hyprland-protocols"

clone_rev https://github.com/hyprwm/hyprwire.git "$SRC/hyprwire" "$HYPRWIRE_REV"
cmake_install "$SRC/hyprwire" "$BUILD/hyprwire"

if ! pkg-config --atleast-version=0.2.0 libdisplay-info; then
    clone_tag https://gitlab.freedesktop.org/emersion/libdisplay-info.git "$SRC/libdisplay-info" 0.2.0
    meson_install "$SRC/libdisplay-info"
fi

clone_rev https://github.com/hyprwm/aquamarine.git "$SRC/aquamarine" "$AQUAMARINE_REV"
apply_patch "$SRC/aquamarine" "$ROOT/patches/aquamarine/0001-shm-allocator-for-headless.patch"
cmake_install "$SRC/aquamarine" "$BUILD/aquamarine"

clone_rev https://github.com/hyprwm/Hyprland.git "$SRC/Hyprland" "$HYPRLAND_REV"
apply_patch "$SRC/Hyprland" "$ROOT/patches/hyprland/0001-surfaceless-shm-headless.patch"
git -C "$SRC/Hyprland" submodule update --init --depth 1 -- subprojects/udis86
cmake_install "$SRC/Hyprland" "$BUILD/Hyprland" -DNO_XWAYLAND=ON -DGIT_COMMIT_HASH="$HYPRLAND_REV"

if [[ ! -d "$SRC/grim/.git" ]]; then
    git clone --depth 1 --branch 1.5.0 https://gitlab.freedesktop.org/emersion/grim.git "$SRC/grim" \
        || git clone --depth 1 https://gitlab.freedesktop.org/emersion/grim.git "$SRC/grim"
fi
meson_install "$SRC/grim" -Djpeg=enabled

"$ROOT/scripts/build-client.sh"

echo "built $PREFIX/bin/Hyprland"
"$PREFIX/bin/Hyprland" --version || true
pkg-config --modversion aquamarine hyprlang hyprutils wayland-server wayland-protocols xkbcommon libinput lua
