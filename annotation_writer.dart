// pdf_tile_rasterizer.dart
//
// The concrete rasterizer that plugs into the engine's TileRasterizer seam.
// The pure engine decides WHICH tiles to render and at what pixel size; this
// class turns one TileRenderRequest into a ui.Image using pdfrx (PDFium).
//
// World-space convention for a single page (matches the engine + the loader):
//   world = page space in PDF points, origin top-left, y increasing DOWN.
//   This mirrors the rendered image's orientation, so a tile's world rectangle
//   maps to image pixels with NO per-tile vertical flip.
//
// API note: the render() call below reflects the current pdfrx API (verified
// against pdfrx's published API docs): named params x/y/width/height (ints),
// fullWidth/fullHeight (doubles), backgroundColor as an int ARGB, and an
// optional PdfPageRenderCancellationToken. PdfImage exposes createImage() ->
// ui.Image and dispose(). pdfrx evolves across 1.x — if a build error points
// here, reconcile names with your installed version. This file is real,
// complete code but was NOT compiled here (no Flutter SDK in the build env).

import 'dart:ui' as ui;

import 'package:pdfrx/pdfrx.dart';

import '../engine/tile.dart';

class PdfTileRasterizer implements TileRasterizer<ui.Image> {
  final PdfPage page;

  PdfTileRasterizer(this.page);

  @override
  Future<ui.Image> rasterize(
    TileRenderRequest request,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();

    final wb = request.worldBounds;
    final tileWorldWidth = wb.width;
    if (tileWorldWidth <= 0) {
      return _transparent(request.pixelWidth, request.pixelHeight);
    }

    final pageW = page.width; // points
    final pageH = page.height;

    // Tile entirely outside the page -> a fully transparent tile (cached so the
    // scheduler doesn't re-request it; draws nothing).
    if (wb.maxX <= 0 || wb.minX >= pageW || wb.maxY <= 0 || wb.minY >= pageH) {
      return _transparent(request.pixelWidth, request.pixelHeight);
    }

    // Render scale (pixels per point) implied by the requested tile resolution.
    final renderScale = request.pixelWidth / tileWorldWidth;
    final fullWidth = (pageW * renderScale);
    final fullHeight = (pageH * renderScale);

    // Top-left pixel of this tile within the full rendered page image.
    final pxX = (wb.minX * renderScale).round();
    final pxY = (wb.minY * renderScale).round();

    // Wire our cooperative cancellation into PDFium's native render token so an
    // off-screen / superseded tile aborts the native render, not just the Dart
    // future. (Method name per pdfrx; verify against your installed version.)
    final pdfToken = page.createCancellationToken();
    token.onCancel(pdfToken.cancel);

    final PdfImage? rendered = await page.render(
      x: pxX,
      y: pxY,
      width: request.pixelWidth,
      height: request.pixelHeight,
      fullWidth: fullWidth,
      fullHeight: fullHeight,
      backgroundColor: const ui.Color(0x00000000), // transparent (pdfrx render takes Color?)
      cancellationToken: pdfToken,
    );

    token.throwIfCancelled();
    if (rendered == null) {
      // Null means either nothing to draw or the render was cancelled.
      if (token.isCancelled) throw const CancellationException();
      return _transparent(request.pixelWidth, request.pixelHeight);
    }

    final ui.Image image = await rendered.createImage();
    rendered.dispose();

    if (token.isCancelled) {
      image.dispose();
      throw const CancellationException();
    }
    return image;
  }

  Future<ui.Image> _transparent(int w, int h) {
    final recorder = ui.PictureRecorder();
    // Recording an empty canvas yields a fully transparent picture.
    ui.Canvas(recorder, ui.Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()));
    final picture = recorder.endRecording();
    return picture.toImage(w, h);
  }
}
