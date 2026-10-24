# Third-party components & licenses

InkSurf bundles and/or builds the following third-party software. Each remains
under its own license; this file is the attribution + source-offer required by
those licenses. Fill in the exact versions from `build.sh` where marked `<ver>`.

## Browser engine
- **NetSurf 3.11** — © NetSurf Developers. License: **GPL-2.0** (core & framebuffer
  frontend). Source: https://www.netsurf-browser.org/ (release `netsurf-all-3.11`).
  InkSurf builds NetSurf from this upstream release and applies patches contained
  in `build.sh`. The InkSurf-specific additions to NetSurf — the Kindle framebuffer
  surface (`kindlefb.c`), the custom toolbar / minimize / field-input patches to
  `frontends/framebuffer/gui.c`, `event.c`, `osk.c`, and `clipboard.c` — are
  **derivative works of NetSurf and are therefore licensed GPL-2.0**. The complete
  corresponding source is `build.sh` plus the referenced upstream release.
- **Duktape** (JavaScript engine, compiled into NetSurf) — MIT. https://duktape.org/

## Bundled command-line binaries (invoked as separate processes)
- **aria2c** `<ver>` — GPL-2.0-or-later. https://github.com/aria2/aria2
- **openvpn** `<ver>` — GPL-2.0. https://openvpn.net/community-downloads/
- **FBInk (fbink)** `<ver>` — GPL-3.0-or-later. https://github.com/NiLuJe/FBInk
- **libmobi (mobitool)** `<ver>` — LGPL-3.0-or-later. https://github.com/bfabiszewski/libmobi

## Data & resources
- **Mozilla CA certificate bundle** (`bin/cacert.pem`) — MPL-2.0.
  https://curl.se/docs/caextract.html
- **DejaVu fonts** (`bin/res/fonts/`) — Bitstream Vera License + public-domain
  additions. https://dejavu-fonts.github.io/
- **Ad/tracker hosts list** (`bin/ad_hosts.txt`) — a small curated blocklist in the
  spirit of public hosts lists (e.g. StevenBlack/hosts, AdAway). If you derived it
  from a specific list, credit it here.

## Acknowledgements
- Reader-mode and the general plugin idea were inspired by
  **omer-faruq/webbrowser.koplugin** (https://github.com/omer-faruq/webbrowser.koplugin).
  InkSurf's reader mode is an independent, local implementation (no third-party
  extraction service). No source code was copied; credit is given as inspiration.
  (InkSurf uses its own package name `inksurf.koplugin` to avoid any collision.)
- Built on **KOReader** (https://github.com/koreader/koreader), AGPL-3.0 —
  InkSurf is a plugin that runs inside KOReader; it does not include KOReader code.

## Note on GPL source availability
Because this distribution ships GPL-licensed binaries, you must make the
corresponding source available to recipients. For NetSurf this is satisfied by
`build.sh` (which fetches the exact upstream release and contains all patches).
For aria2 / openvpn / fbink / libmobi, link to the exact upstream version you
built (fill the `<ver>` fields above), or include a written offer valid for 3
years as GPL-2.0 §3(b) allows.
