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
    # a paletta-API forrásainak becsomagolása (a szürkepaletta megírásához)
    mkdir -p "$OUT/libnsfb-src"
    cp "$SRC/$lib"/src/*.h "$OUT/libnsfb-src/" 2>/dev/null || true
    cp "$SRC/$lib"/src/palette.c "$SRC/$lib"/src/libnsfb.c "$OUT/libnsfb-src/" 2>/dev/null || true
    # --- Saját Kindle framebuffer felület beillesztése a libnsfb-be ---
    echo "   >>> kindle framebuffer surface hozzáadása"
    cat > "$SRC/$lib/src/surface/kindlefb.c" <<'KFBEOF'
/* Kindle framebuffer surface for libnsfb.
 * A NetSurf 32bpp (ABGR) RAM-pufferbe rajzol; frissítéskor a megváltozott részt
 * luminanciává (8bpp szürke) alakítva másoljuk a valódi /dev/fb0-ba (Y8, hwtcon_v2).
 * Az e-ink frissítést külső fbink intézi. Felület neve: "kindle".
 * Az érintőképernyőt közvetlenül a /dev/input/event* evdev eszközről olvassuk:
 *   - koppintás  -> egérkattintás (MOUSE_1 le/fel az adott ponton)
 *   - függőleges húzás -> görgetés (MOUSE_4/MOUSE_5)
 * Tengely-tájolás környezeti változókkal igazítható újrafordítás nélkül:
 *   NETSURF_TOUCH_DEV, NETSURF_TOUCH_SWAP, NETSURF_TOUCH_INVX, NETSURF_TOUCH_INVY */
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <errno.h>
#include <poll.h>
#include <dirent.h>
#include <sys/mman.h>
#include <sys/ioctl.h>
#include <linux/fb.h>
#include <linux/input.h>
#include <signal.h>

#include "libnsfb.h"
#include "libnsfb_plot.h"
#include "libnsfb_event.h"

#include "nsfb.h"
#include "surface.h"
#include "plot.h"

#define UNUSED(x) ((x) = (x))

#include <stdarg.h>
/* diagnosztikai napló a stderr-re (az indító a netsurf.log-ba irányítja) */
static void ktlog(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fputs("KINDLETOUCH: ", stderr);
    vfprintf(stderr, fmt, ap);
    fputc('\n', stderr);
    fflush(stderr);
    va_end(ap);
}

static int      kfb_fd = -1;
static uint8_t *kfb_mem = NULL;      /* a valódi framebuffer mmap-je (8bpp) */
static size_t   kfb_memlen = 0;
static int      kfb_linelen = 0;     /* a fb sor hossza bájtban */

/* ---- MTK (hwtcon) e-ink frissítés: a rajzolt régiót azonnal kitesszük a kijelzőre ----
 * Forrás: FBInk/eink/mtk-kindle.h (PW5/PW6, hwtcon_v2). A struktúra méretét az _IOW
 * is kódolja, ezért pontosan kell. */
struct mtk_rect { uint32_t top, left, width, height; };
struct mtk_alt_buffer { uint32_t phys_addr, width, height; struct mtk_rect region; };
struct mtk_swipe { uint32_t direction, steps; };
struct mtk_update_data {
    struct mtk_rect        update_region;
    uint32_t               waveform_mode;
    uint32_t               update_mode;
    uint32_t               update_marker;
    int32_t                temp;
    uint32_t               flags;
    int32_t                dither_mode;
    int32_t                quant_bit;
    struct mtk_alt_buffer  alt_buffer_data;
    struct mtk_swipe       swipe_data;
    uint32_t               hist_bw_waveform_mode;
    uint32_t               hist_gray_waveform_mode;
    uint32_t               ts_pxp;
    uint32_t               ts_epdc;
};
#define MTK_WAVEFORM_AUTO   257
#define MTK_WAVEFORM_GC16   2
#define MTK_WAVEFORM_GL16   3
#define MTK_UPDATE_PARTIAL  0
#define MTK_UPDATE_FULL     1
#define MTK_TEMP_AMBIENT    0x1000
#define MXCFB_SEND_UPDATE_MTK _IOW('F', 0x2E, struct mtk_update_data)

static int      mtk_ok = 1;          /* 0: az ioctl nem megy, marad az fbink hurok */
static uint32_t mtk_marker = 0;
static int      mtk_logged = 0;      /* az első ioctl eredményét naplózzuk */

/* ---- minimalizálás (SIGSTOP) / folytatás (SIGCONT) ----
 * A böngésző a háttérben "megfagy" (a KOReader ilyenkor visszakapja a képernyőt és
 * az érintőt). Folytatáskor SIGCONT érkezik; a teljes 32bpp RAM-puffert (nsfb->ptr)
 * újra kiírjuk a kijelzőre, mert a KOReader közben átrajzolta a framebuffert. */
static volatile sig_atomic_t g_resumed = 0;   /* 1: SIGCONT után teljes újrarajzolás kell */
static void on_sigcont(int sig) { (void)sig; g_resumed = 1; }

/* ===================== SAJÁT ESZKÖZTÁR (KOReader-szerű felső sáv) ===================== */
/* DejaVuSansMono 17px, ASCII 32..126, cella 10x18, uint16 soronkent (MSB=bal) */
#define KFB_FONT_CW 10
#define KFB_FONT_CH 18
#define KFB_FONT_FIRST 32
static const unsigned short kfb_font[95][18] = {
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 32 ' ' */
  {0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 33 '!' */
  {0x0000,0x0000,0x0000,0x0048,0x0048,0x0048,0x0048,0x0048,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 34 '"' */
  {0x0000,0x0000,0x0000,0x0000,0x0032,0x0026,0x0024,0x01ff,0x004c,0x004c,0x0048,0x03fe,0x0098,0x0090,0x0190,0x0000,0x0000,0x0000}, /* 35 '#' */
  {0x0000,0x0000,0x0010,0x0010,0x007c,0x00d4,0x0090,0x0090,0x00f0,0x007c,0x001e,0x0016,0x0012,0x0096,0x007c,0x0010,0x0010,0x0010}, /* 36 '$' */
  {0x0000,0x0000,0x0000,0x01e0,0x0320,0x0330,0x0320,0x01e6,0x0018,0x0060,0x018e,0x0013,0x0011,0x0013,0x000e,0x0000,0x0000,0x0000}, /* 37 '%' */
  {0x0000,0x0000,0x0000,0x0078,0x00c0,0x00c0,0x00c0,0x00c0,0x00e0,0x01b1,0x0119,0x030b,0x010e,0x018e,0x00fb,0x0000,0x0000,0x0000}, /* 38 '&' */
  {0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 39 ''' */
  {0x0000,0x0000,0x0008,0x0018,0x0010,0x0030,0x0030,0x0020,0x0020,0x0060,0x0020,0x0020,0x0030,0x0030,0x0010,0x0018,0x0008,0x0000}, /* 40 '(' */
  {0x0000,0x0000,0x0060,0x0020,0x0030,0x0030,0x0010,0x0018,0x0018,0x0018,0x0018,0x0018,0x0010,0x0030,0x0030,0x0020,0x0060,0x0000}, /* 41 ')' */
  {0x0000,0x0000,0x0000,0x0010,0x0010,0x0096,0x0078,0x0078,0x0096,0x0010,0x0010,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 42 '*' */
  {0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0030,0x01ff,0x01ff,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000,0x0000}, /* 43 '+' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0020,0x0060,0x0000}, /* 44 ',' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0078,0x0078,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 45 '-' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 46 '.' */
  {0x0000,0x0000,0x0000,0x0006,0x0004,0x000c,0x0008,0x0018,0x0010,0x0030,0x0030,0x0060,0x0060,0x00c0,0x00c0,0x0180,0x0180,0x0000}, /* 47 '/' */
  {0x0000,0x0000,0x0000,0x0078,0x00cc,0x0086,0x0186,0x0186,0x01b6,0x01b6,0x0186,0x0186,0x0086,0x00cc,0x0078,0x0000,0x0000,0x0000}, /* 48 '0' */
  {0x0000,0x0000,0x0000,0x0078,0x00d8,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x00fe,0x0000,0x0000,0x0000}, /* 49 '1' */
  {0x0000,0x0000,0x0000,0x00f8,0x018c,0x0106,0x0006,0x0006,0x000c,0x0018,0x0038,0x0070,0x0060,0x00c0,0x01fe,0x0000,0x0000,0x0000}, /* 50 '2' */
  {0x0000,0x0000,0x0000,0x0078,0x008c,0x0006,0x0006,0x000c,0x0078,0x000c,0x0006,0x0006,0x0006,0x010c,0x00f8,0x0000,0x0000,0x0000}, /* 51 '3' */
  {0x0000,0x0000,0x0000,0x001c,0x001c,0x003c,0x006c,0x004c,0x00cc,0x018c,0x018c,0x01fe,0x000c,0x000c,0x000c,0x0000,0x0000,0x0000}, /* 52 '4' */
  {0x0000,0x0000,0x0000,0x00fc,0x0080,0x0080,0x0080,0x00f8,0x008c,0x0006,0x0006,0x0006,0x0006,0x010c,0x00f8,0x0000,0x0000,0x0000}, /* 53 '5' */
  {0x0000,0x0000,0x0000,0x003c,0x00c4,0x0080,0x0180,0x01f8,0x01cc,0x0186,0x0186,0x0186,0x0086,0x00c6,0x0078,0x0000,0x0000,0x0000}, /* 54 '6' */
  {0x0000,0x0000,0x0000,0x01fe,0x0006,0x000c,0x000c,0x000c,0x0018,0x0018,0x0030,0x0030,0x0030,0x0060,0x0060,0x0000,0x0000,0x0000}, /* 55 '7' */
  {0x0000,0x0000,0x0000,0x0078,0x00ce,0x0186,0x0186,0x00cc,0x0078,0x00cc,0x0186,0x0186,0x0186,0x00c6,0x0078,0x0000,0x0000,0x0000}, /* 56 '8' */
  {0x0000,0x0000,0x0000,0x0078,0x00cc,0x0186,0x0186,0x0186,0x0186,0x00ce,0x007e,0x0006,0x0004,0x008c,0x0078,0x0000,0x0000,0x0000}, /* 57 '9' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 58 ':' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000,0x0030,0x0030,0x0030,0x0020,0x0060,0x0000}, /* 59 ';' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0003,0x001e,0x0078,0x01c0,0x01c0,0x0078,0x001e,0x0003,0x0000,0x0000,0x0000,0x0000}, /* 60 '<' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01ff,0x01ff,0x0000,0x0000,0x01ff,0x01ff,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 61 '=' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0100,0x01e0,0x0078,0x000e,0x000e,0x0078,0x01e0,0x0100,0x0000,0x0000,0x0000,0x0000}, /* 62 '>' */
  {0x0000,0x0000,0x0000,0x0078,0x008c,0x0006,0x0006,0x000c,0x0018,0x0030,0x0030,0x0030,0x0000,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 63 '?' */
  {0x0000,0x0000,0x0000,0x003c,0x00c6,0x0183,0x011f,0x0133,0x0323,0x0363,0x0361,0x0363,0x0323,0x0133,0x011f,0x0080,0x00e0,0x003c}, /* 64 '@' */
  {0x0000,0x0000,0x0000,0x0030,0x0038,0x0078,0x0068,0x004c,0x00cc,0x00cc,0x00c6,0x01fe,0x0186,0x0183,0x0303,0x0000,0x0000,0x0000}, /* 65 'A' */
  {0x0000,0x0000,0x0000,0x01fc,0x0186,0x0186,0x0186,0x0186,0x01fc,0x0186,0x0186,0x0182,0x0182,0x0186,0x01fc,0x0000,0x0000,0x0000}, /* 66 'B' */
  {0x0000,0x0000,0x0000,0x003c,0x0066,0x00c0,0x0180,0x0180,0x0180,0x0180,0x0180,0x0180,0x00c0,0x0066,0x003c,0x0000,0x0000,0x0000}, /* 67 'C' */
  {0x0000,0x0000,0x0000,0x01f8,0x018c,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x018c,0x01f8,0x0000,0x0000,0x0000}, /* 68 'D' */
  {0x0000,0x0000,0x0000,0x00fe,0x0080,0x0080,0x0080,0x0080,0x00fe,0x0080,0x0080,0x0080,0x0080,0x0080,0x00fe,0x0000,0x0000,0x0000}, /* 69 'E' */
  {0x0000,0x0000,0x0000,0x00fe,0x00c0,0x00c0,0x00c0,0x00c0,0x00fe,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x0000,0x0000,0x0000}, /* 70 'F' */
  {0x0000,0x0000,0x0000,0x007c,0x00c6,0x0080,0x0180,0x0180,0x0180,0x018e,0x0186,0x0186,0x0086,0x00c6,0x007c,0x0000,0x0000,0x0000}, /* 71 'G' */
  {0x0000,0x0000,0x0000,0x0186,0x0186,0x0186,0x0186,0x0186,0x01fe,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0000,0x0000,0x0000}, /* 72 'H' */
  {0x0000,0x0000,0x0000,0x00fe,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x00fe,0x0000,0x0000,0x0000}, /* 73 'I' */
  {0x0000,0x0000,0x0000,0x007c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x000c,0x0198,0x00f0,0x0000,0x0000,0x0000}, /* 74 'J' */
  {0x0000,0x0000,0x0000,0x0183,0x0186,0x018c,0x0198,0x01b0,0x01f0,0x01f0,0x0198,0x018c,0x018c,0x0186,0x0183,0x0000,0x0000,0x0000}, /* 75 'K' */
  {0x0000,0x0000,0x0000,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00c0,0x00ff,0x0000,0x0000,0x0000}, /* 76 'L' */
  {0x0000,0x0000,0x0000,0x0187,0x01c7,0x01cf,0x014b,0x016b,0x013b,0x0133,0x0133,0x0103,0x0103,0x0103,0x0103,0x0000,0x0000,0x0000}, /* 77 'M' */
  {0x0000,0x0000,0x0000,0x01c6,0x01c6,0x01c6,0x01e6,0x01a6,0x01b6,0x0196,0x019e,0x019e,0x018e,0x018e,0x0186,0x0000,0x0000,0x0000}, /* 78 'N' */
  {0x0000,0x0000,0x0000,0x0078,0x00cc,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x00cc,0x0078,0x0000,0x0000,0x0000}, /* 79 'O' */
  {0x0000,0x0000,0x0000,0x00fc,0x0086,0x0086,0x0083,0x0086,0x0086,0x00fc,0x0080,0x0080,0x0080,0x0080,0x0080,0x0000,0x0000,0x0000}, /* 80 'P' */
  {0x0000,0x0000,0x0000,0x0078,0x00cc,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x00cc,0x0078,0x000c,0x0004,0x0000}, /* 81 'Q' */
  {0x0000,0x0000,0x0000,0x01f8,0x018c,0x0186,0x0186,0x0186,0x018c,0x01f8,0x018c,0x0184,0x0186,0x0183,0x0183,0x0000,0x0000,0x0000}, /* 82 'R' */
  {0x0000,0x0000,0x0000,0x0078,0x00c4,0x0180,0x0180,0x0180,0x00f0,0x003c,0x0006,0x0006,0x0106,0x0186,0x00f8,0x0000,0x0000,0x0000}, /* 83 'S' */
  {0x0000,0x0000,0x0000,0x03ff,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 84 'T' */
  {0x0000,0x0000,0x0000,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x0186,0x00ce,0x0078,0x0000,0x0000,0x0000}, /* 85 'U' */
  {0x0000,0x0000,0x0000,0x0103,0x0182,0x0186,0x0186,0x0084,0x00cc,0x00cc,0x004c,0x0068,0x0078,0x0038,0x0030,0x0000,0x0000,0x0000}, /* 86 'V' */
  {0x0000,0x0000,0x0000,0x0303,0x0303,0x0303,0x0333,0x0133,0x013a,0x01fa,0x01ea,0x01ce,0x01ce,0x00ce,0x00c6,0x0000,0x0000,0x0000}, /* 87 'W' */
  {0x0000,0x0000,0x0000,0x0183,0x0086,0x00cc,0x006c,0x0038,0x0030,0x0038,0x0068,0x00cc,0x00c6,0x0186,0x0303,0x0000,0x0000,0x0000}, /* 88 'X' */
  {0x0000,0x0000,0x0000,0x0103,0x0186,0x00c4,0x00cc,0x0078,0x0038,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 89 'Y' */
  {0x0000,0x0000,0x0000,0x01ff,0x0006,0x0006,0x000c,0x0018,0x0018,0x0030,0x0060,0x0060,0x00c0,0x0180,0x01ff,0x0000,0x0000,0x0000}, /* 90 'Z' */
  {0x0000,0x0000,0x0038,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0038,0x0000}, /* 91 '[' */
  {0x0000,0x0000,0x0000,0x0180,0x0180,0x00c0,0x00c0,0x0060,0x0060,0x0030,0x0030,0x0010,0x0018,0x0008,0x000c,0x0004,0x0006,0x0000}, /* 92 '\\' */
  {0x0000,0x0000,0x0070,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0010,0x0070,0x0000}, /* 93 ']' */
  {0x0000,0x0000,0x0000,0x0030,0x0078,0x00cc,0x0086,0x0182,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 94 '^' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 95 '_' */
  {0x0000,0x0040,0x0020,0x0030,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 96 '`' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0078,0x0084,0x0006,0x007e,0x01c6,0x0186,0x0186,0x018e,0x00f6,0x0000,0x0000,0x0000}, /* 97 'a' */
  {0x0000,0x0000,0x0080,0x0080,0x0080,0x0080,0x00bc,0x00c4,0x00c6,0x0086,0x0082,0x0086,0x00c6,0x00c4,0x00bc,0x0000,0x0000,0x0000}, /* 98 'b' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x003c,0x0062,0x00c0,0x0080,0x0080,0x0080,0x00c0,0x0062,0x003c,0x0000,0x0000,0x0000}, /* 99 'c' */
  {0x0000,0x0000,0x0006,0x0006,0x0006,0x0006,0x007e,0x00ce,0x0186,0x0186,0x0186,0x0186,0x0186,0x00ce,0x007e,0x0000,0x0000,0x0000}, /* 100 'd' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0078,0x00c4,0x0186,0x0182,0x01fe,0x0180,0x0180,0x00c2,0x007c,0x0000,0x0000,0x0000}, /* 101 'e' */
  {0x0000,0x0000,0x001e,0x0030,0x0030,0x0030,0x00fe,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0000,0x0000,0x0000}, /* 102 'f' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0076,0x00ce,0x0186,0x0186,0x0186,0x0186,0x0186,0x00ce,0x0076,0x0006,0x0004,0x008c}, /* 103 'g' */
  {0x0000,0x0000,0x0080,0x0080,0x0080,0x0080,0x00bc,0x00cc,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x0000,0x0000,0x0000}, /* 104 'h' */
  {0x0000,0x0000,0x0030,0x0030,0x0000,0x0000,0x00f0,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x01fe,0x0000,0x0000,0x0000}, /* 105 'i' */
  {0x0000,0x0000,0x0018,0x0018,0x0000,0x0000,0x00f8,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0018,0x0010,0x0030}, /* 106 'j' */
  {0x0000,0x0000,0x00c0,0x00c0,0x00c0,0x00c0,0x00c6,0x00cc,0x00d8,0x00f0,0x00f8,0x00d8,0x00cc,0x00c6,0x00c3,0x0000,0x0000,0x0000}, /* 107 'k' */
  {0x0000,0x0000,0x01e0,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0020,0x0030,0x001e,0x0000,0x0000,0x0000}, /* 108 'l' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01ee,0x01b2,0x0132,0x0132,0x0132,0x0132,0x0132,0x0132,0x0132,0x0000,0x0000,0x0000}, /* 109 'm' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00bc,0x00cc,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x0000,0x0000,0x0000}, /* 110 'n' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0078,0x00cc,0x0186,0x0186,0x0186,0x0186,0x0186,0x00cc,0x0078,0x0000,0x0000,0x0000}, /* 111 'o' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00b8,0x00c4,0x00c6,0x0086,0x0082,0x0086,0x00c6,0x00c4,0x00bc,0x0080,0x0080,0x0080}, /* 112 'p' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x007e,0x00ce,0x0186,0x0186,0x0186,0x0186,0x0186,0x00ce,0x007e,0x0006,0x0006,0x0006}, /* 113 'q' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x006e,0x0073,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0060,0x0000,0x0000,0x0000}, /* 114 'r' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0078,0x00c4,0x0080,0x00c0,0x007c,0x000c,0x0006,0x008c,0x0078,0x0000,0x0000,0x0000}, /* 115 's' */
  {0x0000,0x0000,0x0000,0x0060,0x0060,0x0060,0x01fe,0x0060,0x0060,0x0060,0x0060,0x0060,0x0020,0x0030,0x003e,0x0000,0x0000,0x0000}, /* 116 't' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x0086,0x00ce,0x0076,0x0000,0x0000,0x0000}, /* 117 'u' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0182,0x0186,0x0086,0x00cc,0x00cc,0x0048,0x0078,0x0038,0x0030,0x0000,0x0000,0x0000}, /* 118 'v' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0301,0x0303,0x0103,0x0132,0x01b2,0x01be,0x01ce,0x00cc,0x00cc,0x0000,0x0000,0x0000}, /* 119 'w' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0186,0x00cc,0x0068,0x0038,0x0030,0x0078,0x004c,0x00c6,0x0186,0x0000,0x0000,0x0000}, /* 120 'x' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0182,0x0186,0x00c6,0x00c4,0x00cc,0x006c,0x0078,0x0038,0x0030,0x0030,0x0030,0x0060}, /* 121 'y' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x00fe,0x0006,0x000c,0x0018,0x0030,0x0060,0x0060,0x00c0,0x00fe,0x0000,0x0000,0x0000}, /* 122 'z' */
  {0x0000,0x0000,0x001c,0x0010,0x0030,0x0030,0x0030,0x0030,0x0030,0x00e0,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0010,0x001c}, /* 123 '{' */
  {0x0000,0x0000,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030}, /* 124 '|' */
  {0x0000,0x0000,0x00e0,0x0030,0x0030,0x0030,0x0030,0x0030,0x0010,0x001c,0x0018,0x0030,0x0030,0x0030,0x0030,0x0030,0x0030,0x00e0}, /* 125 '}' */
  {0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x01e0,0x01ff,0x011e,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000,0x0000}, /* 126 '~' */
};

#define KFB_TBAR_H 72          /* a saját eszköztár magassága (fizikai) */
#define KFB_GUTTER 14          /* bal margó a tartalomnak (zoomnál is marad) */

static int kfb_scrw = 0, kfb_scrh = 0;   /* FIZIKAI kijelzőméret (sáv+gutter együtt) */

/* a gui.c-vel megosztott állapot (NEM static, hogy a frontend is lássa) */
char g_toolbar_url[1024] = "";
volatile sig_atomic_t g_toolbar_url_dirty = 1;     /* 1: újra kell rajzolni az URL-t */
volatile sig_atomic_t g_nav_request = 0;           /* 1=vissza 2=előre 3=újratölt 4=bezár (a fő ciklus kezeli) */
/* oldalon belüli beviteli mezők -> KOReader billentyűzet (a NetSurf saját OSK ki van kapcsolva) */
volatile sig_atomic_t g_field_click_pending = 0;   /* a user épp mezőbe koppintott (a fő ciklus csökkenti) */
volatile sig_atomic_t g_field_input_request = 0;   /* mező fókuszba került -> KOReader billentyűzet kell */
volatile sig_atomic_t g_inject_request = 0;        /* folytatás után a beírt szöveget injektálni kell a mezőbe */

/* gomb-azonosítók */
enum { TB_NONE=0, TB_BACK, TB_FWD, TB_RELOAD, TB_MIN, TB_CLOSE, TB_URL };

/* ---- érintés (evdev) ---- */
#ifndef ABS_MT_POSITION_X
#define ABS_MT_POSITION_X 0x35
#endif
#ifndef ABS_MT_POSITION_Y
#define ABS_MT_POSITION_Y 0x36
#endif
#ifndef ABS_MT_TRACKING_ID
#define ABS_MT_TRACKING_ID 0x39
#endif

#define BITS_PER_LONG (sizeof(long) * 8)
#define NBITS(x) ((((x) - 1) / BITS_PER_LONG) + 1)
#define TEST_BIT(bit, arr) (((arr)[(bit) / BITS_PER_LONG] >> ((bit) % BITS_PER_LONG)) & 1)

static int   ts_fd = -1;
static int   ts_inited = 0;
static int   ts_min_x = 0, ts_max_x = 0, ts_min_y = 0, ts_max_y = 0;
static int   ts_swap = 0, ts_invx = 0, ts_invy = 0;

/* nyers érintés-állapot az aktuális frame-ben */
static int   raw_x = 0, raw_y = 0;
static int   have_x = 0, have_y = 0;
static int   frame_down = -1;        /* -1: nincs váltás, 0: fel, 1: le */

/* gesztus-állapot */
static int   g_down = 0;
static int   g_start_x = 0, g_start_y = 0;
static int   g_last_x = 0,  g_last_y = 0;
static int   g_moved = 0;
static int   g_scrolling = 0;
static int   g_scroll_accum = 0;
static int   g_scroll_accx = 0;   /* vízszintes görgetés-gyűjtő */
static int   g_min_fired = 0;     /* ebben a gesztusban már kiváltottuk a minimalizálást */

#define TAP_MAX_MOVE 18      /* ennél kisebb elmozdulás: koppintás */
#define SCROLL_STEP  80      /* ennyi képpont húzás = egy görgetőlépés */
#define SCROLL_MAX_PER_FRAME 4
#define TOP_EDGE_PX      70  /* a felső élnek számító sáv magassága */
#define TOP_DRAG_TRIGGER 160 /* ennyit lefelé húzva a felső élről -> minimalizálás */

/* multitouch slotok a PINCH-ZOOMhoz (type B protokoll, ABS_MT_SLOT) */
#ifndef ABS_MT_SLOT
#define ABS_MT_SLOT 0x2f
#endif
#define NSLOTS 2
static int   cur_slot = 0;
static int   sl_active[NSLOTS] = {0, 0};
static int   sl_x[NSLOTS] = {0, 0};
static int   sl_y[NSLOTS] = {0, 0};
static int   pinch_on = 0;
static int   pinch_last = 0;
#define PINCH_STEP 60        /* ennyi nyers távolság-változás = egy zoom-lépés */

/* kis esemény-sor, mert a felület hívásonként egy eseményt adhat vissza */
#define EVQ_SIZE 64
static nsfb_event_t evq[EVQ_SIZE];
static int evq_head = 0, evq_tail = 0;

static void evq_push_key(enum nsfb_event_type_e type, enum nsfb_key_code_e code)
{
    int nt = (evq_tail + 1) % EVQ_SIZE;
    if (nt == evq_head) return;            /* tele: eldobjuk */
    evq[evq_tail].type = type;
    evq[evq_tail].value.keycode = code;
    evq_tail = nt;
}

static void evq_push_move(int x, int y)
{
    int nt = (evq_tail + 1) % EVQ_SIZE;
    if (nt == evq_head) return;
    evq[evq_tail].type = NSFB_EVENT_MOVE_ABSOLUTE;
    evq[evq_tail].value.vector.x = x;
    evq[evq_tail].value.vector.y = y;
    evq[evq_tail].value.vector.z = 0;
    evq_tail = nt;
}

static int evq_pop(nsfb_event_t *out)
{
    if (evq_head == evq_tail) return 0;
    *out = evq[evq_head];
    evq_head = (evq_head + 1) % EVQ_SIZE;
    return 1;
}

static int kindle_defaults(nsfb_t *nsfb)
{
    nsfb->width = 0;
    nsfb->height = 0;
    nsfb->format = NSFB_FMT_ABGR8888;
    select_plotters(nsfb);
    return 0;
}

static int kindle_initialise(nsfb_t *nsfb)
{
    struct fb_var_screeninfo vinfo;
    struct fb_fix_screeninfo finfo;
    const char *dev = getenv("FRAMEBUFFER");
    if (dev == NULL) dev = "/dev/fb0";

    kfb_fd = open(dev, O_RDWR);
    if (kfb_fd == -1) return -1;
    if (ioctl(kfb_fd, FBIOGET_FSCREENINFO, &finfo) == -1) { close(kfb_fd); kfb_fd = -1; return -1; }
    if (ioctl(kfb_fd, FBIOGET_VSCREENINFO, &vinfo) == -1) { close(kfb_fd); kfb_fd = -1; return -1; }

    kfb_memlen = finfo.smem_len;
    kfb_linelen = finfo.line_length;
    kfb_mem = mmap(NULL, kfb_memlen, PROT_READ | PROT_WRITE, MAP_SHARED, kfb_fd, 0);
    if (kfb_mem == MAP_FAILED) { kfb_mem = NULL; close(kfb_fd); kfb_fd = -1; return -1; }

    /* a FIZIKAI kijelzőméret; a NetSurf tartalmi területe ennél kisebb:
     * fent a saját eszköztár (KFB_TBAR_H), balra a gutter (KFB_GUTTER) */
    kfb_scrw = vinfo.xres;
    kfb_scrh = vinfo.yres;
    nsfb->width  = vinfo.xres - KFB_GUTTER;
    nsfb->height = vinfo.yres - KFB_TBAR_H;
    nsfb->format = NSFB_FMT_ABGR8888;
    select_plotters(nsfb);               /* bpp = 32 */
    nsfb->linelen = nsfb->width * 4;
    nsfb->ptr = calloc((size_t)nsfb->width * nsfb->height, 4);
    if (nsfb->ptr == NULL) {
        munmap(kfb_mem, kfb_memlen); kfb_mem = NULL; close(kfb_fd); kfb_fd = -1;
        return -1;
    }

    /* SIGCONT-kezelő: a minimalizálás utáni folytatáskor jelezzük, hogy teljes
     * újrarajzolás kell. SA_RESTART, hogy a megszakított poll/read folytatódjon. */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = on_sigcont;
        sa.sa_flags = SA_RESTART;
        sigemptyset(&sa.sa_mask);
        sigaction(SIGCONT, &sa, NULL);
    }
    return 0;
}

static int kindle_set_geometry(nsfb_t *nsfb, int width, int height, enum nsfb_format_e format)
{
    UNUSED(format);
    if (width > 0)  { kfb_scrw = width;  nsfb->width  = width  - KFB_GUTTER; }
    if (height > 0) { kfb_scrh = height; nsfb->height = height - KFB_TBAR_H; }
    nsfb->format = NSFB_FMT_ABGR8888;    /* mindig 32bpp-t rajzoltatunk */
    select_plotters(nsfb);
    return 0;
}

/* a megrajzolt (32bpp) terület szürkévé alakítása és kiírása a 8bpp framebufferbe */
static int kindle_update(nsfb_t *nsfb, nsfb_bbox_t *box)
{
    int x, y, x0, y0, x1, y1;
    if (kfb_mem == NULL || nsfb->ptr == NULL) return 0;

    x0 = box->x0; y0 = box->y0; x1 = box->x1; y1 = box->y1;
    if (x0 < 0) x0 = 0;
    if (y0 < 0) y0 = 0;
    if (x1 > nsfb->width)  x1 = nsfb->width;
    if (y1 > nsfb->height) y1 = nsfb->height;

    if (x1 <= x0 || y1 <= y0) return 0;

    for (y = y0; y < y1; y++) {
        const uint32_t *src = (const uint32_t *)(nsfb->ptr + (size_t)y * nsfb->linelen);
        uint8_t *dst = kfb_mem + (size_t)(y + KFB_TBAR_H) * kfb_linelen; /* fizikai sor (sáv alatt) */
        if (x0 == 0) { int gi; for (gi = 0; gi < KFB_GUTTER; gi++) dst[gi] = 0xFF; } /* bal gutter fehér */
        for (x = x0; x < x1; x++) {
            uint32_t p = src[x];
            int r =  p        & 0xFF;
            int g = (p >> 8)  & 0xFF;
            int b = (p >> 16) & 0xFF;
            dst[x + KFB_GUTTER] = (uint8_t)((r * 77 + g * 151 + b * 28) >> 8); /* gutterrel eltolva */
        }
    }

    /* a megrajzolt régió azonnali e-ink frissítése (nincs külső pollozó hurok) */
    if (mtk_ok) {
        struct mtk_update_data u;
        int big = ((x1 - x0) * (y1 - y0)) > (nsfb->width * nsfb->height / 2);
        memset(&u, 0, sizeof(u));
        u.update_region.left   = (uint32_t)((x0 == 0) ? 0 : (x0 + KFB_GUTTER));
        u.update_region.top    = (uint32_t)(y0 + KFB_TBAR_H);
        u.update_region.width  = (uint32_t)((x0 == 0) ? ((x1 - x0) + KFB_GUTTER) : (x1 - x0));
        u.update_region.height = (uint32_t)(y1 - y0);
        u.waveform_mode = MTK_WAVEFORM_AUTO;
        /* nagy terület (oldalbetöltés) -> teljes, tiszta frissítés; kicsi -> gyors részleges */
        u.update_mode   = big ? MTK_UPDATE_FULL : MTK_UPDATE_PARTIAL;
        u.update_marker = ++mtk_marker;
        u.temp          = MTK_TEMP_AMBIENT;
        if (ioctl(kfb_fd, MXCFB_SEND_UPDATE_MTK, &u) < 0) {
            if (!mtk_logged) { ktlog("MXCFB_SEND_UPDATE_MTK HIBA (errno=%d) -> marad az fbink hurok", errno); mtk_logged = 1; }
            mtk_ok = 0;   /* nem megy: marad az fbink tartalék */
        } else if (!mtk_logged) {
            ktlog("MXCFB_SEND_UPDATE_MTK OK (refresh-on-draw aktiv)");
            mtk_logged = 1;
        }
    }
    return 0;
}


/* ---------- eszköztár-rajzolás (8bpp: fehér=0xFF, fekete=0x00) ---------- */
static void kfb_mtk_update(int x, int y, int w, int h, int full)
{
    struct mtk_update_data u;
    if (!mtk_ok) return;
    memset(&u, 0, sizeof(u));
    u.update_region.left = (uint32_t)x; u.update_region.top = (uint32_t)y;
    u.update_region.width = (uint32_t)w; u.update_region.height = (uint32_t)h;
    u.waveform_mode = full ? MTK_WAVEFORM_GC16 : MTK_WAVEFORM_AUTO;
    u.update_mode   = full ? MTK_UPDATE_FULL : MTK_UPDATE_PARTIAL;
    u.update_marker = ++mtk_marker; u.temp = MTK_TEMP_AMBIENT;
    if (ioctl(kfb_fd, MXCFB_SEND_UPDATE_MTK, &u) < 0) mtk_ok = 0;
}
static void kfb_px(int x, int y, uint8_t v)
{
    if (x < 0 || y < 0 || x >= kfb_scrw || y >= kfb_scrh) return;
    kfb_mem[(size_t)y * kfb_linelen + x] = v;
}
static void kfb_fill(int x, int y, int w, int h, uint8_t v)
{
    int i, j; for (j = 0; j < h; j++) for (i = 0; i < w; i++) kfb_px(x + i, y + j, v);
}
static void kfb_line(int x0, int y0, int x1, int y1, uint8_t v, int th)
{
    int dx = (x1>x0)?(x1-x0):(x0-x1), dy = (y1>y0)?(y1-y0):(y0-y1);
    int sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1, err = dx - dy, e2, k, l;
    for (;;) {
        for (k = -th/2; k <= th/2; k++) for (l = -th/2; l <= th/2; l++) kfb_px(x0 + k, y0 + l, v);
        if (x0 == x1 && y0 == y1) break;
        e2 = 2 * err; if (e2 > -dy) { err -= dy; x0 += sx; } if (e2 < dx) { err += dx; y0 += sy; }
    }
}
static void kfb_tri_left(int cx, int cy, int s, uint8_t v)   /* ◀ tömör háromszög */
{
    int yy, x; for (yy = -s; yy <= s; yy++) { int ay = yy<0?-yy:yy; for (x = cx - s + ay; x <= cx + s; x++) kfb_px(x, cy + yy, v); }
}
static void kfb_tri_right(int cx, int cy, int s, uint8_t v)  /* ▶ tömör háromszög */
{
    int yy, x; for (yy = -s; yy <= s; yy++) { int ay = yy<0?-yy:yy; for (x = cx - s; x <= cx + s - ay; x++) kfb_px(x, cy + yy, v); }
}
static void kfb_reload(int cx, int cy, int r, uint8_t v)     /* ⟳ gyűrű réssel + nyílhegy, trig nélkül */
{
    int yy, xx, r2 = r*r, rin = (r-3)*(r-3);
    for (yy = -r; yy <= r; yy++) for (xx = -r; xx <= r; xx++) {
        int d = xx*xx + yy*yy;
        if (d <= r2 && d >= rin) { if (!(xx > 0 && yy < 0 && (-yy) < xx)) kfb_px(cx + xx, cy + yy, v); }
    }
    kfb_line(cx + r - 1, cy - 1, cx + r - 9, cy - 4, v, 2);
    kfb_line(cx + r - 1, cy - 1, cx + r - 3, cy + 8, v, 2);
}
static void kfb_btnbox(int cx, int cy, int bw)
{
    int x = cx - bw/2, y = cy - bw/2;
    kfb_fill(x, y, bw, 1, 0xC8); kfb_fill(x, y + bw - 1, bw, 1, 0xC8);
    kfb_fill(x, y, 1, bw, 0xC8); kfb_fill(x + bw - 1, y, 1, bw, 0xC8);
}
static void kfb_text(int x, int y, const char *str, int xmax)
{
    const unsigned char *p = (const unsigned char *)str;
    for (; *p; p++) {
        int c = *p, idx, row;
        if (x + KFB_FONT_CW > xmax) break;
        if (c < KFB_FONT_FIRST || c > 126) c = '?';
        idx = c - KFB_FONT_FIRST;
        for (row = 0; row < KFB_FONT_CH; row++) {
            unsigned short bits = kfb_font[idx][row];
            int col; for (col = 0; col < KFB_FONT_CW; col++) if (bits & (1 << (KFB_FONT_CW - 1 - col))) kfb_px(x + col, y + row, 0x00);
        }
        x += KFB_FONT_CW;
    }
}
/* gomb-geometria (a hittest és a rajzolás ugyanezt használja) */
static int toolbar_hit(int px)
{
    int bw = 56, pad = 14, gap = 10;
    int xback = pad, xfwd = pad + (bw + gap), xrel = pad + 2*(bw + gap);
    int xclose = kfb_scrw - pad - bw, xmin = kfb_scrw - pad - (bw + gap) - bw;
    if (px >= xback && px < xback + bw) return TB_BACK;
    if (px >= xfwd  && px < xfwd  + bw) return TB_FWD;
    if (px >= xrel  && px < xrel  + bw) return TB_RELOAD;
    if (px >= xmin  && px < xmin  + bw) return TB_MIN;
    if (px >= xclose&& px < xclose+ bw) return TB_CLOSE;
    return TB_URL;
}
static void draw_toolbar(nsfb_t *nsfb, int do_update)
{
    int bw = 56, pad = 14, gap = 10, cy = KFB_TBAR_H / 2;
    int xback = pad + bw/2, xfwd = pad + (bw+gap) + bw/2, xrel = pad + 2*(bw+gap) + bw/2;
    int xclose = kfb_scrw - pad - bw/2, xmin = kfb_scrw - pad - (bw+gap) - bw/2;
    int urlx0 = xrel + bw/2 + 18, urlx1 = xmin - bw/2 - 18;
    UNUSED(nsfb);
    if (kfb_mem == NULL) return;
    kfb_fill(0, 0, kfb_scrw, KFB_TBAR_H, 0xFF);            /* fehér háttér */
    kfb_fill(0, KFB_TBAR_H - 2, kfb_scrw, 2, 0x40);        /* alsó szegély */
    kfb_btnbox(xback, cy, bw); kfb_btnbox(xfwd, cy, bw); kfb_btnbox(xrel, cy, bw);
    kfb_btnbox(xmin, cy, bw);  kfb_btnbox(xclose, cy, bw);
    kfb_tri_left(xback, cy, 13, 0x00);
    kfb_tri_right(xfwd, cy, 13, 0x00);
    kfb_reload(xrel, cy, 14, 0x00);
    kfb_fill(xmin - 14, cy + 9, 28, 5, 0x00);              /* '_' minimalizál */
    kfb_line(xclose - 13, cy - 13, xclose + 13, cy + 13, 0x00, 3);  /* ✕ bezár */
    kfb_line(xclose + 13, cy - 13, xclose - 13, cy + 13, 0x00, 3);
    kfb_text(urlx0, (KFB_TBAR_H - KFB_FONT_CH) / 2, g_toolbar_url, urlx1);
    if (do_update) kfb_mtk_update(0, 0, kfb_scrw, KFB_TBAR_H, 0);
}

/* a teljes megrajzolt kép (nsfb->ptr) újbóli kiírása a kijelzőre + teljes e-ink frissítés.
 * Folytatáskor (SIGCONT) hívjuk, amikor a KOReader közben átrajzolta a framebuffert. */
static void full_reblit(nsfb_t *nsfb)
{
    int x, y;
    if (kfb_mem == NULL || nsfb->ptr == NULL) return;
    for (y = 0; y < nsfb->height; y++) {
        const uint32_t *src = (const uint32_t *)(nsfb->ptr + (size_t)y * nsfb->linelen);
        uint8_t *dst = kfb_mem + (size_t)(y + KFB_TBAR_H) * kfb_linelen;
        int gi; for (gi = 0; gi < KFB_GUTTER; gi++) dst[gi] = 0xFF;
        for (x = 0; x < nsfb->width; x++) {
            uint32_t p = src[x];
            int r =  p        & 0xFF;
            int g = (p >> 8)  & 0xFF;
            int b = (p >> 16) & 0xFF;
            dst[x + KFB_GUTTER] = (uint8_t)((r * 77 + g * 151 + b * 28) >> 8);
        }
    }
    draw_toolbar(nsfb, 0);                       /* a sávot is újrarajzoljuk */
    kfb_mtk_update(0, 0, kfb_scrw, kfb_scrh, 1); /* egyetlen teljes, tiszta frissítés */
}

static void minimize_self(nsfb_t *nsfb, int reason)
{
    const char *sig = getenv("NETSURF_SIGNAL_FILE");
    if (sig != NULL && sig[0] != 0) {
        FILE *f = fopen(sig, "w");
        if (f != NULL) { fputs(reason == 1 ? "menu" : reason == 2 ? "url" : reason == 3 ? "field" : "min", f); fputc('\n', f); fclose(f); }
    }
    if (ts_fd >= 0) ioctl(ts_fd, EVIOCGRAB, (void *)0);   /* grab elengedése */
    g_down = 0; g_scrolling = 0; pinch_on = 0;
    frame_down = -1; have_x = have_y = 0;
    sl_active[0] = sl_active[1] = 0;
    ktlog("minimalizalas (reason=%d): SIGSTOP", reason);
    fflush(NULL);
    raise(SIGSTOP);                 /* --- ide fagyunk; SIGCONT folytatja innen --- */
    if (ts_fd >= 0) {
        struct input_event d;
        ioctl(ts_fd, EVIOCGRAB, (void *)1);
        while (read(ts_fd, &d, sizeof(d)) == (ssize_t)sizeof(d)) { }
    }
    full_reblit(nsfb);
    g_resumed = 0;
    if (reason == 3) g_inject_request = 1;   /* mező: a fő ciklus injektálja a beírt szöveget */
    ktlog("folytatas: SIGCONT");
}

static int kindle_finalise(nsfb_t *nsfb)
{
    UNUSED(nsfb);
    if (nsfb->ptr != NULL) { free(nsfb->ptr); nsfb->ptr = NULL; }
    if (kfb_mem != NULL) { munmap(kfb_mem, kfb_memlen); kfb_mem = NULL; }
    if (kfb_fd != -1) { close(kfb_fd); kfb_fd = -1; }
    if (ts_fd != -1) { close(ts_fd); ts_fd = -1; }
    return 0;
}

/* érintőeszköz megkeresése: előnyben a multitouch (ABS_MT_POSITION_X),
 * másodsorban ABS_X. NETSURF_TOUCH_DEV felülírja. */
static int ts_probe(const char *path, int *is_mt)
{
    int fd;
    unsigned long absbits[NBITS(ABS_MAX + 1)];
    char name[128];
    int mt = 0, plain = 0;

    fd = open(path, O_RDONLY | O_NONBLOCK);
    if (fd < 0) return -1;
    name[0] = 0;
    ioctl(fd, EVIOCGNAME(sizeof(name)), name);
    memset(absbits, 0, sizeof(absbits));
    if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) >= 0) {
        mt    = TEST_BIT(ABS_MT_POSITION_X, absbits) ? 1 : 0;
        plain = TEST_BIT(ABS_X, absbits) ? 1 : 0;
    }
    ktlog("vizsgalat %s: name='%s' MT=%d ABS_X=%d", path, name, mt, plain);
    if (mt || plain) { *is_mt = mt; return fd; }
    close(fd);
    return -1;
}

static int ts_open(void)
{
    const char *env = getenv("NETSURF_TOUCH_DEV");
    int i, fd, is_mt;
    int plain_fd = -1;
    char path[64];

    ts_swap = getenv("NETSURF_TOUCH_SWAP") ? 1 : 0;
    ts_invx = getenv("NETSURF_TOUCH_INVX") ? 1 : 0;
    ts_invy = getenv("NETSURF_TOUCH_INVY") ? 1 : 0;
    ktlog("tajolas: swap=%d invx=%d invy=%d", ts_swap, ts_invx, ts_invy);

    if (env != NULL && env[0] != '\0') {
        fd = open(env, O_RDONLY | O_NONBLOCK);
        ktlog("NETSURF_TOUCH_DEV=%s -> fd=%d", env, fd);
        if (fd >= 0) return fd;
    }

    /* 1. kör: multitouch eszköz keresése; a sima ABS_X-eset megjegyezzük tartaléknak */
    for (i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        is_mt = 0;
        fd = ts_probe(path, &is_mt);
        if (fd < 0) continue;
        if (is_mt) { ktlog("valasztott (MT): %s fd=%d", path, fd); return fd; }
        if (plain_fd < 0) plain_fd = fd; else close(fd);
    }
    if (plain_fd >= 0) ktlog("valasztott (sima ABS_X) fd=%d", plain_fd);
    else ktlog("NEM talaltam erintoeszkozt");
    return plain_fd;
}

static void ts_read_range(int fd, int axis, int *mn, int *mx)
{
    struct input_absinfo ai;
    if (ioctl(fd, EVIOCGABS(axis), &ai) >= 0 && ai.maximum > ai.minimum) {
        *mn = ai.minimum; *mx = ai.maximum;
    }
}

static void ts_setup(nsfb_t *nsfb)
{
    int gr;
    ts_inited = 1;
    ts_fd = ts_open();
    if (ts_fd < 0) return;

    /* megpróbáljuk kizárólagosan lefoglalni; ha a KOReader már fogja, EBUSY-t kapunk */
    gr = ioctl(ts_fd, EVIOCGRAB, (void *)1);
    ktlog("EVIOCGRAB -> %d (0=siker; -1 es EBUSY: mas fogja)", gr);

    /* tartományok: előnyben a multitouch tengelyek */
    ts_min_x = 0; ts_max_x = nsfb->width  - 1;
    ts_min_y = 0; ts_max_y = nsfb->height - 1;
    ts_read_range(ts_fd, ABS_MT_POSITION_X, &ts_min_x, &ts_max_x);
    if (ts_max_x == nsfb->width - 1)  ts_read_range(ts_fd, ABS_X, &ts_min_x, &ts_max_x);
    ts_read_range(ts_fd, ABS_MT_POSITION_Y, &ts_min_y, &ts_max_y);
    if (ts_max_y == nsfb->height - 1) ts_read_range(ts_fd, ABS_Y, &ts_min_y, &ts_max_y);
    ktlog("tartomany X[%d..%d] Y[%d..%d] kijelzo %dx%d",
          ts_min_x, ts_max_x, ts_min_y, ts_max_y, nsfb->width, nsfb->height);
}

static int scale(int v, int mn, int mx, int screen)
{
    int s;
    if (mx <= mn) return v;
    s = (int)((long)(v - mn) * (screen - 1) / (mx - mn));
    if (s < 0) s = 0;
    if (s > screen - 1) s = screen - 1;
    return s;
}

/* zoom-lépés kibocsátása a NetSurfnek (Ctrl + '+' nagyítás / Ctrl + '-' kicsinyítés) */
static void emit_zoom(int zin)
{
    enum nsfb_key_code_e k = zin ? NSFB_KEY_EQUALS : NSFB_KEY_MINUS;
    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LCTRL);
    evq_push_key(NSFB_EVENT_KEY_DOWN, k);
    evq_push_key(NSFB_EVENT_KEY_UP, k);
    evq_push_key(NSFB_EVENT_KEY_UP, NSFB_KEY_LCTRL);
}

/* egy SYN_REPORT kiértékelése: a nyers állapotból nsfb eseményeket gyártunk */
static void ts_process_frame(nsfb_t *nsfb)
{
    int sx, sy, tmp, dx, dy, nscroll, nsc2;
    int nact = sl_active[0] + sl_active[1];

    /* --- PINCH ZOOM: két ujj a kijelzőn --- */
    if (nact >= 2) {
        int px = sl_x[0] - sl_x[1]; if (px < 0) px = -px;
        int py = sl_y[0] - sl_y[1]; if (py < 0) py = -py;
        int d = px + py;
        if (!pinch_on) {
            pinch_on = 1;
            g_down = 0; g_scrolling = 0;
            pinch_last = d;
        } else {
            int delta = d - pinch_last;
            int steps = 0;
            while (delta >= PINCH_STEP && steps < 3) { emit_zoom(1); pinch_last += PINCH_STEP; delta -= PINCH_STEP; steps++; }
            while (delta <= -PINCH_STEP && steps < 3) { emit_zoom(0); pinch_last -= PINCH_STEP; delta += PINCH_STEP; steps++; }
        }
        frame_down = -1; have_x = have_y = 0;
        return;
    }
    if (pinch_on) {
        pinch_on = 0; g_down = 0;
        frame_down = -1; have_x = have_y = 0;
        return;
    }

    /* skálázás a FIZIKAI kijelzőre */
    sx = scale(raw_x, ts_min_x, ts_max_x, kfb_scrw);
    sy = scale(raw_y, ts_min_y, ts_max_y, kfb_scrh);
    if (ts_swap) { tmp = sx; sx = sy; sy = tmp; }
    if (ts_invx) sx = kfb_scrw - 1 - sx;
    if (ts_invy) sy = kfb_scrh - 1 - sy;

    /* lenyomás kezdete */
    if (frame_down == 1 && !g_down) {
        g_down = 1;
        g_start_x = sx; g_start_y = sy;
        g_last_x = sx;  g_last_y = sy;
        g_moved = 0; g_scrolling = 0; g_scroll_accum = 0; g_scroll_accx = 0;
        g_min_fired = 0;
    }

    /* mozgás lenyomott ujjal */
    if (g_down && (have_x || have_y)) {
        dx = sx - g_last_x;
        dy = sy - g_last_y;
        g_moved += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);

        /* eszköztárból lefelé húzás -> minimalizálás (és a KOReader menü megnyitása) */
        if (!g_min_fired && g_start_y < KFB_TBAR_H) {
            int ddown = sy - g_start_y;
            int dhoriz = sx - g_start_x; if (dhoriz < 0) dhoriz = -dhoriz;
            if (ddown >= TOP_DRAG_TRIGGER && ddown > dhoriz) {
                g_min_fired = 1;
                minimize_self(nsfb, 1);
                frame_down = -1; have_x = have_y = 0;
                return;
            }
        }

        /* tartalom görgetése CSAK ha a tartalomban (a sáv alatt) kezdtünk */
        if (g_start_y >= KFB_TBAR_H) {
            if (!g_scrolling && g_moved > TAP_MAX_MOVE) {
                g_scrolling = 1; g_scroll_accum = 0; g_scroll_accx = 0;
            }
            if (g_scrolling) {
                g_scroll_accum += dy;
                nscroll = 0;
                while (g_scroll_accum <= -SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_5); g_scroll_accum += SCROLL_STEP; nscroll++;
                }
                while (g_scroll_accum >= SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_4); g_scroll_accum -= SCROLL_STEP; nscroll++;
                }
                g_scroll_accx += dx;
                nsc2 = 0;
                while (g_scroll_accx >= SCROLL_STEP && nsc2 < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_LEFT); g_scroll_accx -= SCROLL_STEP; nsc2++;
                }
                while (g_scroll_accx <= -SCROLL_STEP && nsc2 < SCROLL_MAX_PER_FRAME) {
                    evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_RIGHT); g_scroll_accx += SCROLL_STEP; nsc2++;
                }
            }
        }
        g_last_x = sx; g_last_y = sy;
    }

    /* elengedés */
    if (frame_down == 0 && g_down) {
        if (g_start_y < KFB_TBAR_H) {
            /* eszköztár-koppintás (nem húzás): a megfelelő gomb */
            if (!g_scrolling && !g_min_fired) {
                switch (toolbar_hit(g_start_x)) {
                    case TB_BACK:   g_nav_request = 1; break;
                    case TB_FWD:    g_nav_request = 2; break;
                    case TB_RELOAD: g_nav_request = 3; break;
                    case TB_MIN:    minimize_self(nsfb, 0); break;
                    case TB_CLOSE:  g_nav_request = 4; break;
                    case TB_URL:    minimize_self(nsfb, 2); break;
                    default: break;
                }
            }
        } else if (!g_scrolling) {
            /* tartalmi koppintás -> kattintás (gutter/sáv eltolással) */
            int cx = g_start_x - KFB_GUTTER, cy = g_start_y - KFB_TBAR_H;
            if (cx < 0) cx = 0;
            if (cx > nsfb->width - 1)  cx = nsfb->width - 1;
            if (cy < 0) cy = 0;
            if (cy > nsfb->height - 1) cy = nsfb->height - 1;
            /* ha a koppintás beviteli mezőbe talál, a place_caret ebből tudja,
             * hogy ez user-koppintás -> KOReader billentyűzet (nem automatikus fókusz) */
            g_field_click_pending = 4;
            evq_push_move(cx, cy);
            evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_1);
            evq_push_key(NSFB_EVENT_KEY_UP, NSFB_KEY_MOUSE_1);
        }
        g_down = 0;
    }

    frame_down = -1;
    have_x = have_y = 0;
}

static bool kindle_input(nsfb_t *nsfb, nsfb_event_t *event, int timeout)
{
    struct input_event iev;
    struct pollfd pfd;
    ssize_t n;
    int pr;

    if (!ts_inited) ts_setup(nsfb);

    /* folytatás minimalizálás után: a KOReader átrajzolta a kijelzőt, ezért a
     * böngésző teljes képét újra kiírjuk, mielőtt bármit feldolgoznánk */
    if (g_resumed) {
        g_resumed = 0;
        full_reblit(nsfb);
    }

    /* eszköztár újrarajzolása, ha az URL megváltozott (vagy az első hívásnál) */
    if (g_toolbar_url_dirty) {
        g_toolbar_url_dirty = 0;
        draw_toolbar(nsfb, 1);
    }

    /* oldalon belüli mező fókuszba került -> KOReader billentyűzet */
    if (g_field_input_request) {
        g_field_input_request = 0;
        minimize_self(nsfb, 3);
    }

    /* először a sorban álló eseményt adjuk vissza */
    if (evq_pop(event)) return true;

    if (ts_fd < 0) {
        /* nincs érintőeszköz: csak várunk, hogy a NetSurf ne pörögjön */
        if (timeout > 0) {
            struct timespec ts;
            ts.tv_sec = timeout / 1000;
            ts.tv_nsec = (long)(timeout % 1000) * 1000000L;
            nanosleep(&ts, NULL);
        }
        return false;
    }

    pfd.fd = ts_fd;
    pfd.events = POLLIN;
    pr = poll(&pfd, 1, timeout < 0 ? -1 : timeout);
    if (pr <= 0) return false;      /* időtúllépés vagy hiba */

    /* az összes elérhető evdev-rekord beolvasása és feldolgozása */
    while ((n = read(ts_fd, &iev, sizeof(iev))) == (ssize_t)sizeof(iev)) {
        switch (iev.type) {
        case EV_ABS:
            switch (iev.code) {
            case ABS_MT_SLOT:
                cur_slot = (iev.value >= 0 && iev.value < NSLOTS) ? iev.value : NSLOTS;
                break;
            case ABS_MT_POSITION_X:
                raw_x = iev.value; have_x = 1;
                if (cur_slot < NSLOTS) sl_x[cur_slot] = iev.value;
                break;
            case ABS_X:             raw_x = iev.value; have_x = 1; break;
            case ABS_MT_POSITION_Y:
                raw_y = iev.value; have_y = 1;
                if (cur_slot < NSLOTS) sl_y[cur_slot] = iev.value;
                break;
            case ABS_Y:             raw_y = iev.value; have_y = 1; break;
            case ABS_MT_TRACKING_ID:
                frame_down = (iev.value < 0) ? 0 : 1;
                if (cur_slot < NSLOTS) sl_active[cur_slot] = (iev.value < 0) ? 0 : 1;
                break;
            default: break;
            }
            break;
        case EV_KEY:
            if (iev.code == BTN_TOUCH) {
                frame_down = iev.value ? 1 : 0;
            }
            break;
        case EV_SYN:
            if (iev.code == SYN_REPORT) {
                ts_process_frame(nsfb);
            }
            break;
        default: break;
        }
    }

    if (evq_pop(event)) return true;
    return false;
}

const nsfb_surface_rtns_t kindle_rtns = {
    .defaults = kindle_defaults,
    .initialise = kindle_initialise,
    .finalise = kindle_finalise,
    .input = kindle_input,
    .update = kindle_update,
    .geometry = kindle_set_geometry,
};

NSFB_SURFACE_DEF(kindle, NSFB_SURFACE_LINUX, &kindle_rtns)

KFBEOF
    # a surface/Makefile-ban a mindig fordított kezelőkhöz hozzáadjuk
    sed -i 's/^SURFACE_HANDLER_yes := surface.c ram.c/SURFACE_HANDLER_yes := surface.c ram.c kindlefb.c/' \
        "$SRC/$lib/src/surface/Makefile"
    echo "   >>> surface/Makefile SURFACE_HANDLER_yes:"; grep "SURFACE_HANDLER_yes :=" "$SRC/$lib/src/surface/Makefile"
    tmake "$lib"
    tmake "$lib" install
    echo "   >>> lefordult-e a kindlefb?"; find "$SRC/$lib" -name 'kindlefb*.o' | head || echo "   (nem)"
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

# 2e) FreeType – rendes (TTF) betűkhöz, hogy a magyar ő, a cirill stb. is megjelenjen,
#     és a szöveg élsimított legyen (a beépített bittérképes font helyett).
FT_VER="2.13.3"
echo "==> freetype ${FT_VER} (target, statikus)"
ok=0
for url in \
  "https://download.savannah.gnu.org/releases/freetype/freetype-${FT_VER}.tar.gz" \
  "https://downloads.sourceforge.net/freetype/freetype-${FT_VER}.tar.gz" \
  "https://downloads.sourceforge.net/project/freetype/freetype2/${FT_VER}/freetype-${FT_VER}.tar.gz" ; do
  echo "   freetype letöltés: $url"
  if curl -fSL --retry 3 -o freetype.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "HIBA: freetype letöltése nem sikerült"; exit 1; }
tar xzf freetype.tar.gz
( cd "freetype-${FT_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --enable-static --disable-shared \
    --without-zlib --without-bzip2 --without-png --without-harfbuzz --without-brotli && \
  make -j"$JOBS" && make install )
[ -f "$PREFIX/lib/pkgconfig/freetype2.pc" ] || { echo "HIBA: freetype2.pc hiányzik"; exit 1; }
echo "   freetype2.pc rendben"

# 2f) libpng – a PNG képekhez (a NetSurf pkg-configgal keresi). zlib-re épül.
PNG_VER="1.6.44"
echo "==> libpng ${PNG_VER} (target, statikus)"
ok=0
for url in \
  "https://downloads.sourceforge.net/project/libpng/libpng16/${PNG_VER}/libpng-${PNG_VER}.tar.gz" \
  "https://downloads.sourceforge.net/libpng/libpng-${PNG_VER}.tar.gz" ; do
  echo "   libpng letöltés: $url"
  if curl -fSL --retry 3 -o libpng.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "HIBA: libpng letöltése nem sikerült"; exit 1; }
tar xzf libpng.tar.gz
( cd "libpng-${PNG_VER}" && \
  ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
    --enable-static --disable-shared \
    CPPFLAGS="-I$PREFIX/include" LDFLAGS="-L$PREFIX/lib" && \
  make -j"$JOBS" && make install )
[ -f "$PREFIX/lib/pkgconfig/libpng.pc" ] || { echo "HIBA: libpng.pc hiányzik"; exit 1; }
# statikus linkeléshez a png mellé a zlib és -lm is kelljen
sed -i 's/^Libs:.*/& -lz -lm/' "$PREFIX/lib/pkgconfig/libpng.pc"
echo "   libpng.pc rendben"

# 2g) libjpeg (IJG) – a JPEG képekhez (pl. könyvborítók). Best-effort: ha nem megy,
#     a build JPEG nélkül folytatódik (PNG akkor is lesz).
JPEG_OK=0
JPEG_VER="9f"
echo "==> libjpeg (IJG v${JPEG_VER}, target, statikus)"
ok=0
for url in \
  "https://www.ijg.org/files/jpegsrc.v${JPEG_VER}.tar.gz" \
  "http://www.ijg.org/files/jpegsrc.v${JPEG_VER}.tar.gz" ; do
  echo "   libjpeg letöltés: $url"
  if curl -fSL --retry 3 -o jpeg.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
if [ "$ok" = "1" ] && tar xzf jpeg.tar.gz 2>/dev/null; then
  if ( cd "jpeg-${JPEG_VER}" && \
       ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
         --enable-static --disable-shared && \
       make -j"$JOBS" && make install ); then
    [ -f "$PREFIX/include/jpeglib.h" ] && JPEG_OK=1
  fi
fi
if [ "$JPEG_OK" = "1" ]; then echo "   libjpeg kész (JPEG be)"; else echo "   FIGYELEM: libjpeg kimaradt (csak PNG lesz)"; fi

# 2h) libwebp – a WebP képekhez (pl. magyar híroldalak). Best-effort.
WEBP_OK=0
WEBP_VER="1.4.0"
echo "==> libwebp ${WEBP_VER} (target, statikus)"
ok=0
for url in \
  "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-${WEBP_VER}.tar.gz" \
  "https://github.com/webmproject/libwebp/releases/download/v${WEBP_VER}/libwebp-${WEBP_VER}.tar.gz" ; do
  echo "   libwebp letöltés: $url"
  if curl -fSL --retry 3 -o webp.tar.gz "$url"; then ok=1; break; fi
  sleep 5
done
if [ "$ok" = "1" ] && tar xzf webp.tar.gz 2>/dev/null; then
  if ( cd "libwebp-${WEBP_VER}" && \
       ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
         --enable-static --disable-shared \
         --disable-gif --disable-tiff --disable-jpeg --disable-png --disable-wic \
         --disable-libwebpmux --disable-libwebpdemux && \
       make -j"$JOBS" && make install ); then
    [ -f "$PREFIX/lib/pkgconfig/libwebp.pc" ] && WEBP_OK=1
  fi
fi
if [ "$WEBP_OK" = "1" ]; then echo "   libwebp kész (WebP be)"; else echo "   FIGYELEM: libwebp kimaradt"; fi

# a NetSurf a -ljpeg-et pkg-config nélkül adja hozzá, ezért a fordító keresési útjába
# tesszük a prefixünket (a png-t pkg-config amúgy is megtalálja)
export CPATH="$PREFIX/include${CPATH:+:$CPATH}"
export LIBRARY_PATH="$PREFIX/lib${LIBRARY_PATH:+:$LIBRARY_PATH}"

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

# 2j) A képernyő-billentyűzet (OSK) sötét háttere -> fehér (e-ink), hogy ne legyen fekete sáv
sed -i 's/fbtk_get_height(root) - wh, 0, wh, 0xff202020/fbtk_get_height(root) - wh, 0, wh, 0xffffffff/' \
  "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" || true
echo "   OSK háttér fehérre állítva:"; grep -n "0xffffffff" "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" | head -1 || true

# 2k) Szövegmezőre koppintva jöjjön fel MAGÁTÓL a billentyűzet (map_osk a text_input_click-ben)
python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/text.c" <<'PYOSK'
import re, sys
p = sys.argv[1]
s = open(p).read()
# a text_input_click függvényben a redraw után hívjuk meg a map_osk()-t
anchor = "\tfbtk_request_redraw(widget);\n\n\treturn 0;\n}"
m = s.find("text_input_click")
if m != -1:
    i = s.find(anchor, m)
    if i != -1:
        s = s[:i] + "\tfbtk_request_redraw(widget);\n\n\tmap_osk();\n\n\treturn 0;\n}" + s[i+len(anchor):]
        open(p, "w").write(s)
        sys.stderr.write("map_osk beszurva a text_input_click-be\n")
    else:
        sys.stderr.write("FIGYELEM: a text_input_click horgony nem talalhato (kihagyva)\n")
else:
    sys.stderr.write("FIGYELEM: text_input_click nem talalhato (kihagyva)\n")
PYOSK
grep -q "map_osk();" "$SRC/netsurf/frontends/framebuffer/fbtk/text.c" && echo "   auto-billentyűzet patch OK" || echo "   (auto-billentyűzet patch kimaradt)"

# 2m) Billentyűzet: a shift legyen RAGADÓS (caps lock) – különben nincs nagybetű
python3 - "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" <<'PYSHIFT'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''static int
osk_click(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
\tnsfb_event_t event;
\tstruct kbd_button_s *kbd_button = cbi->context;

\tevent.type = cbi->event->type;
\tevent.value.keycode = kbd_button->keycode;
\tfbtk_input(widget, &event);

\treturn 0;
}'''
new = '''static int osk_caps = 0;
static int
osk_click(fbtk_widget_t *widget, fbtk_callback_info *cbi)
{
\tnsfb_event_t event;
\tstruct kbd_button_s *kbd_button = cbi->context;

\t/* Shift = ragados valto (caps lock): tartja a modositot, amig ujra meg nem nyomjak */
\tif (kbd_button->keycode == NSFB_KEY_LSHIFT ||
\t    kbd_button->keycode == NSFB_KEY_RSHIFT) {
\t\tif (cbi->event->type == NSFB_EVENT_KEY_DOWN) {
\t\t\tosk_caps = !osk_caps;
\t\t\tevent.type = osk_caps ? NSFB_EVENT_KEY_DOWN : NSFB_EVENT_KEY_UP;
\t\t\tevent.value.keycode = NSFB_KEY_LSHIFT;
\t\t\tfbtk_input(widget, &event);
\t\t}
\t\treturn 0;
\t}

\tevent.type = cbi->event->type;
\tevent.value.keycode = kbd_button->keycode;
\tfbtk_input(widget, &event);

\treturn 0;
}'''
if old in s:
    s = s.replace(old, new)
    open(p, "w").write(s)
    sys.stderr.write("OSK shift-toggle beszurva\\n")
else:
    sys.stderr.write("FIGYELEM: osk_click horgony nem talalhato (shift patch kimaradt)\\n")
PYSHIFT
grep -q "osk_caps" "$SRC/netsurf/frontends/framebuffer/fbtk/osk.c" && echo "   shift (caps lock) patch OK" || echo "   (shift patch kimaradt)"

# 2n) A képernyő-billentyűzet hibás gombjai: a "/" és "\" keycode fel van cserélve (csak e két
#     gombon fordul elő), az aposztróf pedig "l"-t ad. Felcseréljük / javítjuk.
OSKC="$SRC/netsurf/frontends/framebuffer/fbtk/osk.c"
sed -i 's/NSFB_KEY_SLASH/__NSFBTMP__/g; s/NSFB_KEY_BACKSLASH/NSFB_KEY_SLASH/g; s/__NSFBTMP__/NSFB_KEY_BACKSLASH/g' "$OSKC"
sed -i "s/\"'\", NSFB_KEY_l/\"'\", NSFB_KEY_QUOTE/" "$OSKC"
echo "   OSK billentyű-javítások (perjel/aposztróf):"; grep -nE 'NSFB_KEY_QUOTE|"/", NSFB_KEY_SLASH' "$OSKC" | head

# 2o) Oldali (HTML) mezőre koppintva is jöjjön fel a billentyűzet (map_osk a caret-elhelyezéskor;
#     a map_osk() az fbtk.h-ban deklarálva van, amit a gui.c már include-ol)
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYCARET'
import sys
p = sys.argv[1]
s = open(p).read()
anc = ("\tfb_queue_redraw(g->browser,\n"
       "\t\t\tx - bwidget->scrollx,\n"
       "\t\t\ty - bwidget->scrolly,\n"
       "\t\t\tx + 1 - bwidget->scrollx,\n"
       "\t\t\ty + height - bwidget->scrolly);\n"
       "}")
new = anc[:-1] + ("\n\tif (g_field_click_pending > 0) { g_field_input_request = 1; g_field_click_pending = 0; }\n}")
if anc in s:
    s = s.replace(anc, new, 1)
    open(p, "w").write(s)
    sys.stderr.write("place_caret -> KOReader billentyuzet kivalto beszurva\n")
else:
    sys.stderr.write("FIGYELEM: place_caret horgony nem talalhato\n")
PYCARET
grep -q "g_field_input_request = 1" "$SRC/netsurf/frontends/framebuffer/gui.c" && echo "   mezo-fokusz (KOReader) patch OK" || { echo "HIBA: mezo-fokusz patch nem sikerult"; exit 1; }

# 2l) LETÖLTÉS-KEZELŐ a framebuffer frontendhez (hiányzik belőle): fájlba menti a
#     letöltött fájlt a NETSURF_DOWNLOAD_DIR mappába, és a NETSURF_DL_LIST listába írja.
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYDL'
import sys
p = sys.argv[1]
s = open(p).read()
block = r'''
/* ===== Kindle: fajlba mento letoltes (a fb frontendbol hianyzik) ===== */
#include "netsurf/download.h"
#include "desktop/download.h"
struct gui_download_window { FILE *kf; char kpath[1024]; download_context *kctx; };
static struct gui_download_window *
fb_kindle_download_create(download_context *ctx, struct gui_window *parent)
{
	const char *dir = getenv("NETSURF_DOWNLOAD_DIR");
	const char *fn = download_context_get_filename(ctx);
	struct gui_download_window *dw;
	char name[512];
	char cmd[1200];
	char *p;
	(void) parent;
	if (dir == NULL || dir[0] == 0) dir = "/mnt/us/koreader/documents";
	if (fn != NULL && fn[0] != 0) { strncpy(name, fn, sizeof(name) - 1); name[sizeof(name) - 1] = 0; }
	else { snprintf(name, sizeof(name), "letoltes-%ld", (long) time(NULL)); }
	for (p = name; *p != 0; p++) { if (*p == '/' || *p == '\\') *p = '_'; }
	dw = calloc(1, sizeof(*dw));
	if (dw == NULL) return NULL;
	dw->kctx = ctx;
	snprintf(cmd, sizeof(cmd), "mkdir -p \"%s\" 2>/dev/null", dir);
	if (system(cmd) == -1) { /* ignore */ }
	snprintf(dw->kpath, sizeof(dw->kpath), "%s/%s", dir, name);
	dw->kf = fopen(dw->kpath, "wb");
	if (dw->kf == NULL) { free(dw); return NULL; }
	NSLOG(netsurf, INFO, "Kindle download -> %s", dw->kpath);
	return dw;
}
static nserror
fb_kindle_download_data(struct gui_download_window *dw, const char *data, unsigned int size)
{
	if (dw != NULL && dw->kf != NULL && size > 0) {
		if (fwrite(data, 1, size, dw->kf) != size) return NSERROR_SAVE_FAILED;
	}
	return NSERROR_OK;
}
static void
fb_kindle_download_error(struct gui_download_window *dw, const char *error_msg)
{
	NSLOG(netsurf, INFO, "Kindle download error: %s", error_msg ? error_msg : "?");
	if (dw != NULL) { if (dw->kf != NULL) fclose(dw->kf); download_context_destroy(dw->kctx); free(dw); }
}
static void
fb_kindle_download_done(struct gui_download_window *dw)
{
	const char *listf;
	if (dw == NULL) return;
	if (dw->kf != NULL) fclose(dw->kf);
	NSLOG(netsurf, INFO, "Kindle download done: %s", dw->kpath);
	listf = getenv("NETSURF_DL_LIST");
	if (listf != NULL && listf[0] != 0) {
		FILE *lf = fopen(listf, "a");
		if (lf != NULL) { fputs(dw->kpath, lf); fputc('\n', lf); fclose(lf); }
	}
	download_context_destroy(dw->kctx);
	free(dw);
}
static struct gui_download_table framebuffer_download_table = {
	.create = fb_kindle_download_create,
	.data = fb_kindle_download_data,
	.error = fb_kindle_download_error,
	.done = fb_kindle_download_done,
};
/* ===== Kindle letoltes vege ===== */

'''
anchor = "\t.quit = gui_quit,\n};\n"
i = s.find(anchor)
if i == -1:
    sys.stderr.write("DL-PATCH HIBA: misc_table horgony nem talalhato\n"); sys.exit(2)
i += len(anchor)
s = s[:i] + block + s[i:]
# a tablaba bejegyezzuk a letoltest
tbl = "\t\t.fetch = framebuffer_fetch_table,\n"
j = s.find(tbl)
if j == -1:
    sys.stderr.write("DL-PATCH HIBA: framebuffer_table horgony nem talalhato\n"); sys.exit(2)
j += len(tbl)
s = s[:j] + "\t\t.download = &framebuffer_download_table,\n" + s[j:]
open(p, "w").write(s)
sys.stderr.write("Letoltes-kezelo beszurva a fb frontendbe\n")
PYDL
grep -q "framebuffer_download_table" "$SRC/netsurf/frontends/framebuffer/gui.c" \
  && echo "   letöltés-kezelő patch OK" || { echo "HIBA: letöltés-kezelő patch nem sikerült"; exit 1; }

# 2p) SAJÁT ESZKÖZTÁR: a felület (kindlefb.c) rajzolja a felső sávot és állítja a
#     g_nav_request / g_toolbar_url jelzőket. A gui.c-nek három dolgot kell tennie:
#      - extern deklarációk a megosztott jelzőkhöz,
#      - a fő ciklusban a vissza/előre/újratöltés/bezárás kérelmek kezelése,
#      - az URL megváltozásakor átmásolni a címet a saját sáv számára (és NULL-védelem,
#        mert a natív eszköztárat kikapcsoljuk, így g->url lehet NULL).
python3 - "$SRC/netsurf/frontends/framebuffer/gui.c" <<'PYTB'
import sys
p = sys.argv[1]; s = open(p).read()

a1 = "static bool fb_complete = false;\n"
if a1 not in s:
    sys.stderr.write("TB-PATCH HIBA: fb_complete horgony nem talalhato\n"); sys.exit(2)
add1 = a1 + ('#include <signal.h>\n'
             'extern char g_toolbar_url[1024];\n'
             'extern volatile sig_atomic_t g_toolbar_url_dirty;\n'
             'extern volatile sig_atomic_t g_nav_request;\n'
             'extern volatile sig_atomic_t g_field_click_pending;\n'
             'extern volatile sig_atomic_t g_field_input_request;\n'
             'extern volatile sig_atomic_t g_inject_request;\n')
s = s.replace(a1, add1, 1)

a2 = "\twhile (fb_complete != true) {\n"
if a2 not in s:
    sys.stderr.write("TB-PATCH HIBA: fo ciklus horgony nem talalhato\n"); sys.exit(2)
h2 = ("\t\tif (g_nav_request != 0) {\n"
      "\t\t\tint _r = g_nav_request; g_nav_request = 0;\n"
      "\t\t\tif (window_list != NULL && window_list->bw != NULL) {\n"
      "\t\t\t\tif (_r == 1) browser_window_history_back(window_list->bw, false);\n"
      "\t\t\t\telse if (_r == 2) browser_window_history_forward(window_list->bw, false);\n"
      "\t\t\t\telse if (_r == 3) browser_window_reload(window_list->bw, true);\n"
      "\t\t\t\telse if (_r == 4) fb_complete = true;\n"
      "\t\t\t}\n"
      "\t\t}\n"
      "\t\tif (g_field_click_pending > 0) g_field_click_pending--;\n"
      "\t\tif (g_inject_request != 0) {\n"
      "\t\t\tg_inject_request = 0;\n"
      "\t\t\tif (window_list != NULL && window_list->bw != NULL) {\n"
      "\t\t\t\tconst char *_if = getenv(\"NETSURF_INJECT_FILE\");\n"
      "\t\t\t\tif (_if != NULL && _if[0] != 0) {\n"
      "\t\t\t\t\tFILE *_f = fopen(_if, \"rb\");\n"
      "\t\t\t\t\tif (_f != NULL) {\n"
      "\t\t\t\t\t\tint _ch; uint32_t _cp = 0; int _need = 0;\n"
      "\t\t\t\t\t\twhile ((_ch = fgetc(_f)) != EOF) {\n"
      "\t\t\t\t\t\t\tunsigned char _b = (unsigned char)_ch;\n"
      "\t\t\t\t\t\t\tif (_need == 0) {\n"
      "\t\t\t\t\t\t\t\tif (_b == '\\n' || _b == '\\r') continue;\n"
      "\t\t\t\t\t\t\t\tif (_b < 0x80) { browser_window_key_press(window_list->bw, _b); }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xE0) == 0xC0) { _cp = _b & 0x1F; _need = 1; }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xF0) == 0xE0) { _cp = _b & 0x0F; _need = 2; }\n"
      "\t\t\t\t\t\t\t\telse if ((_b & 0xF8) == 0xF0) { _cp = _b & 0x07; _need = 3; }\n"
      "\t\t\t\t\t\t\t\telse { _need = 0; }\n"
      "\t\t\t\t\t\t\t} else {\n"
      "\t\t\t\t\t\t\t\tif ((_b & 0xC0) == 0x80) { _cp = (_cp << 6) | (_b & 0x3F); _need--; if (_need == 0) browser_window_key_press(window_list->bw, _cp); }\n"
      "\t\t\t\t\t\t\t\telse { _need = 0; }\n"
      "\t\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\t}\n"
      "\t\t\t\t\t\tfclose(_f); remove(_if);\n"
      "\t\t\t\t\t}\n"
      "\t\t\t\t}\n"
      "\t\t\t}\n"
      "\t\t}\n")
s = s.replace(a2, a2 + h2, 1)

a3 = "\tfbtk_set_text(g->url, nsurl_access(url));\n"
if a3 not in s:
    sys.stderr.write("TB-PATCH HIBA: set_url horgony nem talalhato\n"); sys.exit(2)
h3 = ("\t{ const char *_u = nsurl_access(url);\n"
      "\t  strncpy(g_toolbar_url, _u ? _u : \"\", sizeof(g_toolbar_url) - 1);\n"
      "\t  g_toolbar_url[sizeof(g_toolbar_url) - 1] = 0; g_toolbar_url_dirty = 1;\n"
      "\t  { const char *_hf = getenv(\"NETSURF_HISTORY_FILE\");\n"
      "\t    if (_hf != NULL && _hf[0] != 0 && _u != NULL && _u[0] != 0 && strncmp(_u, \"about:\", 6) != 0) {\n"
      "\t      FILE *_h = fopen(_hf, \"a\"); if (_h != NULL) { fputs(_u, _h); fputc('\\n', _h); fclose(_h); } } } }\n"
      "\tif (g->url != NULL) fbtk_set_text(g->url, nsurl_access(url));\n")
s = s.replace(a3, h3, 1)

open(p, "w").write(s)
sys.stderr.write("Sajat eszkoztar patch beszurva a gui.c-be\n")
PYTB
grep -q "g_nav_request" "$SRC/netsurf/frontends/framebuffer/gui.c" \
  && echo "   saját eszköztár (gui.c) patch OK" || { echo "HIBA: saját eszköztár patch nem sikerült"; exit 1; }

# 3) NetSurf, framebuffer frontend, linux felület (/dev/fb + /dev/input), JS (duktape)
echo "==> netsurf (framebuffer)"
make -C "$SRC/netsurf" -j"$JOBS" \
  CC="${CROSS}gcc" AR="${CROSS}ar" HOST="$TARGET_TUPLE" \
  PREFIX="$PREFIX" NSSHARED="$TGT_NSSHARED" \
  NSGENBIND="$HOSTPREFIX/bin/nsgenbind" \
  TARGET=framebuffer \
  NETSURF_FB_FRONTEND=linux \
  NETSURF_FB_FONTLIB=freetype \
  PKG_CONFIG_PATH="$PREFIX/lib/pkgconfig" \
  NETSURF_USE_DUKTAPE=YES \
  NETSURF_USE_JPEG=$([ "$JPEG_OK" = "1" ] && echo YES || echo NO) \
  NETSURF_USE_PNG=YES NETSURF_USE_WEBP=$([ "$WEBP_OK" = "1" ] && echo YES || echo NO) \
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

# 5) libmobi + mobitool – azw3/mobi/KF8 -> EPUB konverzió a készüléken (külső függőség
#    nélkül: beépített miniz + xmlwriter). Best-effort: ha nem épül, a többi attól kész.
echo "==> libmobi (mobitool, azw3->epub)"
if [ ! -d "$ROOT/libmobi" ]; then
  git clone --depth 1 https://github.com/bfabiszewski/libmobi "$ROOT/libmobi" || true
fi
if [ -d "$ROOT/libmobi" ]; then
  # a teljes libmobi-build kimenetét a naplóba mentjük (az artifactba is bekerül)
  ( cd "$ROOT/libmobi" && \
    ./autogen.sh && \
    ./configure --host="$TARGET_TUPLE" --prefix="$PREFIX" \
      --enable-static --disable-shared --enable-tools \
      --with-zlib=no --with-libxml2=no \
      LDFLAGS="-Wl,--allow-multiple-definition" && \
    make -j"$JOBS" ) > "$OUT/libmobi-build.log" 2>&1 || echo "   FIGYELEM: libmobi fordítás hiba (lásd libmobi-build.log)"
  # a libtool az IGAZI ELF binárist a .libs/ alá teszi; azt keressük elsőként
  MOBITOOL_BIN="$(find "$ROOT/libmobi" -path '*/.libs/mobitool' -type f 2>/dev/null | head -n1 || true)"
  [ -n "$MOBITOOL_BIN" ] || MOBITOOL_BIN="$(find "$ROOT/libmobi" -name mobitool -type f 2>/dev/null | head -n1 || true)"
  if [ -n "$MOBITOOL_BIN" ] && head -c4 "$MOBITOOL_BIN" | grep -q "ELF"; then
    cp "$MOBITOOL_BIN" "$OUT/mobitool" && "${CROSS}strip" "$OUT/mobitool" 2>/dev/null || true
  else
    echo "   (mobitool bináris nem ELF vagy nincs: $MOBITOOL_BIN)"
  fi
fi
[ -f "$OUT/mobitool" ] && echo "   mobitool kész: $(file "$OUT/mobitool" | cut -c1-50)" || echo "   FIGYELEM: mobitool nem épült (a konverzió kimarad)"

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
# DejaVu TTF betűk a res/fonts alá (ezekből tölt a freetype backend: magyar ő, cirill, görög)
echo "==> DejaVu betűk letöltése"
DEJAVU_VER="2.37"
ok=0
for url in \
  "https://github.com/dejavu-fonts/dejavu-fonts/releases/download/version_2_37/dejavu-fonts-ttf-${DEJAVU_VER}.tar.bz2" \
  "https://downloads.sourceforge.net/project/dejavu/dejavu/${DEJAVU_VER}/dejavu-fonts-ttf-${DEJAVU_VER}.tar.bz2" ; do
  echo "   DejaVu letöltés: $url"
  if curl -fSL --retry 3 -o dejavu.tar.bz2 "$url"; then ok=1; break; fi
  sleep 5
done
[ "$ok" = "1" ] || { echo "HIBA: DejaVu letöltése nem sikerült"; exit 1; }
tar xjf dejavu.tar.bz2
DEJAVU_DIR="$(find "$ROOT" -maxdepth 2 -type d -name 'dejavu-fonts-ttf-*' | head -n1)/ttf"
mkdir -p "$OUT/res/fonts"
for f in DejaVuSans.ttf DejaVuSans-Bold.ttf DejaVuSans-Oblique.ttf \
         DejaVuSans-BoldOblique.ttf DejaVuSerif.ttf DejaVuSerif-Bold.ttf \
         DejaVuSansMono.ttf DejaVuSansMono-Bold.ttf ; do
  cp -f "$DEJAVU_DIR/$f" "$OUT/res/fonts/$f" || { echo "HIBA: $f hiányzik"; exit 1; }
done
echo "   DejaVu betűk a res/fonts alatt:"; ls -1 "$OUT/res/fonts"

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
