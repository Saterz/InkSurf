#!/usr/bin/env bash
# NetSurf (framebuffer) keresztfordítása Kindle-re a hivatalos "netsurf-all" forrásból.
# Feltétel: a koxtoolchain fordító a PATH-on, a tuple a TARGET_TUPLE-ben.
set -euo pipefail

TARGET_TUPLE="${TARGET_TUPLE:?Add meg a TARGET_TUPLE-t, pl. arm-kindlehf-linux-gnueabihf}"
JOBS="${JOBS:-$(nproc)}"
VER="${NS_VERSION:-3.11}"
ROOT="$(pwd)"
PREFIX="$ROOT/ns-prefix"     # target libek ide
HOSTPREFIX="$ROOT/ns-host"   # build-gépen futó eszközök (nsgenbind, buildsystem)
OUT="$ROOT/out"
export CROSS="${TARGET_TUPLE}-"

mkdir -p "$PREFIX" "$HOSTPREFIX" "$OUT"

TARBALL="netsurf-all-${VER}.tar.gz"
URL="https://download.netsurf-browser.org/netsurf/releases/source-full/${TARBALL}"

echo "==> forrás letöltése: $URL"
ok=0
for i in 1 2 3 4 5; do
  if curl -fSL --retry 3 -o "$TARBALL" "$URL"; then ok=1; break; fi
  echo "letöltés #$i sikertelen, újra 15 mp múlva..."; sleep 15
done
[ "$ok" = "1" ] || { echo "HIBA: nem sikerült letölteni a forrást"; exit 1; }

echo "==> kicsomagolás"
tar xzf "$TARBALL"
SRC="$ROOT/netsurf-all-${VER}"
[ -d "$SRC" ] || { echo "HIBA: nincs $SRC a tarball után"; exit 1; }

# a netsurf-all pontosan ezeket a komponenseket tartalmazza, a git-repókkal azonos szerkezetben
TARGET_LIBS="libwapcaplet libparserutils libhubbub libdom libcss libnsbmp libnsgif libnsutils libnspsl libutf8proc libnsfb"

# 1) buildsystem – kell a host- és a target-oldalhoz is
echo "==> buildsystem"
make -C "$SRC/buildsystem" PREFIX="$HOSTPREFIX" install
make -C "$SRC/buildsystem" PREFIX="$PREFIX" install
HOST_NSSHARED="$HOSTPREFIX/share/netsurf-buildsystem"
TGT_NSSHARED="$PREFIX/share/netsurf-buildsystem"

# 2) nsgenbind – a BUILD gépen fut (JS-kötések), natív fordítóval
echo "==> nsgenbind (host, natív)"
make -C "$SRC/nsgenbind" PREFIX="$HOSTPREFIX" NSSHARED="$HOST_NSSHARED" install

# 2b) expat – a libdom XML-kötéséhez kell, keresztfordítva a prefixünkbe (statikus)
EXPAT_VER="${EXPAT_VER:-2.6.4}"
EXPAT_TAG="R_$(echo "$EXPAT_VER" | tr '.' '_')"
echo "==> expat ${EXPAT_VER} (target, statikus)"
ok=0
for i in 1 2 3; do
  if curl -fSL -o expat.tar.gz \
      "https://github.com/libexpat/libexpat/releases/download/${EXPAT_TAG}/expat-${EXPAT_VER}.tar.gz"; then ok=1; break; fi
  echo "expat letöltés #$i sikertelen, újra 10 mp..."; sleep 10
done
[ "$ok" = "1" ] || { echo "HIBA: expat letöltése nem sikerült"; exit 1; }
tar xzf expat.tar.gz
( cd "expat-${EXPAT_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
      --enable-static --disable-shared \
      --without-docbook --without-examples --without-tests \
      CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" && \
  make -j"$JOBS" && make install )

# A régi NetSurf-forrás sok figyelmeztetést vált ki, az új GCC viszont -Werror-ral
# hibává teszi őket. Egy fordító-becsomagolóval a sor VÉGÉRE tesszük a -Wno-error-t
# (az nyer minden korábbi -Werror felett), így a figyelmeztetések nem végzetesek.
REALGCC="$(command -v "${CROSS}gcc")"
WRAP="$ROOT/ccwrap"
mkdir -p "$WRAP"
printf '#!/bin/sh\nexec "%s" "$@" -Wno-error\n' "$REALGCC" > "$WRAP/${CROSS}gcc"
chmod +x "$WRAP/${CROSS}gcc"
export PATH="$WRAP:$PATH"

export CFLAGS="-I$PREFIX/include -O2"
export LDFLAGS="-L$PREFIX/lib"
export PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig"

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

# 2c) Hálózati réteg: zlib + openssl + libcurl (statikusan, a prefixünkbe)
fetch() {
  local out="$1" url="$2"
  for i in 1 2 3 4; do
    curl -fSL --retry 3 --retry-delay 5 -o "$out" "$url" && return 0
    echo "letöltés újra ($i): $url"; sleep 10
  done
  echo "HIBA: nem sikerült letölteni: $url"; exit 1
}

echo "==> zlib (target)"
ZLIB_VER=1.3.1
fetch zlib.tar.gz "https://github.com/madler/zlib/releases/download/v${ZLIB_VER}/zlib-${ZLIB_VER}.tar.gz"
tar xzf zlib.tar.gz
( cd "zlib-${ZLIB_VER}" && \
  CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
    ./configure --prefix="$PREFIX" --static && \
  make -j"$JOBS" && make install )

echo "==> openssl (target)"
OSSL_VER=3.0.15
fetch openssl.tar.gz "https://github.com/openssl/openssl/releases/download/openssl-${OSSL_VER}/openssl-${OSSL_VER}.tar.gz"
tar xzf openssl.tar.gz
( cd "openssl-${OSSL_VER}" && \
  CROSS_COMPILE="${CROSS}" ./Configure linux-armv4 \
    --prefix="$PREFIX" --openssldir="$PREFIX/ssl" \
    no-shared no-tests no-asm zlib \
    --with-zlib-include="$PREFIX/include" --with-zlib-lib="$PREFIX/lib" && \
  make -j"$JOBS" && make install_sw )

echo "==> libcurl (target)"
CURL_VER=8.11.0
CURL_TAG="curl-$(echo "$CURL_VER" | tr '.' '_')"
fetch curl.tar.gz "https://github.com/curl/curl/releases/download/${CURL_TAG}/curl-${CURL_VER}.tar.gz"
tar xzf curl.tar.gz
( cd "curl-${CURL_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --disable-shared --enable-static \
    --with-openssl="$PREFIX" --with-zlib="$PREFIX" \
    --without-libpsl --without-libidn2 --without-brotli --without-zstd \
    --without-nghttp2 --without-ngtcp2 --disable-ldap --disable-ldaps \
    --disable-manual --disable-docs \
    CC="${CROSS}gcc" AR="${CROSS}ar" RANLIB="${CROSS}ranlib" \
    PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" && \
  make -j"$JOBS" && make install )

# a statikus linkeléshez a libcurl.pc-be beleírjuk a privát függőségeket is,
# hogy a NetSurf linkelésénél meglegyen az -lssl -lcrypto -lz
if [ -f "$PREFIX/lib/pkgconfig/libcurl.pc" ]; then
  sed -i 's/^Libs:.*/& -lssl -lcrypto -lz/' "$PREFIX/lib/pkgconfig/libcurl.pc"
fi

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
BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'nsfb' -type f | head -n1 || true)"
[ -n "$BIN" ] || BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'netsurf' -type f -perm -u+x | head -n1 || true)"
[ -n "$BIN" ] || { echo "HIBA: nem találom a lefordított binárist"; exit 1; }

cp "$BIN" "$OUT/netsurf"
if [ -d "$SRC/netsurf/frontends/framebuffer/res" ]; then
  cp -r "$SRC/netsurf/frontends/framebuffer/res" "$OUT/res"
elif [ -d "$SRC/netsurf/resources" ]; then
  cp -r "$SRC/netsurf/resources" "$OUT/res"
fi
"${CROSS}strip" "$OUT/netsurf" 2>/dev/null || true
file "$OUT/netsurf" || true
echo "==> KÉSZ: $OUT/netsurf"
