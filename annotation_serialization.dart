// pdf_viewport.dart
//
// The Flutter widget that hosts the engine for one PDF page:
//  * holds the absolute Camera and the TileManager,
//  * translates scale/pan/rotate gestures into focal-stable Camera transitions
//    (recomputed from absolutes -> no long-run drift),
//  * paints the manager's gap-free draw set using camera.tileTransform(), the
//    tile-local placement that keeps content crisp at extreme zoom.
//
// Honest caveat: real, complete code, but NOT compiled here (no Flutter SDK in
// the build container). Compile in your Flutter/Android toolchain.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import '../engine/viewport_core.dart';
import '../engine/lod.dart';
import '../engine/tile.dart';
import 'pdf_tile_rasterizer.dart';
import '../annotations/annotation_overlay.dart';
import '../search/search_overlay.dart';

class PdfViewport extends StatefulWidget {
  final PdfPage page;

  /// Cache ceiling for rasterized tiles (bytes). Tune to device memory.
  final int cacheBytes;

  /// When provided, an annotation overlay is mounted above the page and (when a
  /// tool is active) captures pointer input instead of pan/zoom.
  final AnnotationController? annotationController;

  /// Highlight rects (world space) for all search matches on this page.
  final List<Aabb> searchRects;

  /// Highlight rects (world space) for the active search match on this page.
  final List<Aabb> activeSearchRects;

  /// Optional color filter applied to the PAGE only (reading modes). Overlays
  /// (annotations, search highlights) are not filtered.
  final ColorFilter? pageFilter;

  const PdfViewport({
    super.key,
    required this.page,
    this.cacheBytes = 192 * 1024 * 1024,
    this.annotationController,
    this.searchRects = const <Aabb>[],
    this.activeSearchRects = const <Aabb>[],
    this.pageFilter,
  });

  @override
  State<PdfViewport> createState() => _PdfViewportState();
}

class _PdfViewportState extends State<PdfViewport> {
  late Camera _camera;
  late TileManager<ui.Image> _manager;
  Size _viewport = Size.zero;
  bool _fitted = false;

  // Incremental gesture tracking (scale & rotation are cumulative-since-start).
  double _lastScale = 1.0;
  double _lastRotation = 0.0;

  @override
  void initState() {
    super.initState();
    final pageW = widget.page.width;
    final pageH = widget.page.height;

    _camera = Camera(
      center: Vec2(pageW / 2, pageH / 2),
      scale: 1.0,
      viewportWidth: 1, // replaced on first layout
      viewportHeight: 1,
      minScale: 0.05,
      maxScale: 64.0,
    );

    final lod = LodPolicy(
      tilePixelSize: 512,
      baseScale: 1.0,
      baseTileWorldSize: 512,
      minLevel: 0,
      maxLevel: 16,
    );

    final cache = TileCache<ui.Image>(
      maxBytes: widget.cacheBytes,
      sizeOf: (im) => im.width * im.height * 4,
      dispose: (im) => im.dispose(),
    );

    _manager = TileManager<ui.Image>(
      rasterizer: PdfTileRasterizer(widget.page),
      cache: cache,
      lod: lod,
      bufferPx: 256,
      onTileReady: () {
        if (mounted) setState(() {});
      },
    );
  }

  void _applyViewport(Size size) {
    if (size.isEmpty || size == _viewport) return;
    _viewport = size;
    _camera = _camera.resize(size.width, size.height);

    if (!_fitted) {
      // Fit page to width on first valid layout.
      final fitScale = (size.width / widget.page.width)
          .clamp(_camera.minScale, _camera.maxScale)
          .toDouble();
      _camera = _camera.copyWith(scale: fitScale);
      _fitted = true;
    }
    _manager.update(_camera);
    if (mounted) setState(() {});
  }

  void _onScaleStart(ScaleStartDetails d) {
    _lastScale = 1.0;
    _lastRotation = 0.0;
  }

  void _onScaleUpdate(ScaleUpdateDetails d) {
    var cam = _camera;

    // Pan by the focal point's incremental movement.
    if (d.focalPointDelta != Offset.zero) {
      cam = cam.panByScreen(d.focalPointDelta.dx, d.focalPointDelta.dy);
    }

    // Incremental zoom about the focal point.
    final zoomFactor = d.scale / _lastScale;
    if (zoomFactor.isFinite && zoomFactor > 0 && zoomFactor != 1.0) {
      cam = cam.zoomBy(zoomFactor, d.focalPoint.dx, d.focalPoint.dy);
    }
    _lastScale = d.scale == 0 ? _lastScale : d.scale;

    // Incremental rotation about the focal point.
    final dRotation = d.rotation - _lastRotation;
    if (dRotation != 0.0) {
      cam = cam.rotateBy(dRotation, d.focalPoint.dx, d.focalPoint.dy);
    }
    _lastRotation = d.rotation;

    setState(() => _camera = cam);
    _manager.update(_camera);
  }

  @override
  void dispose() {
    _manager.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        WidgetsBinding.instance
            .addPostFrameCallback((_) => _applyViewport(size));

        Widget pageContent = CustomPaint(
          size: size,
          isComplex: true,
          willChange: true,
          painter: _TilePainter(_camera, _manager),
        );
        if (widget.pageFilter != null) {
          pageContent = ColorFiltered(
            colorFilter: widget.pageFilter!,
            child: pageContent,
          );
        }

        final tileLayer = GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          child: pageContent,
        );

        final children = <Widget>[tileLayer];

        // Search highlights sit above the page, below annotations.
        if (widget.searchRects.isNotEmpty ||
            widget.activeSearchRects.isNotEmpty) {
          children.add(
            IgnorePointer(
              child: CustomPaint(
                size: size,
                painter: SearchHighlightPainter(
                  camera: _camera,
                  all: widget.searchRects,
                  active: widget.activeSearchRects,
                ),
              ),
            ),
          );
        }

        final controller = widget.annotationController;
        if (controller != null) {
          // Annotations render above the page and follow the same camera. When
          // a drawing/erase tool is active the gesture layer intercepts
          // pointers; otherwise events fall through to pan/zoom below.
          children.add(
            IgnorePointer(
              child: CustomPaint(
                size: size,
                painter: AnnotationOverlayPainter(
                  camera: _camera,
                  controller: controller,
                ),
              ),
            ),
          );
          children.add(
            ListenableBuilder(
              listenable: controller,
              builder: (_, __) => AnnotationGestureLayer(
                controller: controller,
                cameraOf: () => _camera,
                child: const SizedBox.expand(),
              ),
            ),
          );
        }

        if (children.length == 1) return tileLayer;
        return Stack(fit: StackFit.expand, children: children);
      },
    );
  }
}

class _TilePainter extends CustomPainter {
  final Camera camera;
  final TileManager<ui.Image> manager;

  _TilePainter(this.camera, this.manager);

  final Paint _paint = Paint()
    ..filterQuality = FilterQuality.medium
    ..isAntiAlias = true;

  @override
  void paint(Canvas canvas, Size size) {
    // Clip to the viewport.
    canvas.clipRect(Offset.zero & size);

    final tiles = manager.collectDrawTiles(camera);
    for (final tile in tiles) {
      final anchor = Vec2(tile.worldBounds.minX, tile.worldBounds.minY);
      // Tile-local -> screen transform (full double precision; large world
      // magnitude already removed by the anchor). This is the placement path
      // that keeps content crisp at 1000%+ zoom.
      final transform = camera.tileTransform(anchor);

      canvas.save();
      canvas.transform(transform.toCanvasMatrix4());

      final image = tile.value;
      final src = Rect.fromLTWH(
        0,
        0,
        image.width.toDouble(),
        image.height.toDouble(),
      );
      // Destination is the tile's extent in tile-local WORLD units; the canvas
      // transform scales/rotates it onto the screen.
      final dst = Rect.fromLTWH(
        0,
        0,
        tile.worldBounds.width,
        tile.worldBounds.height,
      );
      canvas.drawImageRect(image, src, dst, _paint);
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(covariant _TilePainter old) => true;
}
