// viewport_core_test.dart
//
// Self-contained test suite (no package:test dependency, so it runs anywhere a
// `dart` binary exists). Replace the tiny harness below with package:test
// imports to fold into a standard Flutter project's test/ directory.

import 'dart:typed_data';
import 'dart:math' as math;
import 'package:ultimate_pdf/engine/viewport_core.dart';

// --------------------------- minimal test harness ---------------------------

int _pass = 0;
int _fail = 0;
String _group = '';

void group(String name, void Function() body) {
  final prev = _group;
  _group = name;
  body();
  _group = prev;
}

void test(String name, void Function() body) {
  try {
    body();
    _pass++;
  } catch (e, st) {
    _fail++;
    print('  FAIL [$_group] $name');
    print('    $e');
    final firstFrame = st.toString().split('\n').firstWhere(
          (l) => l.contains('viewport_core_test.dart'),
          orElse: () => '',
        );
    if (firstFrame.isNotEmpty) print('    $firstFrame');
  }
}

void check(bool cond, [String msg = 'check failed']) {
  if (!cond) throw StateError(msg);
}

void close(double actual, double expected, double eps, [String label = '']) {
  if ((actual - expected).abs() > eps || actual.isNaN) {
    throw StateError(
        '$label expected ~$expected got $actual (|diff|=${(actual - expected).abs()}, eps=$eps)');
  }
}

void throws(void Function() body, [String label = '']) {
  var threw = false;
  try {
    body();
  } on ArgumentError {
    threw = true;
  } catch (_) {
    threw = true;
  }
  if (!threw) throw StateError('$label expected an exception, none thrown');
}

/// Round-trips a double through IEEE-754 single precision to emulate what a
/// float32 GPU/CPU path would store. Dart has no float32 scalar type, so we go
/// via ByteData.
double f32(double v) {
  final b = ByteData(4);
  b.setFloat32(0, v, Endian.little);
  return b.getFloat32(0, Endian.little);
}

// --------------------------------- tests ------------------------------------

void main() {
  group('Affine2', () {
    test('identity is a no-op', () {
      const p = Vec2(3.5, -2.25);
      final q = Affine2.identity.transform(p);
      close(q.x, p.x, 0, 'identity.x');
      close(q.y, p.y, 0, 'identity.y');
    });

    test('translation then inverse round-trips', () {
      final t = Affine2.translation(120.0, -45.0);
      final inv = t.inverse();
      check(inv != null, 'translation must be invertible');
      final round = inv!.multiply(t).transform(const Vec2(7, 9));
      close(round.x, 7, 1e-12, 'round.x');
      close(round.y, 9, 1e-12, 'round.y');
    });

    test('compose applies right-hand transform first', () {
      // scale by 2 then translate by (10,0): point (1,1) -> (2,2) -> (12,2)
      final m = Affine2.translation(10, 0).multiply(Affine2.scale(2, 2));
      final r = m.transform(const Vec2(1, 1));
      close(r.x, 12, 1e-12, 'compose.x');
      close(r.y, 2, 1e-12, 'compose.y');
    });

    test('inverse of singular transform is null', () {
      final singular = Affine2.scale(0, 5); // collapses x axis -> det 0
      check(singular.inverse() == null, 'singular inverse must be null');
    });

    test('rotation inverse round-trips a point', () {
      final r = Affine2.rotation(math.pi / 3);
      final inv = r.inverse()!;
      final p = const Vec2(2.0, -1.0);
      final back = inv.transform(r.transform(p));
      close(back.x, p.x, 1e-12, 'rot round.x');
      close(back.y, p.y, 1e-12, 'rot round.y');
    });

    test('transformInto is allocation-free and matches transform', () {
      final m = Affine2.rotation(0.4).multiply(Affine2.scale(3, 3));
      final out = Float64List(2);
      m.transformInto(1.5, -2.5, out);
      final ref = m.transform(const Vec2(1.5, -2.5));
      close(out[0], ref.x, 1e-12, 'into.x');
      close(out[1], ref.y, 1e-12, 'into.y');
    });

    test('transformAabb encloses a rotated box', () {
      // Unit box rotated 45deg about origin: half-diagonal sqrt(2)/2 ~ 0.7071.
      final r = Affine2.rotation(math.pi / 4);
      final box = const Aabb(-0.5, -0.5, 0.5, 0.5);
      final out = r.transformAabb(box);
      final half = math.sqrt(2) / 2;
      close(out.minX, -half, 1e-9, 'rotbox.minX');
      close(out.maxX, half, 1e-9, 'rotbox.maxX');
      close(out.minY, -half, 1e-9, 'rotbox.minY');
      close(out.maxY, half, 1e-9, 'rotbox.maxY');
    });
  });

  group('Aabb', () {
    test('intersects and intersectsRaw agree', () {
      const a = Aabb(0, 0, 10, 10);
      const b = Aabb(5, 5, 15, 15);
      const cBox = Aabb(20, 20, 30, 30);
      check(a.intersects(b), 'a should intersect b');
      check(!a.intersects(cBox), 'a should not intersect c');
      check(
          Aabb.intersectsRaw(0, 0, 10, 10, 5, 5, 15, 15), 'raw overlap true');
      check(!Aabb.intersectsRaw(0, 0, 10, 10, 20, 20, 30, 30),
          'raw overlap false');
    });

    test('containsPoint inclusive on edges', () {
      const a = Aabb(0, 0, 10, 10);
      check(a.containsPoint(0, 10), 'edge point inside');
      check(!a.containsPoint(10.0001, 5), 'just outside');
    });

    test('union covers both boxes', () {
      const a = Aabb(0, 0, 4, 4);
      const b = Aabb(-2, 1, 1, 8);
      final u = a.union(b);
      close(u.minX, -2, 0, 'union.minX');
      close(u.minY, 0, 0, 'union.minY');
      close(u.maxX, 4, 0, 'union.maxX');
      close(u.maxY, 8, 0, 'union.maxY');
    });

    test('inflate shrink does not invert', () {
      const a = Aabb(0, 0, 2, 10);
      final shrunk = a.inflate(-5); // x-extent only 2, shrink would invert
      check(shrunk.minX <= shrunk.maxX, 'x not inverted');
      check(shrunk.minY <= shrunk.maxY, 'y not inverted');
      close(shrunk.minX, 1, 1e-12, 'collapsed to center x');
    });

    test('fromPoints normalizes corner order', () {
      final box = Aabb.fromPoints(10, 20, 0, 5);
      close(box.minX, 0, 0);
      close(box.maxX, 10, 0);
      close(box.minY, 5, 0);
      close(box.maxY, 20, 0);
    });
  });

  group('Camera construction & validation', () {
    Camera base() => Camera(
          center: const Vec2(0, 0),
          scale: 1.0,
          viewportWidth: 1080,
          viewportHeight: 2400,
        );

    test('valid camera builds', () {
      final cam = base();
      close(cam.scale, 1.0, 0);
    });

    test('rejects non-positive scale', () {
      throws(
          () => Camera(
              center: Vec2.zero,
              scale: 0,
              viewportWidth: 100,
              viewportHeight: 100),
          'scale=0');
    });

    test('rejects non-finite center', () {
      throws(
          () => Camera(
              center: const Vec2(double.nan, 0),
              scale: 1,
              viewportWidth: 100,
              viewportHeight: 100),
          'nan center');
    });

    test('rejects non-positive viewport', () {
      throws(
          () => Camera(
              center: Vec2.zero,
              scale: 1,
              viewportWidth: 0,
              viewportHeight: 100),
          'zero width');
    });

    test('rejects scale outside bounds', () {
      throws(
          () => Camera(
              center: Vec2.zero,
              scale: 5,
              viewportWidth: 100,
              viewportHeight: 100,
              minScale: 0.1,
              maxScale: 2),
          'scale above max');
    });

    test('copyWith clamps scale into bounds', () {
      final cam = Camera(
        center: Vec2.zero,
        scale: 1,
        viewportWidth: 100,
        viewportHeight: 100,
        minScale: 0.5,
        maxScale: 4,
      );
      final z = cam.copyWith(scale: 999);
      close(z.scale, 4, 0, 'clamped to max');
    });
  });

  group('Camera coordinate mapping', () {
    test('world<->screen round-trips', () {
      final cam = Camera(
        center: const Vec2(50, 60),
        scale: 2.5,
        rotation: 0.7,
        viewportWidth: 1024,
        viewportHeight: 768,
      );
      final pts = const [Vec2(0, 0), Vec2(123, -45), Vec2(50, 60), Vec2(-9, 9)];
      for (final p in pts) {
        final s = cam.worldToScreenPoint(p.x, p.y);
        final w = cam.screenToWorldPoint(s.x, s.y);
        close(w.x, p.x, 1e-9, 'roundtrip.x for $p');
        close(w.y, p.y, 1e-9, 'roundtrip.y for $p');
      }
    });

    test('center maps to viewport centre', () {
      final cam = Camera(
        center: const Vec2(7, 11),
        scale: 3,
        rotation: 1.2,
        viewportWidth: 800,
        viewportHeight: 600,
      );
      final s = cam.worldToScreenPoint(7, 11);
      close(s.x, 400, 1e-9, 'centre.x');
      close(s.y, 300, 1e-9, 'centre.y');
    });
  });

  group('Camera gesture invariants', () {
    test('zoom holds the focal world point fixed on screen', () {
      final cam = Camera(
        center: const Vec2(10, 10),
        scale: 1.5,
        rotation: 0.3,
        viewportWidth: 1080,
        viewportHeight: 1920,
      );
      const fx = 742.0, fy = 1303.0;
      final worldUnderFocalBefore = cam.screenToWorldPoint(fx, fy);
      final zoomed = cam.zoomBy(2.0, fx, fy);
      // Same world point must now project back to the same screen focal.
      final screenOfThatWorld = zoomed.worldToScreenPoint(
          worldUnderFocalBefore.x, worldUnderFocalBefore.y);
      close(screenOfThatWorld.x, fx, 1e-7, 'zoom focal.x');
      close(screenOfThatWorld.y, fy, 1e-7, 'zoom focal.y');
      close(zoomed.scale, 3.0, 1e-12, 'zoom scale');
    });

    test('rotate holds the focal world point fixed on screen', () {
      final cam = Camera(
        center: const Vec2(-5, 22),
        scale: 4.0,
        viewportWidth: 1200,
        viewportHeight: 1200,
      );
      const fx = 300.0, fy = 950.0;
      final worldBefore = cam.screenToWorldPoint(fx, fy);
      final rotated = cam.rotateBy(math.pi / 5, fx, fy);
      final screenAfter =
          rotated.worldToScreenPoint(worldBefore.x, worldBefore.y);
      close(screenAfter.x, fx, 1e-7, 'rotate focal.x');
      close(screenAfter.y, fy, 1e-7, 'rotate focal.y');
      close(rotated.rotation, math.pi / 5, 1e-12, 'rotation applied');
    });

    test('pan moves content by exactly the screen delta', () {
      final cam = Camera(
        center: const Vec2(0, 0),
        scale: 2.0,
        rotation: 0.9,
        viewportWidth: 1000,
        viewportHeight: 1000,
      );
      // Track an arbitrary world point's screen position before/after pan.
      const wp = Vec2(13, -7);
      final before = cam.worldToScreenPoint(wp.x, wp.y);
      const dx = 35.0, dy = -18.0;
      final panned = cam.panByScreen(dx, dy);
      final after = panned.worldToScreenPoint(wp.x, wp.y);
      close(after.x - before.x, dx, 1e-7, 'pan dx');
      close(after.y - before.y, dy, 1e-7, 'pan dy');
    });

    test('zoom clamps at maxScale while keeping focal fixed', () {
      final cam = Camera(
        center: const Vec2(0, 0),
        scale: 3.0,
        viewportWidth: 800,
        viewportHeight: 800,
        minScale: 0.1,
        maxScale: 5.0,
      );
      const fx = 200.0, fy = 600.0;
      final worldBefore = cam.screenToWorldPoint(fx, fy);
      final zoomed = cam.zoomBy(100.0, fx, fy); // would be 300, clamps to 5
      close(zoomed.scale, 5.0, 1e-12, 'clamped scale');
      final after =
          zoomed.worldToScreenPoint(worldBefore.x, worldBefore.y);
      close(after.x, fx, 1e-7, 'clamped focal.x');
      close(after.y, fy, 1e-7, 'clamped focal.y');
    });

    test('NO DRIFT: 10000 mixed gestures keep the focal invariant', () {
      var cam = Camera(
        center: const Vec2(1000, 1000),
        scale: 1.0,
        viewportWidth: 1080,
        viewportHeight: 1920,
        minScale: 0.01,
        maxScale: 1e5,
      );
      final rng = math.Random(42);
      for (var i = 0; i < 10000; i++) {
        final fx = rng.nextDouble() * 1080;
        final fy = rng.nextDouble() * 1920;
        final op = i % 3;
        if (op == 0) {
          final f = 0.97 + rng.nextDouble() * 0.06; // 0.97..1.03
          cam = cam.zoomBy(f, fx, fy);
        } else if (op == 1) {
          cam = cam.panByScreen(
              (rng.nextDouble() - 0.5) * 40, (rng.nextDouble() - 0.5) * 40);
        } else {
          cam = cam.rotateBy((rng.nextDouble() - 0.5) * 0.05, fx, fy);
        }
        // Invariant that must hold exactly regardless of history: a world point
        // round-tripped through the current transform returns to itself.
        final wp = cam.screenToWorldPoint(123, 456);
        final s = cam.worldToScreenPoint(wp.x, wp.y);
        close(s.x, 123, 1e-6, 'drift roundtrip.x @op$i');
        close(s.y, 456, 1e-6, 'drift roundtrip.y @op$i');
      }
      check(cam.scale.isFinite && cam.scale > 0, 'scale stayed valid');
      check(cam.center.isFinite, 'center stayed finite');
    });
  });

  group('Camera visible bounds & tiling', () {
    test('visibleWorldBounds covers the viewport with no rotation', () {
      final cam = Camera(
        center: const Vec2(0, 0),
        scale: 2.0, // 2 px per world unit
        viewportWidth: 800, // -> 400 world units wide
        viewportHeight: 600, // -> 300 world units tall
      );
      final b = cam.visibleWorldBounds();
      close(b.minX, -200, 1e-9, 'vb.minX');
      close(b.maxX, 200, 1e-9, 'vb.maxX');
      close(b.minY, -150, 1e-9, 'vb.minY');
      close(b.maxY, 150, 1e-9, 'vb.maxY');
    });

    test('buffer enlarges visible bounds by bufferPx/scale', () {
      final cam = Camera(
        center: const Vec2(0, 0),
        scale: 2.0,
        viewportWidth: 800,
        viewportHeight: 600,
      );
      final b = cam.visibleWorldBounds(bufferPx: 100); // 50 world units
      close(b.minX, -250, 1e-9, 'buf.minX');
      close(b.maxX, 250, 1e-9, 'buf.maxX');
    });

    test('rotated visible bounds enclose all four screen corners', () {
      final cam = Camera(
        center: const Vec2(5, 5),
        scale: 3.0,
        rotation: math.pi / 6,
        viewportWidth: 900,
        viewportHeight: 1600,
      );
      final b = cam.visibleWorldBounds();
      // Every screen corner must unproject to inside the reported world bounds.
      final corners = const [
        [0.0, 0.0],
        [900.0, 0.0],
        [900.0, 1600.0],
        [0.0, 1600.0],
      ];
      for (final cnr in corners) {
        final w = cam.screenToWorldPoint(cnr[0], cnr[1]);
        check(b.containsPoint(w.x, w.y),
            'corner ${cnr} world $w must be within $b');
      }
    });

    test('rejects negative buffer', () {
      final cam = Camera(
        center: Vec2.zero,
        scale: 1,
        viewportWidth: 100,
        viewportHeight: 100,
      );
      throws(() => cam.visibleWorldBounds(bufferPx: -1), 'negative buffer');
    });
  });

  group('DEEP-ZOOM PRECISION (the headline safeguard)', () {
    // A 1:30,000-style document: large world coordinates, extreme zoom, and a
    // real (non-axis-aligned) view rotation as any CAD/GIS pan-rotate produces.
    // World offset ~1e6, scale 20 (==2000%), rotation ~20deg.
    final cam = Camera(
      center: const Vec2(1000000.0, 1000000.0),
      scale: 20.0,
      rotation: 0.35,
      viewportWidth: 1080,
      viewportHeight: 1920,
      minScale: 1e-4,
      maxScale: 1e6,
    );
    // A point a quarter-unit from a large coordinate (sub-pixel-scale detail).
    const px = 1000000.25, py = 1000000.30;

    test('double-precision world->screen->world holds sub-pixel', () {
      final s = cam.worldToScreenPoint(px, py);
      final w = cam.screenToWorldPoint(s.x, s.y);
      // Error in world units; at scale 20, 1 world unit = 20px, so sub-pixel
      // means world error < 1/20 = 0.05. We hold far tighter.
      close(w.x, px, 1e-6, 'double precision world.x');
      close(w.y, py, 1e-6, 'double precision world.y');
    });

    test('naive float32-on-large-coords DEMONSTRABLY fails (justifies rebasing)',
        () {
      // Reference screen position in full double precision.
      final ref = cam.worldToScreenPoint(px, py);
      // Emulate a float32 GPU path that narrows the affine AND the raw large
      // world coords: screen = a*X + c*Y + tx, every term through f32.
      final m = cam.worldToScreen;
      final a = f32(m.a), cc = f32(m.c), tx = f32(m.tx);
      final b = f32(m.b), dd = f32(m.d), ty = f32(m.ty);
      final fx = f32(f32(a * f32(px)) + f32(cc * f32(py)) + tx);
      final fy = f32(f32(b * f32(px)) + f32(dd * f32(py)) + ty);
      final errX = (fx - ref.x).abs();
      final errY = (fy - ref.y).abs();
      // The naive path must be visibly wrong (>> 1px) — that's the bug we avoid.
      check(errX > 1.0 || errY > 1.0,
          'expected large float32 error, got errX=$errX errY=$errY');
    });

    test('tile-local transform stays crisp even through float32', () {
      // Anchor the tile near the detail point; tile-local coords are tiny.
      const anchor = Vec2(1000000.0, 1000000.0);
      final tt = cam.tileTransform(anchor);
      // Reference (double) screen position of the detail point.
      final ref = cam.worldToScreenPoint(px, py);
      // Tile-local coordinates of the detail point (small magnitudes).
      final lx = px - anchor.x; // 0.25
      final ly = py - anchor.y; // 0.30
      // Now narrow the tile-local transform AND the small local coords to f32.
      final a = f32(tt.a), cc = f32(tt.c), tx = f32(tt.tx);
      final b = f32(tt.b), dd = f32(tt.d), ty = f32(tt.ty);
      final fx = f32(f32(a * f32(lx)) + f32(cc * f32(ly)) + tx);
      final fy = f32(f32(b * f32(lx)) + f32(dd * f32(ly)) + ty);
      // tx/ty (anchor screen pos ~ hundreds of px) limit precision to ~f32 of
      // a few-hundred value: ~3e-5 px. Comfortably sub-pixel.
      close(fx, ref.x, 0.02, 'tile-local f32 screen.x');
      close(fy, ref.y, 0.02, 'tile-local f32 screen.y');
    });
  });

  // ------------------------------- summary ----------------------------------
  print('');
  print('================ viewport_core test summary ================');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) {
    throw StateError('$_fail test(s) failed');
  }
}
