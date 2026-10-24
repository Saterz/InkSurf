# InkSurf – KOReader browser plugin (NetSurf engine)

A self-contained browser for KOReader: it embeds the NetSurf engine to handle
JavaScript, logins and most file types that the stock Kindle browser can't.

## Install

Copy the whole `inksurf.koplugin` folder here:

```
koreader/plugins/inksurf.koplugin
```

Restart KOReader. The browser is reachable from the main menu and from the
KOReader Settings menu.

## Where is data stored?

**All browser data lives in the plugin's own `data/` subfolder**; nothing is
scattered into the KOReader root:

```
inksurf.koplugin/
├── main.lua, wb_*.lua, vpn.sh      ← the plugin code
├── bin/                            ← netsurf, aria2c, openvpn, fbink, certificates
├── vpn/                            ← your own .ovpn configs + auth files
└── data/                           ← ALL runtime data (see below)
    ├── inksurf.lua                 ← FAVORITES + settings + selected VPN server
    ├── inksurf_torrent.lua         ← torrent state
    ├── cache/                      ← saved (reader-mode) pages (last 25)
    ├── netsurf.history             ← browsing history
    ├── netsurf_cookies             ← cookies
    └── netsurf.pid / .state / .signal / .inject / netsurf_*.sh / netsurf_hosts.bak
       (netsurf.log and netsurf_field.log appear only when Debug log is on)
```

**Downloaded files** (books, documents) do NOT go here; they go to the download
folder set in Settings (default: `koreader/documents`) so KOReader's file manager
can see them.

## Language

The UI language is switchable under **Settings → Language / Nyelv / Sprache**:
**English (default)**, Hungarian, German. The choice is saved to `data/inksurf.lua`.
After switching, **restart KOReader** for it to take effect everywhere (KOReader
caches the main menu, so reopening the menu alone is not enough).

## Update

When updating the plugin, overwrite all files in the folder **but leave the
`data/` subfolder untouched**. Your favorites, history and settings are then kept
in the new version.

> If you overwrite/delete the `data/` folder too, favorites and settings are lost
> (that's a "clean install" – see below).

## Uninstall / full reset

- **Reset everything but keep the plugin:** Settings → *Full cleanup / reset*.
  Clears `data/` (favorites, history, settings, cache, cookies). Leaves the code
  and your `vpn/` configs alone.
- **Full removal:** delete the whole `koreader/plugins/inksurf.koplugin` folder.
  Everything is gone – no stray files left anywhere.

(Older 0.x versions wrote into the KOReader root; the cleanup button removes those
leftover files too, if any.)
