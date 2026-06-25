// lod.dart
//
// Module 5 of the viewport engine: Level-of-Detail policy.
//
// Two responsibilities:
//  1. LodPolicy maps a continuous camera scale onto a discrete tile-pyramid
//     level, so a tile rendered at that level has ~1 texel per screen pixel
//     (no GPU upscandle blur, no wasted fill). This is the bridge between the
//     camera and the tile manager.
//  2. DouglasPeucker simplifies dense polylines to a perceptual tolerance, the
//     vector-side complement to raster proxies: at low zoom, 95%+ of points can
//     be dropped with no visible change, slashing path-tessellation cost.

import 'dart:math' as math;
import 'dart:typed_data';

/// Maps camera scale (screen px per world unit) to a discrete pyramid level and
/// the world-space size of a tile at that level. Immutable / pure.
final class LodPolicy {
  /// Target on-screen tile edge length in pixels (e.g. 256 or 512). A tile at
  /// the chosen level renders at approximately this many pixels per edge.
  final double tilePixelSize;

  /// The scale at which level 0 has exactly [tilePixelSize] px == one tile of
  /// [baseTileWorldSize] world units. Levels above subdivide by powers of two.
  final double baseScale;

  /// World-units per tile edge at level 0.
  final double baseTileWorldSize;

  /// Inclusive clamp on the returned level.
  final int minLevel;
  final int maxLevel;

  LodPolicy({
    this.tilePixelSize = 512.0,
    this.baseScale = 1.0,
    required this.baseTileWorldSize,
    this.minLevel = 0,
    this.maxLevel = 24,
  }) {
    if (!(tilePixelSize > 0)) {
      throw ArgumentError.value(tilePixelSize, 'tilePixelSize', 'must be > 0');
    }
    if (!(baseScale > 0)) {
      throw ArgumentError.value(baseScale, 'baseScale', 'must be > 0');
    }
    if (!(baseTileWorldSize > 0)) {
      throw ArgumentError.value(
          baseTileWorldSize, 'baseTileWorldSize', 'must be > 0');
    }
    if (maxLevel < minLevel) {
      throw ArgumentError('maxLevel must be >= minLevel '
          '(got $minLevel..$maxLevel)');
    }
  }

  /// The pyramid level whose resolution best matches [scale]. Higher scale
  /// (deeper zoom) -> higher level -> finer tiles.
  int levelForScale(double scale) {
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and > 0');
    }
    // At level L, tile world size = baseTileWorldSize / 2^L, and we want
    // tileWorldSize * scale ~= tilePixelSize  =>  2^L ~= scale * baseTileWorldSize / tilePixelSize.
    final ratio = scale * baseTileWorldSize / tilePixelSize;
    final level = ratio <= 0 ? minLevel : (math.log(ratio) / math.ln2).round();
    return level.clamp(minLevel, maxLevel);
  }

  /// World-space edge length of one tile at [level].
  double tileWorldSize(int level) {
    final l = level.clamp(minLevel, maxLevel);
    return baseTileWorldSize / math.pow(2, l);
  }

  /// Pixel edge length to rasterize a tile at [level] for the given [scale]
  /// (kept near [tilePixelSize] by construction). Clamped to [1, maxPixels].
  int tilePixelEdge(int level, double scale, {int maxPixels = 2048}) {
    final px = (tileWorldSize(level) * scale).round();
    return px.clamp(1, maxPixels);
  }
}

/// Iterative Ramer–Douglas–Peucker polyline simplification.
abstract final class DouglasPeucker {
  /// Simplifies a flat polyline [points] (`[x0,y0,x1,y1,...]`) to [tolerance]
  /// (world units): points whose perpendicular distance from the retained
  /// segment is within tolerance are removed. Endpoints are always kept.
  ///
  /// Returns a new flat list. Throws if [points] has odd length or [tolerance]
  /// is negative/non-finite.
  static Float64List simplify(Float64List points, double tolerance) {
    if (points.length.isOdd) {
      throw ArgumentError('points length must be even (got ${points.length})');
    }
    if (!tolerance.isFinite || tolerance < 0) {
      throw ArgumentError.value(tolerance, 'tolerance', 'must be finite >= 0');
    }
    final n = points.length ~/ 2;
    if (n < 3) return Float64List.fromList(points);

    final keep = Uint8List(n);
    keep[0] = 1;
    keep[n - 1] = 1;
    final tol2 = tolerance * tolerance;

    // Explicit stack of [startIndex, endIndex] segments to process.
    final stack = <int>[0, n - 1];
    while (stack.isNotEmpty) {
      final e = stack.removeLast();
      final s = stack.removeLast();
      if (e <= s + 1) continue; // no interior points

      final ax = points[s * 2], ay = points[s * 2 + 1];
      final bx = points[e * 2], by = points[e * 2 + 1];

      var maxD2 = -1.0;
      var idx = -1;
      for (var i = s + 1; i < e; i++) {
        final d2 = _segDist2(points[i * 2], points[i * 2 + 1], ax, ay, bx, by);
        if (d2 > maxD2) {
          maxD2 = d2;
          idx = i;
        }
      }

      if (maxD2 > tol2 && idx > 0) {
        keep[idx] = 1;
        stack.add(s);
        stack.add(idx);
        stack.add(idx);
        stack.add(e);
      }
    }

    var kept = 0;
    for (var i = 0; i < n; i++) {
      if (keep[i] == 1) kept++;
    }
    final out = Float64List(kept * 2);
    var w = 0;
    for (var i = 0; i < n; i++) {
      if (keep[i] == 1) {
        out[w * 2] = points[i * 2];
        out[w * 2 + 1] = points[i * 2 + 1];
        w++;
      }
    }
    return out;
  }

  /// Squared distance from point (px,py) to segment (ax,ay)-(bx,by).
  static double _segDist2(
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
}
