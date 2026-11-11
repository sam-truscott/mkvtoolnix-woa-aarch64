#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Sam Truscott — see LICENSE
# Cross-compile MKVToolNix for Windows on ARM64 (aarch64-w64-mingw32) from WSL / Linux
# using llvm-mingw. Produces statically linked .exe files (no DLLs to ship).
#
# Usage:   ./build-mkvtoolnix-woa.sh
# Override versions/paths via env, e.g.  MKVTOOLNIX_VERSION=103.0 QT_VERSION=6.10.1 WORK=~/woa ./build-mkvtoolnix-woa.sh
# Re-running skips finished steps (delete $WORK/stamps/<step> to redo one).
#
# Keep WORK on the Linux filesystem (~), not /mnt/c — builds over the 9P bridge are very slow.
#
# NOT TESTED END-TO-END. Steps most likely to need a tweak, in order of likelihood:
#   1. MKVToolNix's Qt 6 detection (it runs qmake6 on a dummy project). If configure says
#      "qmake6 couldn't be run", read config.log around that check.
#   2. Linking the static Qt platform plugin (qwindows) into mkvtoolnix-gui.exe.
#   3. Boost: only the headers are installed. If configure asks for compiled Boost libraries,
#      they'll need building with b2 for this target.
set -euo pipefail

MKVTOOLNIX_VERSION="${MKVTOOLNIX_VERSION:-103.0}"
QT_VERSION="${QT_VERSION:-6.10.1}"
BOOST_VERSION="${BOOST_VERSION:-1.89.0}"
ZLIB_VERSION="${ZLIB_VERSION:-1.3.1}"
OGG_VERSION="${OGG_VERSION:-1.3.5}"
VORBIS_VERSION="${VORBIS_VERSION:-1.3.7}"
FLAC_VERSION="${FLAC_VERSION:-1.4.3}"
CMARK_VERSION="${CMARK_VERSION:-0.31.1}"
GMP_VERSION="${GMP_VERSION:-6.3.0}"
ICONV_VERSION="${ICONV_VERSION:-1.17}"
GETTEXT_VERSION="${GETTEXT_VERSION:-0.22.5}"
WITH_NLS="${WITH_NLS:-1}"          # 0 = skip libiconv/gettext and build without translations

WORK="${WORK:-$HOME/mkvtoolnix-woa}"
JOBS="${JOBS:-$(nproc)}"
HOST=aarch64-w64-mingw32

TOOLCHAIN="$WORK/llvm-mingw"       # cross compiler
HOSTQT="$WORK/qt-host"             # Qt built for Linux: supplies moc/rcc/uic/qmake
PREFIX="$WORK/prefix"              # every Windows ARM64 library lands here
SRC="$WORK/src"
BUILD="$WORK/build"
STAMPS="$WORK/stamps"
SHIM="$WORK/shim"
DIST="$WORK/dist"
TOOLCHAIN_FILE="$WORK/toolchain-$HOST.cmake"
BUILD_TRIPLET="$(cc -dumpmachine 2>/dev/null || echo "$(uname -m)-linux-gnu")"

die()  { echo "ERROR: $*" >&2; exit 1; }
step() {
  local name=$1; shift
  if [ -f "$STAMPS/$name" ]; then echo "== $name: already done"; return; fi
  echo "== $name"
  ( "$@" )
  touch "$STAMPS/$name"
}
fetch() {  # download (cached) and extract into $SRC
  local url=$1 file="$SRC/downloads/${1##*/}"
  mkdir -p "$SRC/downloads"
  if [ ! -f "$file" ]; then
    curl -fL --retry 3 -o "$file.part" "$url"
    mv "$file.part" "$file"
  fi
  tar -xf "$file" -C "$SRC"
}
cmake_target() {  # src-dir build-name [cmake args...]
  local src=$1 name=$2; shift 2
  cmake -G Ninja -S "$src" -B "$BUILD/$name" \
    -DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN_FILE" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF "$@"
  cmake --build "$BUILD/$name" --parallel "$JOBS"
  cmake --install "$BUILD/$name"
}
autotools_target() {  # src-dir build-name [configure args...]
  local src=$1 name=$2; shift 2
  mkdir -p "$BUILD/$name"
  cd "$BUILD/$name"
  "$src/configure" --build="$BUILD_TRIPLET" --host="$HOST" --prefix="$PREFIX" \
    --enable-static --disable-shared "$@"
  make -j"$JOBS"
  make install
}

# ---------------------------------------------------------------- host side
install_host_packages() {
  command -v apt-get >/dev/null || { echo "(not Debian/Ubuntu: install the equivalents yourself)"; return; }
  sudo apt-get update
  sudo apt-get install -y build-essential cmake ninja-build pkg-config curl xz-utils bzip2 \
    python3 perl ruby rake xsltproc docbook-xsl inkscape imagemagick gettext file
}

get_llvm_mingw() {
  local arch url
  arch=$(uname -m)   # aarch64 under WSL on a Windows-on-Arm machine, x86_64 elsewhere
  url=$(curl -fsSL https://api.github.com/repos/mstorsjo/llvm-mingw/releases/latest | python3 -c '
import json, re, sys
arch = sys.argv[1]
for a in json.load(sys.stdin)["assets"]:
    if re.fullmatch(r"llvm-mingw-.*-ucrt-ubuntu-[0-9.]+-" + arch + r"\.tar\.xz", a["name"]):
        print(a["browser_download_url"]); break
' "$arch")
  [ -n "$url" ] || die "no llvm-mingw release asset found for $arch"
  echo "   $url"
  rm -rf "$TOOLCHAIN"; mkdir -p "$TOOLCHAIN"
  curl -fL "$url" | tar -xJ -C "$TOOLCHAIN" --strip-components=1
}

write_toolchain_file() {
  cat > "$TOOLCHAIN_FILE" <<EOF
set(CMAKE_SYSTEM_NAME Windows)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_C_COMPILER   $TOOLCHAIN/bin/$HOST-clang)
set(CMAKE_CXX_COMPILER $TOOLCHAIN/bin/$HOST-clang++)
set(CMAKE_RC_COMPILER  $TOOLCHAIN/bin/$HOST-windres)
set(CMAKE_FIND_ROOT_PATH $PREFIX)
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
EOF
}

make_shims() {
  mkdir -p "$SHIM"
  # pkg-config that only sees the target prefix and always reports static link flags
  cat > "$SHIM/$HOST-pkg-config" <<EOF
#!/bin/sh
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"
unset PKG_CONFIG_PATH
exec pkg-config --static "\$@"
EOF
  # Qt's cross build installs a *target* qmake wrapper in \$PREFIX/bin; expose it as qmake6.
  # (A wrapper script, not a symlink: Qt's wrapper locates target_qt.conf relative to itself.)
  for n in qmake6 "$HOST-qmake6"; do
    printf '#!/bin/sh\nexec "%s/bin/qmake" "$@"\n' "$PREFIX" > "$SHIM/$n"
  done
  # MKVToolNix calls ImageMagick 7's `magick`; Ubuntu ships ImageMagick 6 (`convert`).
  if ! command -v magick >/dev/null && command -v convert >/dev/null; then
    printf '#!/bin/sh\nexec convert "$@"\n' > "$SHIM/magick"
  fi
  chmod +x "$SHIM"/*
}

# ---------------------------------------------------------------- Windows ARM64 libraries
build_zlib() {
  fetch "https://github.com/madler/zlib/releases/download/v$ZLIB_VERSION/zlib-$ZLIB_VERSION.tar.gz"
  cmake_target "$SRC/zlib-$ZLIB_VERSION" zlib -DZLIB_BUILD_EXAMPLES=OFF
  # zlib's CMake names the static lib libzlibstatic.a on Windows; everything else expects -lz
  ln -sf libzlibstatic.a "$PREFIX/lib/libz.a"
  rm -f "$PREFIX/lib/libzlib.dll.a"
}
build_ogg() {
  fetch "https://downloads.xiph.org/releases/ogg/libogg-$OGG_VERSION.tar.xz"
  cmake_target "$SRC/libogg-$OGG_VERSION" ogg -DBUILD_TESTING=OFF -DINSTALL_DOCS=OFF
}
build_vorbis() {
  fetch "https://downloads.xiph.org/releases/vorbis/libvorbis-$VORBIS_VERSION.tar.xz"
  cmake_target "$SRC/libvorbis-$VORBIS_VERSION" vorbis
}
build_flac() {
  fetch "https://downloads.xiph.org/releases/flac/flac-$FLAC_VERSION.tar.xz"
  cmake_target "$SRC/flac-$FLAC_VERSION" flac -DWITH_OGG=ON -DBUILD_CXXLIBS=OFF \
    -DBUILD_PROGRAMS=OFF -DBUILD_EXAMPLES=OFF -DBUILD_TESTING=OFF -DBUILD_DOCS=OFF -DINSTALL_MANPAGES=OFF
}
build_cmark() {
  fetch "https://github.com/commonmark/cmark/archive/refs/tags/$CMARK_VERSION.tar.gz"
  cmake_target "$SRC/cmark-$CMARK_VERSION" cmark -DCMARK_TESTS=OFF -DBUILD_TESTING=OFF
}
# GMP's hand-written aarch64 assembly targets ELF/Mach-O, not Windows COFF, so use the
# portable C code. -std=gnu17 sidesteps GMP 6.3's configure tests breaking under C23.
build_gmp() {
  fetch "https://ftp.gnu.org/gnu/gmp/gmp-$GMP_VERSION.tar.xz"
  CFLAGS="-O2 -std=gnu17" CC_FOR_BUILD=cc \
    autotools_target "$SRC/gmp-$GMP_VERSION" gmp --disable-assembly
}
build_iconv() {
  fetch "https://ftp.gnu.org/gnu/libiconv/libiconv-$ICONV_VERSION.tar.gz"
  autotools_target "$SRC/libiconv-$ICONV_VERSION" libiconv
}
build_gettext() {
  fetch "https://ftp.gnu.org/gnu/gettext/gettext-$GETTEXT_VERSION.tar.xz"
  autotools_target "$SRC/gettext-$GETTEXT_VERSION/gettext-runtime" gettext \
    --disable-libasprintf --disable-java --disable-csharp --with-libiconv-prefix="$PREFIX"
}
install_boost_headers() {
  local dir="boost_${BOOST_VERSION//./_}"
  fetch "https://archives.boost.io/release/$BOOST_VERSION/source/$dir.tar.bz2"
  mkdir -p "$PREFIX/include"
  rm -rf "$PREFIX/include/boost"
  cp -a "$SRC/$dir/boost" "$PREFIX/include/"
}
# Boost.Filesystem is a compiled library (Boost.System has been header-only since 1.69 and
# its stub library was removed in 1.89). b2 is built for Linux, then its gcc toolset is
# pointed at llvm-mingw's gcc-named wrappers — the classic MinGW route through b2.
build_boost_filesystem() {
  local dir="$SRC/boost_${BOOST_VERSION//./_}"
  [ -d "$dir" ] || fetch "https://archives.boost.io/release/$BOOST_VERSION/source/${dir##*/}.tar.bz2"
  mkdir -p "$BUILD"
  cat > "$BUILD/boost-user-config.jam" <<EOF
using gcc : woa : $TOOLCHAIN/bin/$HOST-g++ :
    <archiver>$TOOLCHAIN/bin/$HOST-ar
    <ranlib>$TOOLCHAIN/bin/$HOST-ranlib
    <rc>$TOOLCHAIN/bin/$HOST-windres ;
EOF
  cd "$dir"
  [ -x ./b2 ] || ./bootstrap.sh --with-toolset=gcc
  ./b2 -j"$JOBS" --user-config="$BUILD/boost-user-config.jam" \
    --build-dir="$BUILD/boost" --stagedir="$BUILD/boost-stage" \
    toolset=gcc-woa target-os=windows architecture=arm address-model=64 \
    variant=release link=static runtime-link=static threading=multi \
    --layout=system --with-filesystem stage
  cp "$BUILD"/boost-stage/lib/libboost_*.a "$PREFIX/lib/"
  ls "$PREFIX"/lib/libboost_filesystem*.a >/dev/null || die "libboost_filesystem wasn't produced"
}

# ---------------------------------------------------------------- Qt (host tools, then target)
qt_url() { echo "https://download.qt.io/official_releases/qt/${QT_VERSION%.*}/$QT_VERSION/submodules/$1-everywhere-src-$QT_VERSION.tar.xz"; }

build_qt_host() {
  fetch "$(qt_url qtbase)"
  cmake -G Ninja -S "$SRC/qtbase-everywhere-src-$QT_VERSION" -B "$BUILD/qtbase-host" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$HOSTQT" \
    -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF -DINPUT_opengl=no -DFEATURE_dbus=OFF
  cmake --build "$BUILD/qtbase-host" --parallel "$JOBS"
  cmake --install "$BUILD/qtbase-host"
}
build_qt_target() {
  [ -d "$SRC/qtbase-everywhere-src-$QT_VERSION" ] || fetch "$(qt_url qtbase)"
  cmake_target "$SRC/qtbase-everywhere-src-$QT_VERSION" "qtbase-$HOST" \
    -DQT_HOST_PATH="$HOSTQT" \
    -DQT_QMAKE_TARGET_MKSPEC=win32-clang-g++ \
    -DQT_QMAKE_DEVICE_OPTIONS="CROSS_COMPILE=$HOST-" \
    -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF \
    -DINPUT_opengl=no -DFEATURE_dbus=OFF
  [ -x "$PREFIX/bin/qmake" ] || die "Qt didn't install a target qmake wrapper at $PREFIX/bin/qmake"
}
build_qt_module() {  # module host|target [cmake args...]
  local mod=$1 side=$2 qtcmake; shift 2
  case $side in
    host)   qtcmake="$HOSTQT/bin/qt-cmake" ;;
    target) qtcmake="$PREFIX/bin/qt-cmake" ;;
  esac
  [ -d "$SRC/$mod-everywhere-src-$QT_VERSION" ] || fetch "$(qt_url "$mod")"
  "$qtcmake" -G Ninja -S "$SRC/$mod-everywhere-src-$QT_VERSION" -B "$BUILD/$mod-$side" \
    -DCMAKE_BUILD_TYPE=Release -DQT_BUILD_EXAMPLES=OFF -DQT_BUILD_TESTS=OFF "$@"
  cmake --build "$BUILD/$mod-$side" --parallel "$JOBS"
  cmake --install "$BUILD/$mod-$side"
}
build_qtsvg()               { build_qt_module qtsvg target; }
# Qt Multimedia needs Qt Shader Tools: the host build provides the qsb shader compiler,
# the target build provides the library the module links against.
build_qtshadertools_host()  { build_qt_module qtshadertools host; }
build_qtshadertools()       { build_qt_module qtshadertools target; }
# No FFmpeg is built, so Qt Multimedia uses its native Windows Media Foundation backend.
# Spatial audio (bundled Resonance Audio) isn't used by MKVToolNix, so it's switched off.
# Its wav.h also relies on <istream> arriving transitively, which current libc++ no longer
# does, so add the include anyway in case the feature switch doesn't skip that code.
build_qtmultimedia() {
  local src="$SRC/qtmultimedia-everywhere-src-$QT_VERSION"
  [ -d "$src" ] || fetch "$(qt_url qtmultimedia)"
  local wav="$src/src/3rdparty/resonance-audio/resonance_audio/utils/wav.h"
  if [ -f "$wav" ] && ! grep -q '#include <istream>' "$wav"; then
    sed -i '0,/^#include/s//#include <istream>\n#include/' "$wav"
  fi
  build_qt_module qtmultimedia target -DFEATURE_ffmpeg=OFF -DFEATURE_spatialaudio=OFF
}

# The host Qt's rcc compresses resources with zstd whenever the host Qt has zstd (e.g. because
# libzstd-dev is installed), but the Windows ARM64 Qt is built without zstd and can't read them:
# the GUI then starts with almost no icons. Qt's own build passes --no-zstd in that situation;
# MKVToolNix's rake build calls rcc directly and doesn't, so wrap rcc to always pass it.
wrap_host_rcc() {
  local rcc="$HOSTQT/libexec/rcc"
  [ -e "$rcc.real" ] || { [ -x "$rcc" ] || die "host rcc not found at $rcc"; mv "$rcc" "$rcc.real"; }
  cat > "$rcc" <<EOF
#!/bin/sh
# Installed by build-mkvtoolnix-woa.sh: the target Qt has no zstd support.
exec "$rcc.real" --no-zstd "\$@"
EOF
  chmod +x "$rcc"
  # If MKVToolNix was already built with zstd resources, make rake regenerate them.
  local d
  for d in "$SRC"/mkvtoolnix-*/src; do
    [ -d "$d" ] && find "$d" -name '*.qrc' -exec touch {} +
  done
  return 0
}

# ---------------------------------------------------------------- MKVToolNix
build_mkvtoolnix() {
  local dir="$SRC/mkvtoolnix-$MKVTOOLNIX_VERSION"
  [ -d "$dir" ] || fetch "https://mkvtoolnix.download/sources/mkvtoolnix-$MKVTOOLNIX_VERSION.tar.xz"
  cd "$dir"
  local extra=()
  [ "$WITH_NLS" = 1 ] || extra+=(--disable-nls)
  if [ ! -f build-config ]; then
    # -lbcrypt: Boost.Filesystem on Windows uses BCryptGenRandom, and MinGW has no auto-linking
    CPPFLAGS="-I$PREFIX/include -DFLAC__NO_DLL" LDFLAGS="-L$PREFIX/lib -static" LIBS="-lbcrypt" \
      ./configure --build="$BUILD_TRIPLET" --host="$HOST" --prefix=/ \
        --with-boost="$PREFIX" --with-boost-libdir="$PREFIX/lib" --enable-static-qt "${extra[@]}" \
      || die "configure failed — see $dir/config.log"
  fi
  # The MSIX (Microsoft Store) tile images are only needed for an .msix package, which this
  # build doesn't make, and their generator is a zsh script. Drop the target from the default
  # Windows build rather than requiring zsh.
  if grep -q '^ *targets << "msix-assets"' Rakefile; then
    sed -i '/^ *targets << "msix-assets"/s/^/# skipped by build-mkvtoolnix-woa.sh: /' Rakefile
  fi
  fix_manifests
  rake -j"$JOBS"
}

# MKVToolNix's Windows manifests hard-code processorArchitecture="x86" (for the program and
# for its Common-Controls dependency). On ARM64 Windows that makes the loader look for an x86
# Common-Controls and fail with 0xc000007b. "*" means "any architecture".
# (The MSIX manifest uses a differently-cased ProcessorArchitecture attribute and isn't touched.)
fix_manifests() {
  local files
  files=$(grep -rlE 'processorArchitecture="(x86|amd64)"' \
            --include='*.manifest' --include='*.rc' --include='*.xml' --include='*.in' . 2>/dev/null || true)
  [ -n "$files" ] || return 0
  echo "   patching processorArchitecture in:"; echo "$files" | sed 's/^/     /'
  echo "$files" | xargs sed -i -E 's/processorArchitecture="(x86|amd64)"/processorArchitecture="*"/g'
  # make rake recompile the resource files that embed the manifests, then relink
  find src -name '*.rc' -exec touch {} +
}

# Fail loudly instead of shipping an .exe that won't start: no x86/x64 manifest
# dependencies, and no imports of DLLs from this build (everything must be static).
check_exes() {
  local exe bad=0 dlls
  for exe in "$DIST"/*.exe; do
    if strings "$exe" | grep -qE 'processorArchitecture="(x86|amd64)"'; then
      echo "   $(basename "$exe"): manifest still names x86/amd64"; bad=1
    fi
    dlls=$("$HOST-objdump" -p "$exe" | sed -n 's/.*DLL Name: //p' \
             | grep -iE '^(lib|qt[0-9]|zlib|icu|gmp|ogg|vorbis|flac|cmark|intl|iconv)' || true)
    if [ -n "$dlls" ]; then
      echo "   $(basename "$exe") imports non-system DLLs: $(echo $dlls)"; bad=1
    fi
  done
  [ "$bad" = 0 ] || die "packaged executables failed the checks above"
  echo "   checks passed: ARM64-safe manifests, system DLL imports only"
}

package() {
  local dir="$SRC/mkvtoolnix-$MKVTOOLNIX_VERSION" exe lang
  rm -rf "$DIST"; mkdir -p "$DIST"
  for exe in mkvmerge mkvinfo mkvextract mkvpropedit mkvtoolnix-gui/mkvtoolnix-gui; do
    [ -f "$dir/src/$exe.exe" ] && cp "$dir/src/$exe.exe" "$DIST/"
  done
  # The GUI loads its icons at runtime from an external Qt resource file (Linux installs it as
  # share/mkvtoolnix/qt_resources.rcc), plus its "job finished" sounds. On Windows these live
  # in a data\ folder beside the executables.
  local rcc
  rcc=$(find "$dir" -name qt_resources.rcc -print -quit)
  [ -n "$rcc" ] || die "qt_resources.rcc wasn't built — the GUI would have no icons"
  mkdir -p "$DIST/data"
  cp "$rcc" "$DIST/data/"
  if compgen -G "$dir/share/sounds/*" >/dev/null; then
    mkdir -p "$DIST/data/sounds"
    cp "$dir"/share/sounds/* "$DIST/data/sounds/"
  fi
  for mo in "$dir"/po/*.mo; do
    [ -f "$mo" ] || continue
    lang=$(basename "$mo" .mo)
    mkdir -p "$DIST/locale/$lang/LC_MESSAGES"
    cp "$mo" "$DIST/locale/$lang/LC_MESSAGES/mkvtoolnix.mo"
  done
  echo "== Built:"; ls -l "$DIST"
  file "$DIST"/*.exe || true      # should say "PE32+ executable ... ARM64"
  check_exes
  # WSL interop can launch the Windows ARM64 exe directly as a smoke test
  "$DIST/mkvmerge.exe" --version || echo "(couldn't launch via WSL interop — try it from Windows)"
  echo "Copy to Windows with e.g.:  cp -r '$DIST' /mnt/c/Users/<you>/mkvtoolnix-arm64"
}

main() {
  mkdir -p "$SRC" "$BUILD" "$STAMPS" "$PREFIX"
  step host-packages   install_host_packages
  step llvm-mingw      get_llvm_mingw
  export PATH="$SHIM:$TOOLCHAIN/bin:$PATH"
  write_toolchain_file
  make_shims
  "$HOST-clang" --version | head -1

  step zlib            build_zlib
  step ogg             build_ogg
  step vorbis          build_vorbis
  step flac            build_flac
  step cmark           build_cmark
  step gmp             build_gmp
  if [ "$WITH_NLS" = 1 ]; then
    step libiconv      build_iconv
    step gettext       build_gettext
  fi
  step boost-headers   install_boost_headers
  step boost-filesystem build_boost_filesystem
  step qt-host         build_qt_host
  step qt-target       build_qt_target
  step qtsvg           build_qtsvg
  step qtshadertools-host build_qtshadertools_host
  step qtshadertools   build_qtshadertools
  step qtmultimedia    build_qtmultimedia
  step rcc-no-zstd     wrap_host_rcc

  echo "== mkvtoolnix"
  ( build_mkvtoolnix )
  package
}

main "$@"
