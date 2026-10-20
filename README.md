# NetSurf a Kindle-re (KOReader mellé)

Ez a repó a **NetSurf** böngészőt fordítja le a Kindle-re GitHub Actionsben.
A NetSurf egy könnyű, valódi böngészőmotor, ami – a mi Lua-s böngészőnkkel ellentétben –
**korlátozottan JavaScriptet is tud** (Duktape). A nehéz, JS-es oldalakhoz való;
az egyszerűeket a KOReader-plugin beépített nézete gyorsabban kezeli.

> Megjegyzés: a 2024-es Paperwhite (12. gen) nagyon új. Ez a build **kísérleti** –
> az első cél az, hogy egyáltalán elinduljon a készüléken. A GitHub Actions naplója
> mutatja, hol akad el; abból tudjuk finomítani. Ne várd, hogy elsőre tökéletes.

## Használat

1. Hozz létre egy új, üres repót a GitHub-fiókodban (pl. `netsurf-kindle`).
2. Tölts fel bele ebből a mappából mindent: `build.sh`, `README.md`, és a
   `.github/workflows/build.yml` fájlt a mappaszerkezettel együtt.
3. A repó **Actions** fülén engedélyezd a workflow-kat, majd nyomd meg a
   **Run workflow** gombot (vagy pushold a `main`-re).
4. A build végén az **Artifacts** alatt lesz egy `netsurf-kindle-…` csomag.
   Töltsd le; ebben van a `netsurf` bináris és a `res/` mappa.

## Telepítés a Kindle-re

1. A KOReader `plugins/` mappájában hozz létre egy `netsurf.koplugin` mappát.
2. Tedd bele:
   - `bin/netsurf`  ← a letöltött bináris
   - `res/`         ← a letöltött erőforrások
3. Indítsd újra a KOReadert. A „Web böngésző + VPN” menüben a
   **NetSurf motor (JavaScript)** innentől aktív, és a linkeknél megjelenik a
   „Megnyitás NetSurfben”.

(A plugin a binárist a `netsurf.koplugin/bin/netsurf` vagy `…/bin/nsfb` útvonalon keresi,
illetve a beállításokban megadott egyedi útvonalon.)

## Mi történik a build során

- Megépül a Kindle-fordító (**koxtoolchain**, `kindlehf` cél) – ez lassú, ezért
  gyorsítótárazzuk, a második futástól gyors.
- Lefordul a NetSurf függőséglánca (libwapcaplet, libcss, libdom, libnsfb, …),
  majd maga a NetSurf a **framebuffer** frontenddel és a **linux** felülettel
  (közvetlenül a `/dev/fb0`-ra rajzol és a `/dev/input`-ot olvassa).
- A JavaScript a beépített **Duktape**-pel épül.

## Ismert nyitott pontok (ezeken fogunk iterálni)

- **Érintés.** A framebuffer-frontend egeret vár; a Kindle érintését ehhez
  hozzá kell igazítani. Ez a legnagyobb bizonytalanság.
- **Betűk.** Most a beépített (internal) betűkészlettel épül (csúnyább, de
  függőség nélküli). Ha megy, átállunk freetype-ra a szebb betűkért.
- **A `kindlehf` cél** lehet, hogy a 2024-es modellhez igazítást igényel; a
  workflow „Toolchain tuple” lépése kiírja, mit talált.
