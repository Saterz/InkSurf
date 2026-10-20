#!/usr/bin/env bash
# NetSurf (framebuffer) keresztfordítása Kindle-re.
# Feltétel: a koxtoolchain fordító a PATH-on (arm-kindle*-linux-gnueabi*-gcc).
# A TARGET változót a workflow állítja be (pl. kindlehf).
set -euo pipefail

TARGET_TUPLE="${TARGET_TUPLE:?Add meg a TARGET_TUPLE-t, pl. arm-kindlehf-linux-gnueabihf}"
JOBS="${JOBS:-$(nproc)}"
ROOT="$(pwd)"
PREFIX="$ROOT/ns-prefix"          # ide települnek a libek (target)
HOSTPREFIX="$ROOT/ns-host"        # ide a build-gépen futó eszközök (nsgenbind, buildsystem)
SRC="$ROOT/ns-src"
OUT="$ROOT/out"
export CROSS="${TARGET_TUPLE}-"

mkdir -p "$PREFIX" "$HOSTPREFIX" "$SRC" "$OUT"

BASE="https://source.netsurf-browser.org"
# sorrend FONTOS: a buildsystem és a core libek elöl
TARGET_LIBS="libwapcaplet libparserutils libhubbub libdom libcss libnsbmp libnsgif libnsutils libnspsl libutf8proc libnsfb"

clone() {
  local repo="$1"
  if [ ! -d "$SRC/$repo" ]; then
    git clone --depth 1 "$BASE/$repo.git" "$SRC/$repo"
  fi
}

echo "==> források letöltése"
for r in buildsystem nsgenbind $TARGET_LIBS netsurf; do clone "$r"; done

# 1) buildsystem – kell a host- és a target-oldalhoz is
echo "==> buildsystem (host)"
make -C "$SRC/buildsystem" PREFIX="$HOSTPREFIX" install
echo "==> buildsystem (target prefix)"
make -C "$SRC/buildsystem" PREFIX="$PREFIX" install

HOST_NSSHARED="$HOSTPREFIX/share/netsurf-buildsystem"
TGT_NSSHARED="$PREFIX/share/netsurf-buildsystem"

# 2) nsgenbind – a build GÉPEN fut (JS-kötések generálása), natív fordító
echo "==> nsgenbind (host, natív)"
make -C "$SRC/nsgenbind" \
  PREFIX="$HOSTPREFIX" NSSHARED="$HOST_NSSHARED" install

# target fordítóflagek: a saját prefixünk include/lib útvonalai
export CFLAGS="-I$PREFIX/include -O2"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

# minden target-lib ugyanazzal a kereszt-fordítóval
tmake() {
  local dir="$1"; shift
  make -C "$SRC/$dir" -j"$JOBS" \
    CC="${CROSS}gcc" AR="${CROSS}ar" \
    PREFIX="$PREFIX" NSSHARED="$TGT_NSSHARED" \
    COMPONENT_TYPE=lib-static "$@"
}

echo "==> target libek fordítása"
for lib in $TARGET_LIBS; do
  echo "   -- $lib"
  tmake "$lib"
  tmake "$lib" install
done

# 3) NetSurf, framebuffer frontend, linux felület (/dev/fb + /dev/input), JS (duktape)
echo "==> netsurf (framebuffer)"
make -C "$SRC/netsurf" -j"$JOBS" \
  CC="${CROSS}gcc" AR="${CROSS}ar" HOST="$TARGET_TUPLE" \
  PREFIX="$PREFIX" NSSHARED="$TGT_NSSHARED" \
  NSGENBIND="$HOSTPREFIX/bin/nsgenbind" \
  TARGET=framebuffer \
  NETSURF_FB_FRONTEND=linux \
  NETSURF_FB_FONTLIB=internal \
  NETSURF_USE_DUKTAPE=YES \
  NETSURF_USE_JPEG=NO NETSURF_USE_PNG=NO NETSURF_USE_WEBP=NO \
  NETSURF_USE_ROSPRITE=NO NETSURF_USE_NSSVG=NO NETSURF_USE_VIDEO=NO \
  NETSURF_USE_HARU_PDF=NO NETSURF_USE_CURL=YES NETSURF_USE_OPENSSL=YES

echo "==> kimenet összeállítása"
# a lefordított bináris neve általában nsfb
BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'nsfb' -type f | head -n1 || true)"
[ -n "$BIN" ] || BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'netsurf' -type f -perm -u+x | head -n1 || true)"
[ -n "$BIN" ] || { echo "HIBA: nem találom a lefordított binárist"; exit 1; }

cp "$BIN" "$OUT/netsurf"
# erőforrások (betűk, ikonok, about: oldalak)
if [ -d "$SRC/netsurf/frontends/framebuffer/res" ]; then
  cp -r "$SRC/netsurf/frontends/framebuffer/res" "$OUT/res"
elif [ -d "$SRC/netsurf/resources" ]; then
  cp -r "$SRC/netsurf/resources" "$OUT/res"
fi
"${CROSS}strip" "$OUT/netsurf" 2>/dev/null || true
file "$OUT/netsurf" || true
echo "==> KÉSZ: $OUT/netsurf"
