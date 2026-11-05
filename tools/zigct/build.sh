#!/bin/sh
# Builds zigct, the Zig compiler with the comptime debugger built in (see README.md).
#
#   tools/zigct/build.sh            -> ~/.cache/zigui-ide/zigct/0.17.0/bin/zigct
#
# It downloads the official source tarball (checked against its published sha256), applies the
# patches in patches/0.17.0 and builds with the `zig` on PATH, which must be exactly 0.17.0.
# No LLVM is needed in the result and the repository vendors no compiler source.
# Environment: ZIGCT_HOME (default ~/.cache/zigui-ide/zigct), ZIGCT_OPTIMIZE (default Debug: about a minute; ReleaseSafe runs about twice as fast but builds for ~17 minutes).
set -eu

VER=0.17.0
SHA256=b6c7f1728f043700d6529bac980800792f824256a9d2f1839b3d62beed0b8abd
URL="https://ziglang.org/download/$VER/zig-$VER.tar.xz"
HOME_DIR="${ZIGCT_HOME:-$HOME/.cache/zigui-ide/zigct}"
OPT="${ZIGCT_OPTIMIZE:-Debug}"
HERE=$(cd "$(dirname "$0")" && pwd)

if [ "$(zig version)" != "$VER" ]; then
    echo "zigct $VER needs the zig on PATH to be $VER (found $(zig version))" >&2
    exit 1
fi

mkdir -p "$HOME_DIR"
TARBALL="$HOME_DIR/zig-$VER.tar.xz"
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

if [ ! -f "$TARBALL" ] || [ "$(sum "$TARBALL")" != "$SHA256" ]; then
    echo "downloading $URL"
    curl -fsSL -o "$TARBALL.part" "$URL"
    mv "$TARBALL.part" "$TARBALL"
fi
if [ "$(sum "$TARBALL")" != "$SHA256" ]; then
    echo "checksum mismatch for $TARBALL" >&2
    rm -f "$TARBALL"
    exit 1
fi

SRC="$HOME_DIR/build-$VER"
rm -rf "$SRC"
mkdir -p "$SRC"
tar -xf "$TARBALL" -C "$SRC"
cd "$SRC/zig-$VER"
for p in "$HERE"/patches/$VER/*.patch; do
    echo "applying $(basename "$p")"
    patch -p1 -s < "$p"
done

# The standard library of the tarball is used (it carries one patched file).
ZIG_LIB_DIR="$PWD/lib" zig build -p "$HOME_DIR/$VER.new" -Dno-lib -Dno-langref \
    -Dversion-string="$VER" -Doptimize="$OPT"
mkdir -p "$HOME_DIR/$VER/bin"
cp "$HOME_DIR/$VER.new/bin/zig" "$HOME_DIR/$VER/bin/zigct"
rm -rf "$HOME_DIR/$VER.new"
echo "built $HOME_DIR/$VER/bin/zigct"
