// search_overlay.dart
//
// Draws find-in-document highlights above the page. Rects are in world space
// (top-left, y-down); the canvas is transformed by the camera so highlights
// track pan/zoom/rotation exactly like the page beneath them.

import 'package:flutter/material.dart';

import '../engine/viewport_core.dart';

class SearchHighlightPainter extends CustomPainter {
  final Camera camera;

  /// Merged highlight rects for every match on the visible page (world space).
  final List<Aabb> all;

  /// Merged highlight rects for the active match (world space).
  final List<Aabb> active;

  SearchHighlightPainter({
    required this.camera,
    required this.all,
    required this.active,
  });

  static const Color _base = Color(0x33F6A623); // translucent amber
  static const Color _activeFill = Color(0x66F6A623); // stronger amber
  static const Color _activeEdge = Color(0xFFE5604A); // coral

  @override
  void paint(Canvas canvas, Size size) {
    if (all.isEmpty && active.isEmpty) return;
    canvas.save();
    canvas.clipRect(Offset.zero & size);
    canvas.transform(camera.worldToScreen.toCanvasMatrix4());

    final basePaint = Paint()
      ..isAntiAlias = true
      ..color = _base;
    for (final r in all) {
      canvas.drawRect(Rect.fromLTRB(r.minX, r.minY, r.maxX, r.maxY), basePaint);
    }

    if (active.isNotEmpty) {
      final fill = Paint()
        ..isAntiAlias = true
        ..color = _activeFill;
      // Stroke width is in world units under the camera transform; divide by
      // scale so the outline stays ~2px on screen at any zoom.
      final edge = Paint()
        ..isAntiAlias = true
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0 / (camera.scale == 0 ? 1.0 : camera.scale)
        ..color = _activeEdge;
      for (final r in active) {
        final rect = Rect.fromLTRB(r.minX, r.minY, r.maxX, r.maxY);
        canvas.drawRect(rect, fill);
        canvas.drawRect(rect, edge);
      }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant SearchHighlightPainter old) =>
      old.camera.center != camera.center ||
      old.camera.scale != camera.scale ||
      old.camera.rotation != camera.rotation ||
      !identical(old.all, all) ||
      !identical(old.active, active);
}
