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

#include "libnsfb.h"
#include "libnsfb_plot.h"
#include "libnsfb_event.h"

#include "nsfb.h"
#include "surface.h"
#include "plot.h"

#define UNUSED(x) ((x) = (x))

static int      kfb_fd = -1;
static uint8_t *kfb_mem = NULL;      /* a valódi framebuffer mmap-je (8bpp) */
static size_t   kfb_memlen = 0;
static int      kfb_linelen = 0;     /* a fb sor hossza bájtban */

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

#define TAP_MAX_MOVE 18      /* ennél kisebb elmozdulás: koppintás */
#define SCROLL_STEP  80      /* ennyi képpont húzás = egy görgetőlépés */
#define SCROLL_MAX_PER_FRAME 4

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

    /* a NetSurf a valódi kijelző méretén, 32bpp ABGR RAM-pufferbe rajzol */
    nsfb->width = vinfo.xres;
    nsfb->height = vinfo.yres;
    nsfb->format = NSFB_FMT_ABGR8888;
    select_plotters(nsfb);               /* bpp = 32 */
    nsfb->linelen = nsfb->width * 4;
    nsfb->ptr = calloc((size_t)nsfb->width * nsfb->height, 4);
    if (nsfb->ptr == NULL) {
        munmap(kfb_mem, kfb_memlen); kfb_mem = NULL; close(kfb_fd); kfb_fd = -1;
        return -1;
    }
    return 0;
}

static int kindle_set_geometry(nsfb_t *nsfb, int width, int height, enum nsfb_format_e format)
{
    UNUSED(format);
    if (width > 0)  nsfb->width = width;
    if (height > 0) nsfb->height = height;
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

    for (y = y0; y < y1; y++) {
        const uint32_t *src = (const uint32_t *)(nsfb->ptr + (size_t)y * nsfb->linelen);
        uint8_t *dst = kfb_mem + (size_t)y * kfb_linelen;
        for (x = x0; x < x1; x++) {
            uint32_t p = src[x];
            int r =  p        & 0xFF;
            int g = (p >> 8)  & 0xFF;
            int b = (p >> 16) & 0xFF;
            dst[x] = (uint8_t)((r * 77 + g * 151 + b * 28) >> 8); /* luminancia */
        }
    }
    return 0;
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

/* érintőeszköz megkeresése: az első olyan /dev/input/event*, amelyiken van
 * ABS_MT_POSITION_X vagy ABS_X. NETSURF_TOUCH_DEV felülírja. */
static int ts_open(void)
{
    const char *env = getenv("NETSURF_TOUCH_DEV");
    int i, fd;
    unsigned long absbits[NBITS(ABS_MAX + 1)];
    char path[64];

    ts_swap = getenv("NETSURF_TOUCH_SWAP") ? 1 : 0;
    ts_invx = getenv("NETSURF_TOUCH_INVX") ? 1 : 0;
    ts_invy = getenv("NETSURF_TOUCH_INVY") ? 1 : 0;

    if (env != NULL && env[0] != '\0') {
        fd = open(env, O_RDONLY | O_NONBLOCK);
        if (fd >= 0) return fd;
    }

    for (i = 0; i < 32; i++) {
        snprintf(path, sizeof(path), "/dev/input/event%d", i);
        fd = open(path, O_RDONLY | O_NONBLOCK);
        if (fd < 0) continue;
        memset(absbits, 0, sizeof(absbits));
        if (ioctl(fd, EVIOCGBIT(EV_ABS, sizeof(absbits)), absbits) >= 0) {
            if (TEST_BIT(ABS_MT_POSITION_X, absbits) || TEST_BIT(ABS_X, absbits)) {
                return fd;
            }
        }
        close(fd);
    }
    return -1;
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
    ts_inited = 1;
    ts_fd = ts_open();
    if (ts_fd < 0) return;

    /* tartományok: előnyben a multitouch tengelyek */
    ts_min_x = 0; ts_max_x = nsfb->width  - 1;
    ts_min_y = 0; ts_max_y = nsfb->height - 1;
    ts_read_range(ts_fd, ABS_MT_POSITION_X, &ts_min_x, &ts_max_x);
    if (ts_max_x == nsfb->width - 1)  ts_read_range(ts_fd, ABS_X, &ts_min_x, &ts_max_x);
    ts_read_range(ts_fd, ABS_MT_POSITION_Y, &ts_min_y, &ts_max_y);
    if (ts_max_y == nsfb->height - 1) ts_read_range(ts_fd, ABS_Y, &ts_min_y, &ts_max_y);
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

/* egy SYN_REPORT kiértékelése: a nyers állapotból nsfb eseményeket gyártunk */
static void ts_process_frame(nsfb_t *nsfb)
{
    int sx, sy, tmp, dx, dy, nscroll;

    /* skálázás a kijelzőre */
    sx = scale(raw_x, ts_min_x, ts_max_x, nsfb->width);
    sy = scale(raw_y, ts_min_y, ts_max_y, nsfb->height);
    if (ts_swap) { tmp = sx; sx = sy; sy = tmp; }
    if (ts_invx) sx = nsfb->width  - 1 - sx;
    if (ts_invy) sy = nsfb->height - 1 - sy;

    /* lenyomás kezdete */
    if (frame_down == 1 && !g_down) {
        g_down = 1;
        g_start_x = sx; g_start_y = sy;
        g_last_x = sx;  g_last_y = sy;
        g_moved = 0; g_scrolling = 0; g_scroll_accum = 0;
    }

    /* mozgás lenyomott ujjal */
    if (g_down && (have_x || have_y)) {
        dx = sx - g_last_x;
        dy = sy - g_last_y;
        g_moved += (dx < 0 ? -dx : dx) + (dy < 0 ? -dy : dy);
        if (!g_scrolling && g_moved > TAP_MAX_MOVE) {
            g_scrolling = 1;
            g_scroll_accum = 0;
        }
        if (g_scrolling) {
            g_scroll_accum += dy;
            nscroll = 0;
            /* ujj felfelé (dy<0) -> tartalom lefelé gördül -> MOUSE_5 */
            while (g_scroll_accum <= -SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_5);
                g_scroll_accum += SCROLL_STEP; nscroll++;
            }
            while (g_scroll_accum >= SCROLL_STEP && nscroll < SCROLL_MAX_PER_FRAME) {
                evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_4);
                g_scroll_accum -= SCROLL_STEP; nscroll++;
            }
        }
        g_last_x = sx; g_last_y = sy;
    }

    /* elengedés */
    if (frame_down == 0 && g_down) {
        if (!g_scrolling) {
            /* koppintás -> kattintás a kezdőponton */
            evq_push_move(g_start_x, g_start_y);
            evq_push_key(NSFB_EVENT_KEY_DOWN, NSFB_KEY_MOUSE_1);
            evq_push_key(NSFB_EVENT_KEY_UP, NSFB_KEY_MOUSE_1);
        }
        g_down = 0;
    }

    /* frame állapot nullázása a következőhöz */
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
            case ABS_MT_POSITION_X: raw_x = iev.value; have_x = 1; break;
            case ABS_X:             raw_x = iev.value; have_x = 1; break;
            case ABS_MT_POSITION_Y: raw_y = iev.value; have_y = 1; break;
            case ABS_Y:             raw_y = iev.value; have_y = 1; break;
            case ABS_MT_TRACKING_ID:
                frame_down = (iev.value < 0) ? 0 : 1;
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
