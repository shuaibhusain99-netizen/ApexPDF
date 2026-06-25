// engine_test.dart
//
// Self-contained suite (no package:test) for modules 2-6. Supports async tests
// for the tile scheduler.

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/engine/spatial_index.dart';
import 'package:ultimate_pdf/engine/lod.dart';
import 'package:ultimate_pdf/engine/tile.dart';

// --------------------------- minimal harness --------------------------------

int _pass = 0;
int _fail = 0;
String _group = '';

Future<void> group(String name, FutureOr<void> Function() body) async {
  final prev = _group;
  _group = name;
  await body();
  _group = prev;
}

void test(String name, void Function() body) {
  try {
    body();
    _pass++;
  } catch (e, st) {
    _fail++;
    print('  FAIL [$_group] $name\n    $e');
    _printFrame(st);
  }
}

Future<void> testAsync(String name, Future<void> Function() body) async {
  try {
    await body();
    _pass++;
  } catch (e, st) {
    _fail++;
    print('  FAIL [$_group] $name\n    $e');
    _printFrame(st);
  }
}

void _printFrame(StackTrace st) {
  final f = st.toString().split('\n').firstWhere(
        (l) => l.contains('engine_test.dart'),
        orElse: () => '',
      );
  if (f.isNotEmpty) print('    $f');
}

void check(bool cond, [String msg = 'check failed']) {
  if (!cond) throw StateError(msg);
}

void eq(Object? a, Object? b, [String label = '']) {
  if (a is List && b is List) {
    var same = a.length == b.length;
    if (same) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) {
          same = false;
          break;
        }
      }
    }
    if (!same) throw StateError('$label expected $b got $a');
    return;
  }
  if (a != b) throw StateError('$label expected $b got $a');
}

void close(double actual, double expected, double eps, [String label = '']) {
  if ((actual - expected).abs() > eps || actual.isNaN) {
    throw StateError('$label expected ~$expected got $actual');
  }
}

void throws(void Function() body, [String label = '']) {
  var threw = false;
  try {
    body();
  } catch (_) {
    threw = true;
  }
  if (!threw) throw StateError('$label expected exception');
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

// ------------------------------ tests ---------------------------------------

Future<void> main() async {
  await group('RTree', () {
    test('empty tree yields nothing', () {
      final t = RTreeBuilder().build();
      check(t.isEmpty, 'should be empty');
      var hits = 0;
      t.query(-1e9, -1e9, 1e9, 1e9, (id) {
        hits++;
        return true;
      });
      eq(hits, 0, 'empty hits');
    });

    test('single item hit and miss', () {
      final b = RTreeBuilder();
      b.add(0, 0, 10, 10);
      final t = b.build();
      eq(t.queryBox(const Aabb(5, 5, 6, 6)), [0], 'inside');
      eq(t.queryBox(const Aabb(20, 20, 30, 30)), <int>[], 'outside');
    });

    test('rejects invalid box', () {
      throws(() => RTreeBuilder().add(10, 0, 0, 10), 'min>max');
      throws(() => RTreeBuilder().add(double.nan, 0, 1, 1), 'nan');
    });

    test('BRUTE-FORCE EQUIVALENCE over random data', () {
      final rng = math.Random(7);
      const n = 5000;
      final bx = Float64List(n);
      final by = Float64List(n);
      final bX = Float64List(n);
      final bY = Float64List(n);
      final builder = RTreeBuilder(nodeSize: 16);
      for (var i = 0; i < n; i++) {
        final x = rng.nextDouble() * 10000 - 5000;
        final y = rng.nextDouble() * 10000 - 5000;
        final w = rng.nextDouble() * 50;
        final h = rng.nextDouble() * 50;
        bx[i] = x;
        by[i] = y;
        bX[i] = x + w;
        bY[i] = y + h;
        builder.add(x, y, x + w, y + h);
      }
      final tree = builder.build();

      for (var q = 0; q < 300; q++) {
        final qx = rng.nextDouble() * 12000 - 6000;
        final qy = rng.nextDouble() * 12000 - 6000;
        final qw = rng.nextDouble() * 800;
        final qh = rng.nextDouble() * 800;
        final qMinX = qx, qMinY = qy, qMaxX = qx + qw, qMaxY = qy + qh;

        // Brute force reference.
        final expected = <int>{};
        for (var i = 0; i < n; i++) {
          if (qMinX <= bX[i] &&
              bx[i] <= qMaxX &&
              qMinY <= bY[i] &&
              by[i] <= qMaxY) {
            expected.add(i);
          }
        }
        final got = <int>{};
        tree.query(qMinX, qMinY, qMaxX, qMaxY, (id) {
          got.add(id);
          return true;
        });
        check(got.length == expected.length && got.containsAll(expected),
            'query $q mismatch: tree=${got.length} brute=${expected.length}');
      }
    });

    test('early-stop visitor halts traversal', () {
      final b = RTreeBuilder();
      for (var i = 0; i < 100; i++) {
        b.add(i.toDouble(), 0, i + 1.0, 1);
      }
      final t = b.build();
      var count = 0;
      t.query(-1, -1, 1000, 1000, (id) {
        count++;
        return count < 3; // stop after 3
      });
      eq(count, 3, 'early stop count');
    });
  });

  await group('DouglasPeucker', () {
    test('collinear points reduce to endpoints', () {
      final pts = Float64List.fromList([0, 0, 1, 0, 2, 0, 3, 0, 4, 0]);
      final s = DouglasPeucker.simplify(pts, 0.001);
      eq(s.length, 4, 'kept count*2');
      close(s[0], 0, 0);
      close(s[2], 4, 0);
    });

    test('a spike is preserved', () {
      // flat line with one tall spike in the middle
      final pts = Float64List.fromList([0, 0, 1, 0, 2, 10, 3, 0, 4, 0]);
      final s = DouglasPeucker.simplify(pts, 1.0);
      // endpoints + the spike vertex => 3 points => length 6
      eq(s.length, 6, 'spike retained');
      close(s[2], 2, 0, 'spike x');
      close(s[3], 10, 0, 'spike y');
    });

    test('rejects odd-length input', () {
      throws(() => DouglasPeucker.simplify(Float64List.fromList([0, 0, 1]), 1),
          'odd length');
    });

    test('massive collinear polyline collapses (LOD payoff)', () {
      final n = 2000;
      final pts = Float64List(n * 2);
      for (var i = 0; i < n; i++) {
        pts[i * 2] = i.toDouble();
        pts[i * 2 + 1] = 0.0; // perfectly straight
      }
      final s = DouglasPeucker.simplify(pts, 0.5);
      eq(s.length, 4, '2000 points -> 2 endpoints');
    });
  });

  await group('LodPolicy', () {
    final lod = LodPolicy(
      tilePixelSize: 256,
      baseScale: 1,
      baseTileWorldSize: 256,
      minLevel: 0,
      maxLevel: 20,
    );

    test('level rises with scale', () {
      final l1 = lod.levelForScale(1.0);
      final l2 = lod.levelForScale(4.0);
      final l3 = lod.levelForScale(64.0);
      check(l2 > l1, 'higher scale -> higher level ($l1 < $l2)');
      check(l3 > l2, 'still higher ($l2 < $l3)');
    });

    test('tile world size halves per level', () {
      close(lod.tileWorldSize(1), lod.tileWorldSize(0) / 2, 1e-9);
      close(lod.tileWorldSize(3), lod.tileWorldSize(0) / 8, 1e-9);
    });

    test('level clamps to bounds', () {
      eq(lod.levelForScale(1e-9), 0, 'clamp low');
      eq(lod.levelForScale(1e18), 20, 'clamp high');
    });

    test('pixel edge stays near target', () {
      final lvl = lod.levelForScale(10.0);
      final px = lod.tilePixelEdge(lvl, 10.0);
      check(px >= 128 && px <= 512, 'pixel edge $px near 256');
    });

    test('rejects bad scale', () {
      throws(() => lod.levelForScale(0), 'zero scale');
    });
  });

  await group('TileCache LRU', () {
    test('evicts LRU and disposes when over ceiling', () {
      final disposed = <TileKey>[];
      final cache = TileCache<int>(
        maxBytes: 300,
        sizeOf: (_) => 100,
        dispose: (v) => disposed.add(TileKey(0, v, 0)),
      );
      cache.put(const TileKey(0, 1, 0), 1);
      cache.put(const TileKey(0, 2, 0), 2);
      cache.put(const TileKey(0, 3, 0), 3); // bytes = 300, at ceiling
      eq(cache.length, 3, 'three fit');
      eq(cache.currentBytes, 300, 'bytes accounting');

      // Touch key 1 so it becomes MRU; key 2 is now LRU.
      cache.get(const TileKey(0, 1, 0));
      cache.put(const TileKey(0, 4, 0), 4); // forces one eviction
      check(!cache.contains(const TileKey(0, 2, 0)), 'LRU (key2) evicted');
      check(cache.contains(const TileKey(0, 1, 0)), 'touched key1 survived');
      eq(disposed.length, 1, 'one disposed');
      eq(disposed.first.x, 2, 'disposed the LRU value');
    });

    test('value larger than ceiling is disposed, not stored', () {
      final disposed = <int>[];
      final cache = TileCache<int>(
        maxBytes: 50,
        sizeOf: (_) => 100,
        dispose: disposed.add,
      );
      cache.put(const TileKey(0, 0, 0), 9);
      eq(cache.length, 0, 'not stored');
      eq(disposed, [9], 'disposed immediately');
    });

    test('replacing a key disposes the old value', () {
      final disposed = <int>[];
      final cache = TileCache<int>(
        maxBytes: 1000,
        sizeOf: (_) => 10,
        dispose: disposed.add,
      );
      cache.put(const TileKey(0, 0, 0), 1);
      cache.put(const TileKey(0, 0, 0), 2);
      eq(disposed, [1], 'old value disposed');
      eq(cache.get(const TileKey(0, 0, 0)), 2, 'new value present');
    });
  });

  await group('TileManager scheduling & cancellation', () async {
    LodPolicy makeLod() => LodPolicy(
          tilePixelSize: 256,
          baseScale: 1,
          baseTileWorldSize: 256,
          minLevel: 0,
          maxLevel: 20,
        );

    Camera makeCam(double cx, double cy) => Camera(
          center: Vec2(cx, cy),
          scale: 1.0,
          viewportWidth: 512,
          viewportHeight: 512,
          minScale: 1e-3,
          maxScale: 1e4,
        );

    await testAsync('schedules needed tiles then caches on completion',
        () async {
      final raster = _ControlledRasterizer();
      var readyCalls = 0;
      final mgr = TileManager<_FakeTile>(
        rasterizer: raster,
        cache: TileCache<_FakeTile>(
          maxBytes: 100 * 1024 * 1024,
          sizeOf: (t) => t.bytes,
          dispose: (t) => t.disposed = true,
        ),
        lod: makeLod(),
        bufferPx: 0,
        onTileReady: () => readyCalls++,
      );

      mgr.update(makeCam(0, 0));
      check(mgr.inflightCount > 0, 'tiles scheduled');
      final scheduled = raster.tokens.keys.toList();
      check(scheduled.isNotEmpty, 'rasterizer received requests');

      // Complete one tile.
      final k = scheduled.first;
      raster.complete(k, _FakeTile(64 * 1024));
      await pump();

      check(mgr.cache.contains(k), 'completed tile cached');
      check(readyCalls >= 1, 'onTileReady fired');
      mgr.dispose();
    });

    await testAsync('cancels obsolete in-flight tiles on viewport jump',
        () async {
      final raster = _ControlledRasterizer();
      final mgr = TileManager<_FakeTile>(
        rasterizer: raster,
        cache: TileCache<_FakeTile>(
          maxBytes: 100 * 1024 * 1024,
          sizeOf: (t) => t.bytes,
          dispose: (t) => t.disposed = true,
        ),
        lod: makeLod(),
        bufferPx: 0,
      );

      mgr.update(makeCam(0, 0));
      final firstBatch = raster.tokens.keys.toList();
      check(firstBatch.isNotEmpty, 'first batch scheduled');
      final sampleToken = raster.tokens[firstBatch.first]!;
      check(!sampleToken.isCancelled, 'not cancelled yet');

      // Jump far away: the original tiles are no longer needed.
      mgr.update(makeCam(100000, 100000));
      check(sampleToken.isCancelled, 'obsolete tile cancelled');
      mgr.dispose();
    });

    await testAsync('completing a cancelled tile disposes it (no cache leak)',
        () async {
      final raster = _ControlledRasterizer();
      final mgr = TileManager<_FakeTile>(
        rasterizer: raster,
        cache: TileCache<_FakeTile>(
          maxBytes: 100 * 1024 * 1024,
          sizeOf: (t) => t.bytes,
          dispose: (t) => t.disposed = true,
        ),
        lod: makeLod(),
        bufferPx: 0,
      );
      mgr.update(makeCam(0, 0));
      final k = raster.tokens.keys.first;
      mgr.update(makeCam(100000, 100000)); // cancels k
      final tile = _FakeTile(1024);
      raster.complete(k, tile); // late completion of a cancelled tile
      await pump();
      check(!mgr.cache.contains(k), 'cancelled tile not cached');
      check(tile.disposed, 'late tile disposed');
      mgr.dispose();
    });

    await testAsync('graceful degradation: coarse ancestor drawn until fine ready',
        () async {
      final raster = _ControlledRasterizer();
      final mgr = TileManager<_FakeTile>(
        rasterizer: raster,
        cache: TileCache<_FakeTile>(
          maxBytes: 100 * 1024 * 1024,
          sizeOf: (t) => t.bytes,
          dispose: (t) => t.disposed = true,
        ),
        lod: makeLod(),
        bufferPx: 0,
      );

      // Seed a coarse (low-level) tile covering the origin.
      final coarseLevel = makeLod().levelForScale(1.0);
      final coarseKey = TileKey(coarseLevel, 0, 0);
      mgr.cache.put(coarseKey, _FakeTile(1024));

      // Now view at deeper zoom (finer level) where fine tiles are NOT ready.
      final deepCam = Camera(
        center: const Vec2(10, 10),
        scale: 8.0, // deeper -> higher level than coarseLevel
        viewportWidth: 512,
        viewportHeight: 512,
        minScale: 1e-3,
        maxScale: 1e4,
      );
      final draw = mgr.collectDrawTiles(deepCam);
      // The only cached tile is the coarse ancestor; degradation should surface
      // it rather than returning nothing.
      check(draw.isNotEmpty, 'coarse ancestor drawn as fallback');
      check(draw.any((r) => r.key == coarseKey),
          'fallback used the seeded coarse tile');
      mgr.dispose();
    });
  });

  // ------------------------------ summary -----------------------------------
  print('');
  print('================ engine (modules 2-6) test summary =========');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}

// ------------------------------ fakes ---------------------------------------

final class _FakeTile {
  final int bytes;
  bool disposed = false;
  _FakeTile(this.bytes);
}

/// A rasterizer whose completions are driven manually by the test.
final class _ControlledRasterizer implements TileRasterizer<_FakeTile> {
  final Map<TileKey, Completer<_FakeTile>> completers =
      <TileKey, Completer<_FakeTile>>{};
  final Map<TileKey, CancellationToken> tokens =
      <TileKey, CancellationToken>{};

  @override
  Future<_FakeTile> rasterize(
      TileRenderRequest request, CancellationToken token) {
    tokens[request.key] = token;
    final c = Completer<_FakeTile>();
    completers[request.key] = c;
    return c.future;
  }

  void complete(TileKey key, _FakeTile tile) {
    final c = completers[key];
    if (c != null && !c.isCompleted) c.complete(tile);
  }
}
