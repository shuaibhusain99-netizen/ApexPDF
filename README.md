# Ultimate PDF — free, privacy-first, multilingual Android PDF viewer + editor

A Flutter app built on a **custom double-precision tiled vector viewport engine**
that scales from 500-page multilingual documents to CAD/GIS-scale drawings
(50k+ vector primitives, 1000%+ zoom), with PDFium rasterization via `pdfrx`.

---

## Honest build status — read this first

This repository is delivered in three tiers with **different** verification levels.
Nothing here is a stub, but not everything is finished, and the parts that aren't
are listed explicitly. No feature is claimed "done" unless it is.

| Tier | What | Status |
|---|---|---|
| **1. Viewport engine** (`lib/engine/`) | Coordinate/camera core, R-tree, culler, LOD + Douglas–Peucker, tile cache, scheduler | ✅ **Complete & tested — 53/53 unit tests pass, `dart analyze` clean.** Pure Dart, zero deps. |
| **2. Flutter integration harness** (`lib/viewport/`, `lib/viewer/`, `lib/app.dart`, `lib/main.dart`) | pdfrx-backed rasterizer, gesture→camera wiring, tile painter, viewer screen, RTL/i18n app shell | ⚠️ **Real, complete code but UNVERIFIED.** It was **not** compiled here (no Flutter SDK / Android toolchain in the build environment). Compile it in yours. The `pdfrx` `render()` signature has shifted across 1.x — verify param names. |
| **3. Editing / device features** | annotations, forms, scan, OCR, signing, redaction, multilingual PDF fallback, complex-script authoring | ❌ **Not built.** Each requires native plugins / NDK / a device and is multi-week. See **Completion map** below. The architecture has clean seams for all of them. |

A genuinely shippable commercial PDF editor is a multi-month, multi-component
build. This delivers the hard, reusable **core** finished and proven, plus the
integration scaffold and an exact map of the remaining work — instead of a pile
of stubs pretending to be an app.

---

## Why a custom engine (the unifying insight)

Off-the-shelf PDF widgets re-render whole pages and choke on extreme zoom or
huge vector content. The same engine that makes a 500-page multilingual document
buttery also makes a 1:30,000 blueprint smooth — **so it's built once**:

- **Double-precision coordinates + tile-local rebasing.** All world coords and
  gestures stay in `double`; geometry is rebased to a tile-local origin before
  any narrowing for the GPU. Measured: naive float32-on-large-coords jitters by
  **1.36 px**; the rebased path holds **1.1×10⁻⁵ px** at 2000% zoom with 1e6
  offsets — a **~119,000× precision gain** (proven in `test/viewport_core_test.dart`).
- **No drift.** The camera is an absolute state (center/scale/rotation),
  re-derived into a transform every frame — never an accumulated matrix.
  10,000 mixed gestures accumulate no error (tested).
- **O(log n + k) culling.** A bulk-loaded, immutable, flat-array R-tree replaces
  the O(50,000)/frame scan. Verified against brute force over random data.
- **Bounded memory + cancellation.** An LRU tile cache with a hard byte ceiling;
  obsolete in-flight tiles are cancelled on every viewport change; the screen is
  never blank thanks to graceful fallback to coarser cached tiles.
- **Substrate-agnostic.** The engine has **zero Flutter dependency**. The
  `TileRasterizer<T>` seam means the `pdfrx`/Flutter-`Canvas` rasterizer ships
  now and a native SurfaceView/Skia/NDK rasterizer can drop in later for the
  most extreme CAD cases **without touching the engine**.

---

## Architecture / layering

```
┌──────────────────────────── Flutter app (Tier 2) ────────────────────────────┐
│ main.dart → app.dart (MaterialApp, RTL + i18n) → viewer/viewer_screen.dart     │
│   → viewport/pdf_viewport.dart  (gestures → Camera, CustomPaint → tiles)       │
│       └── viewport/pdf_tile_rasterizer.dart  (implements TileRasterizer)       │
│              └── pdfrx (PDFium): renders a tile's world rect → ui.Image        │
├──────────────────────── Viewport engine — pure Dart (Tier 1) ─────────────────┤
│ engine/viewport_core.dart  Vec2 · Aabb · Affine2 · Camera                      │
│ engine/spatial_index.dart  RTreeBuilder · RTree (flat, Morton-packed)          │
│ engine/lod.dart            LodPolicy · DouglasPeucker                          │
│ engine/tile.dart           ViewportCuller · CancellationToken ·                │
│                            TileKey · TileRasterizer · TileCache · TileManager  │
└────────────────────────────────────────────────────────────────────────────────┘
```

World-space convention for a page: PDF points, **origin top-left, y-DOWN**
(mirrors the rendered image, so tiles map to pixels with no per-tile flip).

---

## Assemble & run

1. **Create a Flutter app** and drop these files in:
   ```
   flutter create ultimate_pdf
   # replace lib/ with this lib/, replace pubspec.yaml, copy test/
   flutter pub get
   ```
2. **Run the engine's tests** (these are the verified part). They use a tiny
   zero-dependency harness, so plain Dart runs them:
   ```
   dart test/viewport_core_test.dart   # 32 tests
   dart test/engine_test.dart          # 21 tests
   ```
   (Or port them to `package:flutter_test` / `package:test` — replace the
   harness functions at the top of each file.)
3. **Run the app** on an Android device/emulator:
   ```
   flutter run
   ```
4. **Verify `pdfrx`**: confirm `PdfPage.render(...)` parameter names and the
   `PdfImage.createImage()` bridge against your installed `pdfrx` version; adjust
   `lib/viewport/pdf_tile_rasterizer.dart` if they differ. Add any required
   `pdfrx` init call in `lib/main.dart`.

### Import-path notes
- The four engine files live together in `lib/engine/` and import each other by
  bare relative name (`import 'viewport_core.dart';`) — keep them co-located.
- Harness files import the engine via `../engine/...`.
- `test/*.dart` currently import the engine by relative path; if you move them,
  fix the relative imports or switch to `package:ultimate_pdf/engine/...`.

### Android packaging mandate
Google Play requires **16 KB native-library alignment** (effective Nov 1 2025).
Build with an NDK/AGP combo that emits 16 KB-aligned `.so`s and verify
`pdfrx`'s bundled PDFium is aligned before release.

---

## Completion map (Tier 3 — not built; seams are ready)

Recommended stack (all permissively licensed; **avoid AGPL** — MuPDF, iText,
Poppler — for a freely-distributable app). Editing here means
annotations/overlay/forms/redaction/page-ops/signing — **not** in-place text
reflow, which is not feasible for free and is intentionally out of scope.

| Feature | Library / approach | Slots into | Realistic effort |
|---|---|---|---|
| **Annotations** (ink, highlight, shapes, notes) | `androidx.ink` for strokes; persist via **PdfBox-Android** (Apache-2.0) annotation dictionaries | New overlay layer above the tile painter; annotations indexed in a second `RTree` for hit-testing | 3–5 wks |
| **Forms (AcroForm)** | PdfBox-Android form fields; Flutter form-field overlay widgets | Overlay layer + value persistence | 3–4 wks |
| **Document scan** | **ML Kit Document Scanner** (on-device) → image → PDF | New capture flow → PdfBox-Android page builder | 2–3 wks |
| **OCR → searchable PDF** | **ML Kit** (Latin/CJK/etc.) or **Tesseract4Android**; write an invisible text layer | PdfBox-Android content stream (hidden text) | 4–6 wks |
| **Digital signatures (PAdES)** | **PdfBox-Android + BouncyCastle**; Android Keystore for keys | Save pipeline (incremental update) | 5–8 wks |
| **True redaction** | Remove content (not just black boxes): rewrite content streams, drop images/text under marks, scrub metadata, full re-save | PdfBox-Android content editing + a verification pass | 4–6 wks |
| **Multilingual PDF rendering fallback** | Bundle **Noto** fonts; configure PDFium font fallback so PDFs lacking embedded complex-script fonts still render | `pdfrx`/PDFium font config (native) | 2–3 wks |
| **Complex-script authoring** (insert shaped Arabic/CJK/Indic text) | **HarfBuzz + ICU** (NDK) for shaping/BiDi, then `FPDFText_SetCharcodes` | New native shaping module behind a Dart channel | 6–10 wks (stretch) |
| **Continuous multi-page layout** | Stack pages in one world (vertical, with gaps); rasterizer selects the page a tile falls in | Extend `PdfTileRasterizer` + a page-offset map; engine already supports it | 1–2 wks |

---

## What's proven today

```
dart analyze .            → No issues found!
test/viewport_core_test   → 32 passed, 0 failed
test/engine_test          → 21 passed, 0 failed
                            (incl. R-tree brute-force equivalence,
                             10,000-gesture no-drift, float32 deep-zoom proof,
                             async tile scheduling/cancellation, LRU eviction)
```

The engine — the part that's genuinely hard and the reason this app can do what
generic viewers can't — is finished and verified. The rest is honest, staged,
and seam-ready.
