// annotation_model.dart
//
// Feature 1 — Annotations (core domain model).
//
// Pure Dart (no Flutter), so it is unit-testable and reusable by both the
// Flutter overlay and a future native renderer. Annotations live in WORLD space
// (PDF page points, y-down — same convention as the viewport engine), so they
// pan/zoom/rotate with the document for free via the camera transform.
//
// Colors are ARGB ints (0xAARRGGBB) to avoid a Flutter dependency; the overlay
// converts them to ui.Color at paint time.

import 'dart:math' as math;
import 'dart:typed_data';

import '../engine/viewport_core.dart' show Aabb;

/// Discriminator for serialization / UI switching without `is` chains.
enum AnnotationKind { ink, highlight, rectangle, ellipse, line, note }

/// Base type for all annotations. Sealed: the full set of subtypes is known,
/// enabling exhaustive `switch` handling in renderers and serializers.
sealed class Annotation {
  /// Stable unique id (assigned by the caller / an [AnnotationIdGenerator]).
  final String id;

  /// 0-based page this annotation belongs to.
  final int pageIndex;

  /// Stroke / outline colour as ARGB (0xAARRGGBB).
  final int colorArgb;

  Annotation({
    required this.id,
    required this.pageIndex,
    required this.colorArgb,
  }) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id', 'must not be empty');
    if (pageIndex < 0) {
      throw ArgumentError.value(pageIndex, 'pageIndex', 'must be >= 0');
    }
  }

  AnnotationKind get kind;

  /// Axis-aligned world-space bounds (used for spatial indexing & culling).
  Aabb get worldBounds;

  /// True if the world-space point (x,y) is on/within this annotation, allowing
  /// [toleranceWorld] world units of slack (for finger/cursor picking).
  bool hitTest(double x, double y, double toleranceWorld);
}

/// Freehand ink: a single polyline stroke `[x0,y0,x1,y1,...]` with a width.
final class InkAnnotation extends Annotation {
  final Float64List points;
  final double strokeWidth;

  InkAnnotation({
    required super.id,
    required super.pageIndex,
    required super.colorArgb,
    required this.points,
    required this.strokeWidth,
  }) {
    if (points.length.isOdd) {
      throw ArgumentError('points length must be even (got ${points.length})');
    }
    if (points.length < 2) {
      throw ArgumentError('ink needs at least one point');
    }
    if (!(strokeWidth >= 0) || !strokeWidth.isFinite) {
      throw ArgumentError.value(strokeWidth, 'strokeWidth', 'must be finite >= 0');
    }
  }

  @override
  AnnotationKind get kind => AnnotationKind.ink;

  @override
  Aabb get worldBounds {
    var minX = double.infinity,
        minY = double.infinity,
        maxX = double.negativeInfinity,
        maxY = double.negativeInfinity;
    for (var i = 0; i < points.length; i += 2) {
      final x = points[i], y = points[i + 1];
      if (x < minX) minX = x;
      if (y < minY) minY = y;
      if (x > maxX) maxX = x;
      if (y > maxY) maxY = y;
    }
    final pad = strokeWidth * 0.5;
    return Aabb(minX - pad, minY - pad, maxX + pad, maxY + pad);
  }

  @override
  bool hitTest(double x, double y, double toleranceWorld) {
    final reach = toleranceWorld + strokeWidth * 0.5;
    final reach2 = reach * reach;
    // Single point degenerate stroke.
    if (points.length == 2) {
      final dx = x - points[0], dy = y - points[1];
      return dx * dx + dy * dy <= reach2;
    }
    for (var i = 0; i + 3 < points.length; i += 2) {
      final d2 = _distToSegmentSq(
        x, y,
        points[i], points[i + 1],
        points[i + 2], points[i + 3],
      );
      if (d2 <= reach2) return true;
    }
    return false;
  }
}

/// Text-markup highlight: one or more rectangles (multi-line selections).
final class HighlightAnnotation extends Annotation {
  final List<Aabb> rects;

  HighlightAnnotation({
    required super.id,
    required super.pageIndex,
    required super.colorArgb,
    required this.rects,
  }) {
    if (rects.isEmpty) throw ArgumentError('highlight needs >= 1 rect');
  }

  @override
  AnnotationKind get kind => AnnotationKind.highlight;

  @override
  Aabb get worldBounds {
    var b = rects.first;
    for (var i = 1; i < rects.length; i++) {
      b = b.union(rects[i]);
    }
    return b;
  }

  @override
  bool hitTest(double x, double y, double toleranceWorld) {
    for (final r in rects) {
      if (x >= r.minX - toleranceWorld &&
          x <= r.maxX + toleranceWorld &&
          y >= r.minY - toleranceWorld &&
          y <= r.maxY + toleranceWorld) {
        return true;
      }
    }
    return false;
  }
}

/// Rectangle or ellipse shape (outline, optionally filled).
final class ShapeAnnotation extends Annotation {
  final Aabb rect;
  final bool ellipse;
  final bool filled;
  final double strokeWidth;

  ShapeAnnotation({
    required super.id,
    required super.pageIndex,
    required super.colorArgb,
    required this.rect,
    required this.ellipse,
    required this.filled,
    required this.strokeWidth,
  }) {
    if (!(strokeWidth >= 0) || !strokeWidth.isFinite) {
      throw ArgumentError.value(strokeWidth, 'strokeWidth', 'must be finite >= 0');
    }
  }

  @override
  AnnotationKind get kind =>
      ellipse ? AnnotationKind.ellipse : AnnotationKind.rectangle;

  @override
  Aabb get worldBounds {
    final pad = strokeWidth * 0.5;
    return Aabb(
      rect.minX - pad,
      rect.minY - pad,
      rect.maxX + pad,
      rect.maxY + pad,
    );
  }

  @override
  bool hitTest(double x, double y, double toleranceWorld) {
    if (filled) {
      if (!ellipse) {
        return x >= rect.minX - toleranceWorld &&
            x <= rect.maxX + toleranceWorld &&
            y >= rect.minY - toleranceWorld &&
            y <= rect.maxY + toleranceWorld;
      }
      // Filled ellipse: normalized radius test.
      final rx = rect.width * 0.5, ry = rect.height * 0.5;
      if (rx <= 0 || ry <= 0) return false;
      final nx = (x - rect.centerX) / (rx + toleranceWorld);
      final ny = (y - rect.centerY) / (ry + toleranceWorld);
      return nx * nx + ny * ny <= 1.0;
    }
    // Outline-only: hit if near the border band of width stroke+tolerance.
    final band = toleranceWorld + strokeWidth * 0.5;
    if (!ellipse) {
      final onVert = (x - rect.minX).abs() <= band || (x - rect.maxX).abs() <= band;
      final onHorz = (y - rect.minY).abs() <= band || (y - rect.maxY).abs() <= band;
      final insideX = x >= rect.minX - band && x <= rect.maxX + band;
      final insideY = y >= rect.minY - band && y <= rect.maxY + band;
      return (onVert && insideY) || (onHorz && insideX);
    }
    final rx = rect.width * 0.5, ry = rect.height * 0.5;
    if (rx <= 0 || ry <= 0) return false;
    final nx = (x - rect.centerX) / rx;
    final ny = (y - rect.centerY) / ry;
    final v = nx * nx + ny * ny; // 1.0 on the ellipse
    final tol = band / math.max(rx, ry);
    return (v - 1.0).abs() <= 2 * tol;
  }
}

/// Straight line/arrow between two world points.
final class LineAnnotation extends Annotation {
  final double x1, y1, x2, y2;
  final double strokeWidth;

  LineAnnotation({
    required super.id,
    required super.pageIndex,
    required super.colorArgb,
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
    required this.strokeWidth,
  }) {
    if (!(strokeWidth >= 0) || !strokeWidth.isFinite) {
      throw ArgumentError.value(strokeWidth, 'strokeWidth', 'must be finite >= 0');
    }
  }

  @override
  AnnotationKind get kind => AnnotationKind.line;

  @override
  Aabb get worldBounds {
    final pad = strokeWidth * 0.5;
    return Aabb(
      math.min(x1, x2) - pad,
      math.min(y1, y2) - pad,
      math.max(x1, x2) + pad,
      math.max(y1, y2) + pad,
    );
  }

  @override
  bool hitTest(double x, double y, double toleranceWorld) {
    final reach = toleranceWorld + strokeWidth * 0.5;
    return _distToSegmentSq(x, y, x1, y1, x2, y2) <= reach * reach;
  }
}

/// Anchored sticky note (point + text). Picking uses a small icon radius.
final class NoteAnnotation extends Annotation {
  final double x, y;
  final String text;

  /// World-space radius of the clickable note icon.
  final double iconRadius;

  NoteAnnotation({
    required super.id,
    required super.pageIndex,
    required super.colorArgb,
    required this.x,
    required this.y,
    required this.text,
    this.iconRadius = 12.0,
  }) {
    if (!(iconRadius > 0) || !iconRadius.isFinite) {
      throw ArgumentError.value(iconRadius, 'iconRadius', 'must be finite > 0');
    }
  }

  @override
  AnnotationKind get kind => AnnotationKind.note;

  @override
  Aabb get worldBounds =>
      Aabb(x - iconRadius, y - iconRadius, x + iconRadius, y + iconRadius);

  @override
  bool hitTest(double px, double py, double toleranceWorld) {
    final r = iconRadius + toleranceWorld;
    final dx = px - x, dy = py - y;
    return dx * dx + dy * dy <= r * r;
  }
}

/// Monotonic id generator for newly created annotations.
final class AnnotationIdGenerator {
  int _n = 0;
  final String prefix;
  AnnotationIdGenerator({this.prefix = 'a'});
  String next() => '$prefix${_n++}';
}

/// Squared distance from point (px,py) to segment (ax,ay)-(bx,by).
double _distToSegmentSq(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  var dx = bx - ax;
  var dy = by - ay;
  final lenSq = dx * dx + dy * dy;
  if (lenSq > 0) {
    final t = ((px - ax) * dx + (py - ay) * dy) / lenSq;
    if (t > 1) {
      dx = px - bx;
      dy = py - by;
    } else if (t > 0) {
      dx = px - (ax + dx * t);
      dy = py - (ay + dy * t);
    } else {
      dx = px - ax;
      dy = py - ay;
    }
  } else {
    dx = px - ax;
    dy = py - ay;
  }
  return dx * dx + dy * dy;
}
