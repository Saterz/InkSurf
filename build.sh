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
# a netsurf Makefile bare néven hívja a nsgenbind-ot -> legyen a PATH-on
export PATH="$HOSTPREFIX/bin:$PATH"

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
  if [ "$lib" = "libnsfb" ]; then
    # a libnsfb rajzoló-forrásainak becsomagolása, hogy pontosan meg tudjuk írni
    # a Kindle framebuffer felületet (ram.c mint minta + a felület-API fejlécek)
    mkdir -p "$OUT/libnsfb-src"
    cp -r "$SRC/$lib/src/surface" "$OUT/libnsfb-src/surface" 2>/dev/null || true
    cp -r "$SRC/$lib/include"     "$OUT/libnsfb-src/include" 2>/dev/null || true
    cp    "$SRC/$lib/Makefile"    "$OUT/libnsfb-src/Makefile" 2>/dev/null || true
    echo "   >>> libnsfb forrás becsomagolva az artifactba (libnsfb-src)"
    tmake "$lib"
    tmake "$lib" install
  else
    tmake "$lib"
    tmake "$lib" install
  fi
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
    no-shared no-module no-legacy no-tests no-asm no-dso && \
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

# 2d) MIME-típus javítás: a framebuffer fetch_filetype rossz típust ad a .css-re,
# ezért a stíluslapok "UnacceptableType"-pal elbuknak. Lecseréljük a függvényt egy
# saját, kiterjesztés-alapú változatra (nem függ külső fájltól).
echo "==> fetch_filetype lecserélése a forrásban"
cat > "$ROOT/patcher.py" <<'PY'
import re, sys
p = sys.argv[1]
s = open(p).read()
def ensure_inc(s, inc):
    if ("#include " + inc) in s: return s
    m = re.search(r'^#include[^\n]*\n', s, re.M)
    return (s[:m.end()] + "#include " + inc + "\n" + s[m.end():]) if m else ("#include " + inc + "\n" + s)
for inc in ("<string.h>", "<strings.h>"):
    s = ensure_inc(s, inc)
lines = s.split('\n')
defidx = None
for i, l in enumerate(lines):
    if ('fetch_filetype' in l and '(' in l and ';' not in l
            and 'NSLOG' not in l and 'LOG(' not in l and 'define' not in l):
        defidx = i; break
if defidx is None:
    sys.stderr.write("PATCH-HIBA: fetch_filetype definíció nem található\n"); sys.exit(2)
startline = defidx; k = defidx - 1
while k >= 0:
    prev = lines[k].strip()
    if prev == "": k -= 1; continue
    if (prev.endswith('*') or prev in ('const char *','static const char *','char *')) \
            and ';' not in prev and '{' not in prev and '}' not in prev:
        startline = k; k -= 1; continue
    break
start = sum(len(lines[i]) + 1 for i in range(startline))
rest_off = sum(len(lines[i]) + 1 for i in range(defidx))
b = s.index('{', rest_off); depth = 0; j = b
while j < len(s):
    if s[j] == '{': depth += 1
    elif s[j] == '}':
        depth -= 1
        if depth == 0: break
    j += 1
end = j + 1
sys.stderr.write("EREDETI fetch_filetype:\n" + s[start:end] + "\n--- vége ---\n")
newfn = (
'const char *fetch_filetype(const char *unix_path)\n'
'{\n'
'\tstatic const struct { const char *ext; const char *type; } nsmap[] = {\n'
'\t\t{".css","text/css"},{".html","text/html"},{".htm","text/html"},\n'
'\t\t{".js","text/javascript"},{".json","application/json"},\n'
'\t\t{".png","image/png"},{".gif","image/gif"},{".jpg","image/jpeg"},\n'
'\t\t{".jpeg","image/jpeg"},{".svg","image/svg+xml"},{".bmp","image/bmp"},\n'
'\t\t{".txt","text/plain"},{".xml","text/xml"},{0,0}\n'
'\t};\n'
'\tsize_t nl = strlen(unix_path); int ni;\n'
'\tfor (ni = 0; nsmap[ni].ext; ni++) {\n'
'\t\tsize_t el = strlen(nsmap[ni].ext);\n'
'\t\tif (nl >= el && strcasecmp(unix_path + nl - el, nsmap[ni].ext) == 0)\n'
'\t\t\treturn nsmap[ni].type;\n'
'\t}\n'
'\treturn "text/plain";\n'
'}'
)
open(p, 'w').write(s[:start] + newfn + s[end:])
sys.stderr.write("fetch_filetype LECSERÉLVE.\n")
PY
python3 "$ROOT/patcher.py" "$SRC/netsurf/frontends/framebuffer/fetch.c"
grep -q "nsmap" "$SRC/netsurf/frontends/framebuffer/fetch.c" \
  || { echo "HIBA: a fetch_filetype csere nem sikerült"; exit 1; }

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

# 4) FBInk – a Kindle e-ink frissítéséhez (MTK EPDC). Ezzel rajzolás után kényszerítjük
#    a kijelzőt, hogy megjelenjen, amit a NetSurf a framebufferbe írt.
echo "==> FBInk (Kindle e-ink)"
if [ ! -d "$ROOT/FBInk" ]; then
  git clone --depth 1 --recursive https://github.com/NiLuJe/FBInk.git "$ROOT/FBInk" || true
fi
if [ -d "$ROOT/FBInk" ]; then
  ( cd "$ROOT/FBInk" && \
    export CROSS_TC="$TARGET_TUPLE" && \
    export PATH="$(dirname "$REALGCC"):$PATH" && \
    make clean >/dev/null 2>&1 || true; \
    make kindle -j"$JOBS" ) && \
  FBINK_BIN="$(find "$ROOT/FBInk" -name fbink -type f -perm -u+x | head -n1 || true)" && \
  [ -n "$FBINK_BIN" ] && cp "$FBINK_BIN" "$OUT/fbink" && "${CROSS}strip" "$OUT/fbink" 2>/dev/null || true
fi
[ -f "$OUT/fbink" ] && echo "   fbink kész: $(file "$OUT/fbink" | cut -c1-50)" || echo "   FIGYELEM: fbink nem épült meg (a NetSurf attól még kész)"

echo "==> kimenet összeállítása"
BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'nsfb' -type f | head -n1 || true)"
[ -n "$BIN" ] || BIN="$(find "$SRC/netsurf" -maxdepth 2 -name 'netsurf' -type f -perm -u+x | head -n1 || true)"
[ -n "$BIN" ] || { echo "HIBA: nem találom a lefordított binárist"; exit 1; }

cp "$BIN" "$OUT/netsurf"
# FONTOS: -L, hogy a framebuffer res szimbolikus linkjei (default.css, quirks.css,
# internal.css, welcome.html stb. -> közös resources) VALÓDI fájlként másolódjanak.
rm -rf "$OUT/res"
if [ -d "$SRC/netsurf/frontends/framebuffer/res" ]; then
  cp -rL "$SRC/netsurf/frontends/framebuffer/res" "$OUT/res"
elif [ -d "$SRC/netsurf/resources" ]; then
  cp -rL "$SRC/netsurf/resources" "$OUT/res"
fi
# saját mime.types a res-be (ezt olvassa a fordításkor átírt fetch.c)
cat > "$OUT/res/mime.types" <<'MIME'
text/css			css
text/html			html htm
text/plain			txt text
text/javascript			js
application/json		json
image/png			png
image/jpeg			jpg jpeg jpe
image/gif			gif
image/svg+xml			svg
image/bmp			bmp
application/octet-stream	bin
MIME
echo "==> res tartalom ellenőrzése (kell benne .css, welcome.html, mime.types):"
ls -1 "$OUT/res" | grep -E '\.css$|welcome|mime\.types' || echo "FIGYELEM: hiányzik valami a res-ből!"
"${CROSS}strip" "$OUT/netsurf" 2>/dev/null || true
file "$OUT/netsurf" || true
echo "==> KÉSZ: $OUT/netsurf"
