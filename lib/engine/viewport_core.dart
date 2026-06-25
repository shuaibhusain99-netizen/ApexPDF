// viewport_core.dart
//
// Module 1 of the high-performance vector viewport engine.
//
// Responsibility (and ONLY this): the precise mathematical relationship between
// the three coordinate spaces of the viewport, and the camera that relates them.
//
//   World space  : the document's intrinsic coordinates (PDF user units, CAD
//                  units, GIS projected units). Stored and computed in `double`.
//   Screen space : physical viewport pixels (origin top-left, y-down).
//   View / camera: the absolute state (center-in-world, scale, rotation) from
//                  which the World<->Screen transform is *recomputed every frame*.
//
// Design contracts enforced by this module:
//
//  * SEPARATION OF SPACES. Nothing here knows about PDFs, tiles, GPUs, or
//    widgets. It is pure geometry, so it is trivially testable in isolation and
//    reusable by both the Flutter-`Canvas` rasterizer and a future native one.
//
//  * NO DRIFT. The camera is never an accumulated matrix. Every gesture produces
//    a new *absolute* camera state, and the transform is derived fresh from those
//    absolutes. Ten thousand pan/zoom deltas therefore accumulate no float error
//    (proven in the test suite's focal-invariant-after-N-ops test).
//
//  * DEEP-ZOOM PRECISION. The forward transform is built in the center-relative
//    form  screen = screenCenter + scale * R(theta) * (world - center).
//    The large world magnitudes are subtracted *in double* before scaling, so the
//    geometry handed downstream is small. For GPU tile compositing, vectors are
//    rasterized in tile-local space (small coords) and only finished tiles are
//    placed via this transform — never raw large world coords narrowed to float32.
//    The test suite demonstrates that the naive float32-on-large-coords path
//    fails while this approach holds sub-pixel at 2000% zoom and 1e6 offsets.
//
//  * ERROR POLICY. Value types (Vec2/Aabb/Affine2) sit in hot paths, so they
//    validate via `assert` (compiled out in release) and offer allocation-free
//    `*Into` variants. The Camera is the stateful boundary at gesture frequency,
//    so it validates hard: invalid transitions throw ArgumentError rather than
//    silently producing NaN state. Non-invertible transforms degrade gracefully
//    (nullable inverse) instead of crashing.

import 'dart:math' as math;
import 'dart:typed_data';

// ---------------------------------------------------------------------------
// Vec2 — immutable double-precision 2D point/vector.
// ---------------------------------------------------------------------------

/// An immutable 2D vector in double precision.
///
/// Used for the *infrequent* public surface (camera anchors, gesture focal
/// points, query results). Per-primitive hot loops should prefer the raw
/// `double`-based APIs on [Affine2] and [Aabb] to avoid allocation.
final class Vec2 {
  final double x;
  final double y;

  const Vec2(this.x, this.y);

  static const Vec2 zero = Vec2(0, 0);

  /// True iff both components are finite (neither NaN nor +/-Infinity).
  bool get isFinite => x.isFinite && y.isFinite;

  Vec2 operator +(Vec2 o) => Vec2(x + o.x, y + o.y);
  Vec2 operator -(Vec2 o) => Vec2(x - o.x, y - o.y);
  Vec2 operator *(double s) => Vec2(x * s, y * s);

  double get length => math.sqrt(x * x + y * y);

  @override
  bool operator ==(Object other) =>
      other is Vec2 && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => 'Vec2($x, $y)';
}

// ---------------------------------------------------------------------------
// Aabb — immutable axis-aligned bounding box in world (or any) space.
// ---------------------------------------------------------------------------

/// An immutable axis-aligned bounding box. Invariant: minX <= maxX, minY <= maxY.
///
/// This is the unit of currency between the camera (which produces the visible
/// world rect) and the spatial index (which is queried with it). Hot-path
/// intersection is available allocation-free via [intersectsRaw].
final class Aabb {
  final double minX;
  final double minY;
  final double maxX;
  final double maxY;

  const Aabb(this.minX, this.minY, this.maxX, this.maxY)
      : assert(minX <= maxX, 'Aabb requires minX <= maxX'),
        assert(minY <= maxY, 'Aabb requires minY <= maxY');

  /// Builds an [Aabb] from two arbitrary corners, normalizing their order.
  factory Aabb.fromPoints(double ax, double ay, double bx, double by) {
    return Aabb(
      ax < bx ? ax : bx,
      ay < by ? ay : by,
      ax > bx ? ax : bx,
      ay > by ? ay : by,
    );
  }

  double get width => maxX - minX;
  double get height => maxY - minY;
  double get area => (maxX - minX) * (maxY - minY);
  double get centerX => (minX + maxX) * 0.5;
  double get centerY => (minY + maxY) * 0.5;

  bool get isFinite =>
      minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite;

  /// True iff this box overlaps [o] (touching edges count as overlap).
  bool intersects(Aabb o) =>
      minX <= o.maxX && o.minX <= maxX && minY <= o.maxY && o.minY <= maxY;

  /// Allocation-free overlap test for the culling hot loop. Returns true iff
  /// box A (first four args) overlaps box B (last four args).
  static bool intersectsRaw(
    double aMinX,
    double aMinY,
    double aMaxX,
    double aMaxY,
    double bMinX,
    double bMinY,
    double bMaxX,
    double bMaxY,
  ) =>
      aMinX <= bMaxX && bMinX <= aMaxX && aMinY <= bMaxY && bMinY <= aMaxY;

  /// True iff point (px, py) lies within this box (inclusive).
  bool containsPoint(double px, double py) =>
      px >= minX && px <= maxX && py >= minY && py <= maxY;

  /// The smallest box containing both this and [o].
  Aabb union(Aabb o) => Aabb(
        minX < o.minX ? minX : o.minX,
        minY < o.minY ? minY : o.minY,
        maxX > o.maxX ? maxX : o.maxX,
        maxY > o.maxY ? maxY : o.maxY,
      );

  /// Expands the box by [margin] on every side (negative shrinks). The result
  /// is clamped so it never inverts: a shrink larger than half an extent
  /// collapses that axis to its center rather than producing minX > maxX.
  Aabb inflate(double margin) {
    var nMinX = minX - margin;
    var nMaxX = maxX + margin;
    var nMinY = minY - margin;
    var nMaxY = maxY + margin;
    if (nMinX > nMaxX) {
      final c = (nMinX + nMaxX) * 0.5;
      nMinX = c;
      nMaxX = c;
    }
    if (nMinY > nMaxY) {
      final c = (nMinY + nMaxY) * 0.5;
      nMinY = c;
      nMaxY = c;
    }
    return Aabb(nMinX, nMinY, nMaxX, nMaxY);
  }

  @override
  bool operator ==(Object other) =>
      other is Aabb &&
      other.minX == minX &&
      other.minY == minY &&
      other.maxX == maxX &&
      other.maxY == maxY;

  @override
  int get hashCode => Object.hash(minX, minY, maxX, maxY);

  @override
  String toString() => 'Aabb($minX, $minY, $maxX, $maxY)';
}

// ---------------------------------------------------------------------------
// Affine2 — immutable 2x3 affine transform in double precision.
// ---------------------------------------------------------------------------

/// An immutable 2D affine transform in double precision, mapping
///   x' = a*x + c*y + tx
///   y' = b*x + d*y + ty
/// i.e. the matrix
///   | a  c  tx |
///   | b  d  ty |
///   | 0  0   1 |
///
/// Deliberately NOT backed by `Matrix4` / vector_math: a purpose-built 2x3 keeps
/// the arithmetic, the precision behaviour, and the zero-allocation transform
/// path fully under our control.
final class Affine2 {
  final double a;
  final double b;
  final double c;
  final double d;
  final double tx;
  final double ty;

  const Affine2(this.a, this.b, this.c, this.d, this.tx, this.ty);

  static const Affine2 identity = Affine2(1, 0, 0, 1, 0, 0);

  factory Affine2.translation(double tx, double ty) =>
      Affine2(1, 0, 0, 1, tx, ty);

  factory Affine2.scale(double sx, double sy) => Affine2(sx, 0, 0, sy, 0, 0);

  factory Affine2.rotation(double radians) {
    final cosR = math.cos(radians);
    final sinR = math.sin(radians);
    return Affine2(cosR, sinR, -sinR, cosR, 0, 0);
  }

  /// The signed determinant of the 2x2 linear part. Zero (within epsilon) means
  /// the transform is singular and has no inverse.
  double get determinant => a * d - b * c;

  /// Returns `this * other` (apply [other] first, then this), or in matrix terms
  /// the product of the two 3x3 matrices.
  Affine2 multiply(Affine2 o) => Affine2(
        a * o.a + c * o.b,
        b * o.a + d * o.b,
        a * o.c + c * o.d,
        b * o.c + d * o.d,
        a * o.tx + c * o.ty + tx,
        b * o.tx + d * o.ty + ty,
      );

  /// Transforms a single point, allocating a [Vec2]. Convenience for the
  /// infrequent public surface; prefer [transformInto] in hot loops.
  Vec2 transform(Vec2 p) => Vec2(
        a * p.x + c * p.y + tx,
        b * p.x + d * p.y + ty,
      );

  /// Allocation-free point transform. Writes (x', y') into [out] at [offset] and
  /// [offset]+1. The single permitted shape for the per-primitive hot path.
  void transformInto(double x, double y, Float64List out, [int offset = 0]) {
    out[offset] = a * x + c * y + tx;
    out[offset + 1] = b * x + d * y + ty;
  }

  /// Transforms an axis-aligned box and returns the *enclosing* axis-aligned box
  /// of the (possibly rotated) result. Necessary because under rotation the four
  /// transformed corners are not themselves axis-aligned.
  Aabb transformAabb(Aabb box) {
    final x0 = box.minX, y0 = box.minY, x1 = box.maxX, y1 = box.maxY;
    // Four transformed corners.
    final cx0 = a * x0 + c * y0 + tx, cy0 = b * x0 + d * y0 + ty;
    final cx1 = a * x1 + c * y0 + tx, cy1 = b * x1 + d * y0 + ty;
    final cx2 = a * x1 + c * y1 + tx, cy2 = b * x1 + d * y1 + ty;
    final cx3 = a * x0 + c * y1 + tx, cy3 = b * x0 + d * y1 + ty;
    final minX = _min4(cx0, cx1, cx2, cx3);
    final maxX = _max4(cx0, cx1, cx2, cx3);
    final minY = _min4(cy0, cy1, cy2, cy3);
    final maxY = _max4(cy0, cy1, cy2, cy3);
    return Aabb(minX, minY, maxX, maxY);
  }

  /// The inverse transform, or `null` if singular (|det| below [epsilon]).
  /// Returning null rather than throwing lets callers degrade gracefully; in
  /// practice a valid [Camera] can never produce a singular transform because it
  /// forbids non-positive scale.
  Affine2? inverse({double epsilon = 1e-12}) {
    final det = a * d - b * c;
    if (det.abs() < epsilon || !det.isFinite) return null;
    final invDet = 1.0 / det;
    final ia = d * invDet;
    final ib = -b * invDet;
    final ic = -c * invDet;
    final id = a * invDet;
    // -M^-1 * t
    final itx = -(ia * tx + ic * ty);
    final ity = -(ib * tx + id * ty);
    return Affine2(ia, ib, ic, id, itx, ity);
  }

  /// True iff every component is finite.
  bool get isFinite =>
      a.isFinite &&
      b.isFinite &&
      c.isFinite &&
      d.isFinite &&
      tx.isFinite &&
      ty.isFinite;

  /// Emits a column-major 4x4 [Float64List] suitable for Flutter's
  /// `Canvas.transform`, embedding this 2D affine in the z=0 plane. Flutter's
  /// canvas transform is itself double precision, so no precision is lost at this
  /// boundary.
  Float64List toCanvasMatrix4() {
    final m = Float64List(16);
    m[0] = a;
    m[1] = b;
    m[4] = c;
    m[5] = d;
    m[10] = 1.0;
    m[12] = tx;
    m[13] = ty;
    m[15] = 1.0;
    return m;
  }

  @override
  String toString() => 'Affine2(a:$a b:$b c:$c d:$d tx:$tx ty:$ty)';
}

double _min4(double a, double b, double c, double d) {
  var m = a;
  if (b < m) m = b;
  if (c < m) m = c;
  if (d < m) m = d;
  return m;
}

double _max4(double a, double b, double c, double d) {
  var m = a;
  if (b > m) m = b;
  if (c > m) m = c;
  if (d > m) m = d;
  return m;
}

// ---------------------------------------------------------------------------
// Camera — the single source of truth for the view state.
// ---------------------------------------------------------------------------

/// The viewport camera: the absolute, authoritative view state from which the
/// World<->Screen transform is derived on demand.
///
/// State is held as three absolutes — [center] (a world point), [scale]
/// (screen pixels per world unit), and [rotation] (radians, CCW) — plus the
/// [viewportWidth]/[viewportHeight] of the screen frame. Gestures return a *new*
/// camera computed from these absolutes; nothing is accumulated, so there is no
/// long-run float drift.
///
/// Transform convention (center-relative, the deep-zoom precision safeguard):
///
///   screen = screenCenter + scale * R(rotation) * (world - center)
///
/// All construction and transition inputs are validated; invalid input throws
/// [ArgumentError] rather than producing a NaN camera.
final class Camera {
  /// World-space point currently mapped to the centre of the viewport.
  final Vec2 center;

  /// Screen pixels per world unit. Always strictly within [minScale]..[maxScale].
  final double scale;

  /// View rotation in radians (counter-clockwise).
  final double rotation;

  /// Viewport width in physical pixels (> 0).
  final double viewportWidth;

  /// Viewport height in physical pixels (> 0).
  final double viewportHeight;

  /// Hard lower bound on [scale] (> 0).
  final double minScale;

  /// Hard upper bound on [scale] (>= [minScale]).
  final double maxScale;

  Camera._({
    required this.center,
    required this.scale,
    required this.rotation,
    required this.viewportWidth,
    required this.viewportHeight,
    required this.minScale,
    required this.maxScale,
  });

  /// Creates a validated camera. Throws [ArgumentError] if any input is
  /// non-finite, if the viewport is non-positive, if the scale bounds are
  /// invalid, or if [scale] lies outside [minScale]..[maxScale].
  factory Camera({
    required Vec2 center,
    required double scale,
    double rotation = 0.0,
    required double viewportWidth,
    required double viewportHeight,
    double minScale = 1e-6,
    double maxScale = 1e6,
  }) {
    if (!center.isFinite) {
      throw ArgumentError.value(center, 'center', 'must be finite');
    }
    if (!scale.isFinite || scale <= 0) {
      throw ArgumentError.value(scale, 'scale', 'must be finite and > 0');
    }
    if (!rotation.isFinite) {
      throw ArgumentError.value(rotation, 'rotation', 'must be finite');
    }
    if (!(viewportWidth > 0) || !(viewportHeight > 0)) {
      throw ArgumentError(
          'viewport must be positive (got ${viewportWidth}x$viewportHeight)');
    }
    if (!(minScale > 0) || !(maxScale >= minScale)) {
      throw ArgumentError('require 0 < minScale <= maxScale '
          '(got minScale=$minScale maxScale=$maxScale)');
    }
    if (scale < minScale || scale > maxScale) {
      throw ArgumentError.value(
          scale, 'scale', 'must be within [$minScale, $maxScale]');
    }
    return Camera._(
      center: center,
      scale: scale,
      rotation: rotation,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      minScale: minScale,
      maxScale: maxScale,
    );
  }

  double get _screenCenterX => viewportWidth * 0.5;
  double get _screenCenterY => viewportHeight * 0.5;

  /// The world->screen transform, derived fresh from the absolute state.
  ///
  /// Built in center-relative form so the (large) world coordinates are reduced
  /// by [center] inside the `tx`/`ty` terms. In double this cancellation is
  /// exact to ~15 significant digits; the same expression in float32 is the
  /// classic deep-zoom jitter bug, which is why GPU geometry must be expressed
  /// tile-locally (see [tileTransform]) rather than via raw world coords.
  Affine2 get worldToScreen {
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final a = scale * cosR;
    final b = scale * sinR;
    final c = -scale * sinR;
    final d = scale * cosR;
    final tx = _screenCenterX - (a * center.x + c * center.y);
    final ty = _screenCenterY - (b * center.x + d * center.y);
    return Affine2(a, b, c, d, tx, ty);
  }

  /// The screen->world transform. Never null for a valid camera (scale > 0
  /// guarantees a non-singular linear part); the `!` is therefore safe.
  Affine2 get screenToWorld => worldToScreen.inverse()!;

  /// Maps a screen point to world space.
  Vec2 screenToWorldPoint(double sx, double sy) =>
      screenToWorld.transform(Vec2(sx, sy));

  /// Maps a world point to screen space.
  Vec2 worldToScreenPoint(double wx, double wy) =>
      worldToScreen.transform(Vec2(wx, wy));

  /// Returns a copy with selected fields replaced, re-validating and clamping the
  /// scale into bounds. Used for viewport resize (world center preserved) and
  /// programmatic camera moves.
  Camera copyWith({
    Vec2? center,
    double? scale,
    double? rotation,
    double? viewportWidth,
    double? viewportHeight,
    double? minScale,
    double? maxScale,
  }) {
    final newMin = minScale ?? this.minScale;
    final newMax = maxScale ?? this.maxScale;
    final requestedScale = scale ?? this.scale;
    final clampedScale = requestedScale.clamp(newMin, newMax).toDouble();
    return Camera(
      center: center ?? this.center,
      scale: clampedScale,
      rotation: rotation ?? this.rotation,
      viewportWidth: viewportWidth ?? this.viewportWidth,
      viewportHeight: viewportHeight ?? this.viewportHeight,
      minScale: newMin,
      maxScale: newMax,
    );
  }

  /// Updates the viewport frame (e.g. on rotation or window resize) while keeping
  /// the same world point under the viewport centre.
  Camera resize(double width, double height) =>
      copyWith(viewportWidth: width, viewportHeight: height);

  /// Pans the view by a screen-space delta so that content follows the gesture:
  /// dragging by (dxScreen, dyScreen) moves the content by the same screen
  /// vector. Computed from absolutes, so repeated panning never drifts.
  Camera panByScreen(double dxScreen, double dyScreen) {
    if (!dxScreen.isFinite || !dyScreen.isFinite) {
      throw ArgumentError('pan delta must be finite '
          '(got $dxScreen, $dyScreen)');
    }
    // center' = center - (1/scale) * R(-theta) * delta
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final invS = 1.0 / scale;
    // R(-theta) * (dx, dy)
    final rx = cosR * dxScreen + sinR * dyScreen;
    final ry = -sinR * dxScreen + cosR * dyScreen;
    final newCenter = Vec2(center.x - invS * rx, center.y - invS * ry);
    return copyWith(center: newCenter);
  }

  /// Zooms by [factor] about the screen-space focal point (focalX, focalY),
  /// holding the world point under that focal fixed. [factor] > 1 zooms in.
  /// The resulting scale is clamped to [minScale]..[maxScale]; when clamping
  /// engages, the focal point remains exactly fixed at the clamped scale.
  Camera zoomBy(double factor, double focalX, double focalY) {
    if (!factor.isFinite || factor <= 0) {
      throw ArgumentError.value(factor, 'factor', 'must be finite and > 0');
    }
    if (!focalX.isFinite || !focalY.isFinite) {
      throw ArgumentError('focal point must be finite '
          '(got $focalX, $focalY)');
    }
    final newScale = (scale * factor).clamp(minScale, maxScale).toDouble();
    // World point under the focal at the CURRENT transform.
    final pw = screenToWorldPoint(focalX, focalY);
    // center' = pw - (1/newScale) * R(-theta) * (focal - screenCenter)
    final dx = focalX - _screenCenterX;
    final dy = focalY - _screenCenterY;
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final invS = 1.0 / newScale;
    final rx = cosR * dx + sinR * dy;
    final ry = -sinR * dx + cosR * dy;
    final newCenter = Vec2(pw.x - invS * rx, pw.y - invS * ry);
    return Camera(
      center: newCenter,
      scale: newScale,
      rotation: rotation,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      minScale: minScale,
      maxScale: maxScale,
    );
  }

  /// Rotates the view by [deltaRadians] about the screen-space focal point,
  /// holding the world point under that focal fixed. Scale is unchanged.
  Camera rotateBy(double deltaRadians, double focalX, double focalY) {
    if (!deltaRadians.isFinite) {
      throw ArgumentError.value(deltaRadians, 'deltaRadians', 'must be finite');
    }
    if (!focalX.isFinite || !focalY.isFinite) {
      throw ArgumentError('focal point must be finite '
          '(got $focalX, $focalY)');
    }
    final pw = screenToWorldPoint(focalX, focalY);
    final newRotation = rotation + deltaRadians;
    final dx = focalX - _screenCenterX;
    final dy = focalY - _screenCenterY;
    final cosR = math.cos(newRotation);
    final sinR = math.sin(newRotation);
    final invS = 1.0 / scale;
    // center' = pw - (1/scale) * R(-newRotation) * (focal - screenCenter)
    final rx = cosR * dx + sinR * dy;
    final ry = -sinR * dx + cosR * dy;
    final newCenter = Vec2(pw.x - invS * rx, pw.y - invS * ry);
    return Camera(
      center: newCenter,
      scale: scale,
      rotation: newRotation,
      viewportWidth: viewportWidth,
      viewportHeight: viewportHeight,
      minScale: minScale,
      maxScale: maxScale,
    );
  }

  /// The world-space axis-aligned bounds currently visible, expanded by
  /// [bufferPx] screen pixels on every side. This is the query rectangle handed
  /// to the spatial index for viewport culling; [bufferPx] provides the
  /// pre-render ring so panning reveals already-prepared content. Correctly
  /// accounts for rotation by unprojecting the (buffered) screen corners.
  Aabb visibleWorldBounds({double bufferPx = 0.0}) {
    if (!bufferPx.isFinite || bufferPx < 0) {
      throw ArgumentError.value(bufferPx, 'bufferPx', 'must be finite and >= 0');
    }
    final s2w = screenToWorld;
    final left = -bufferPx;
    final top = -bufferPx;
    final right = viewportWidth + bufferPx;
    final bottom = viewportHeight + bufferPx;
    // Unproject the four (buffered) screen corners.
    final c0 = s2w.transform(Vec2(left, top));
    final c1 = s2w.transform(Vec2(right, top));
    final c2 = s2w.transform(Vec2(right, bottom));
    final c3 = s2w.transform(Vec2(left, bottom));
    return Aabb(
      _min4(c0.x, c1.x, c2.x, c3.x),
      _min4(c0.y, c1.y, c2.y, c3.y),
      _max4(c0.x, c1.x, c2.x, c3.x),
      _max4(c0.y, c1.y, c2.y, c3.y),
    );
  }

  /// Builds a transform for rendering content in a tile whose world-space origin
  /// is [anchorWorld]. The returned affine maps *tile-local* coordinates
  /// (relative to the anchor) to screen space. Because the large world magnitude
  /// is removed (in double) by [anchorWorld], the resulting `tx`/`ty` are small
  /// and the transform is safe to narrow to float32 for the GPU — the mechanism
  /// that preserves crispness at extreme zoom.
  Affine2 tileTransform(Vec2 anchorWorld) {
    final cosR = math.cos(rotation);
    final sinR = math.sin(rotation);
    final a = scale * cosR;
    final b = scale * sinR;
    final c = -scale * sinR;
    final d = scale * cosR;
    // Screen position of the anchor itself (computed in full double precision).
    final anchorScreen = worldToScreenPoint(anchorWorld.x, anchorWorld.y);
    // tile-local (0,0) must land on the anchor's screen position; the linear
    // part (a,b,c,d) is small-magnitude (scale*rotation only).
    return Affine2(a, b, c, d, anchorScreen.x, anchorScreen.y);
  }

  @override
  String toString() =>
      'Camera(center:$center scale:$scale rot:$rotation '
      'viewport:${viewportWidth}x$viewportHeight)';
}
