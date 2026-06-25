// tile.dart
//
// Modules 3, 4 and 6 of the viewport engine, tied together:
//
//   ViewportCuller (3) : Camera + RTree -> the ids of primitives in view.
//   Tile addressing /
//   TileCache /
//   TileManager   (4) : a tile pyramid, an LRU cache under a hard byte ceiling,
//                       and the scheduler that requests missing tiles, cancels
//                       obsolete in-flight work, evicts, and degrades gracefully
//                       to a coarser cached level so the screen is never blank.
//   TileRasterizer (6) : the abstract seam. The pure engine never rasterizes
//                       pixels itself; a Flutter/pdfrx (or native) implementation
//                       supplies T. Tests supply a fake.
//
// Everything here is generic over the rasterizer payload T (e.g. a ui.Image),
// so the engine carries no Flutter dependency.

import 'dart:async';
import 'dart:collection';

import 'viewport_core.dart' show Aabb, Camera;
import 'spatial_index.dart' show RTree;
import 'lod.dart' show LodPolicy;

// ---------------------------------------------------------------------------
// Module 3 — viewport culling
// ---------------------------------------------------------------------------

/// Couples a [Camera] to an [RTree] to yield the primitives intersecting the
/// (buffered) viewport. Stateless and allocation-free on the visitor path.
final class ViewportCuller {
  final RTree index;

  ViewportCuller(this.index);

  /// Visits the id of every primitive whose bounds intersect the camera's
  /// visible world rect, expanded by [bufferPx] screen pixels. Return `false`
  /// from [visit] to stop early.
  void cull(
    Camera camera,
    bool Function(int id) visit, {
    double bufferPx = 0.0,
  }) {
    final b = camera.visibleWorldBounds(bufferPx: bufferPx);
    index.query(b.minX, b.minY, b.maxX, b.maxY, visit);
  }

  /// Collects all visible primitive ids into a list (convenience; allocates).
  List<int> visibleIds(Camera camera, {double bufferPx = 0.0}) {
    final out = <int>[];
    cull(camera, (id) {
      out.add(id);
      return true;
    }, bufferPx: bufferPx);
    return out;
  }
}

// ---------------------------------------------------------------------------
// Cooperative cancellation
// ---------------------------------------------------------------------------

/// Thrown by [CancellationToken.throwIfCancelled] when work has been cancelled.
final class CancellationException implements Exception {
  const CancellationException();
  @override
  String toString() => 'CancellationException';
}

/// A one-shot cooperative cancellation signal. A rasterizer should poll
/// [isCancelled] (or call [throwIfCancelled]) at interruption points so that
/// tiles scrolled off-screen or superseded by a new zoom level abort promptly
/// instead of wasting CPU.
final class CancellationToken {
  bool _cancelled = false;
  final List<void Function()> _listeners = <void Function()>[];

  bool get isCancelled => _cancelled;

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    for (final l in _listeners) {
      l();
    }
    _listeners.clear();
  }

  /// Registers a callback invoked once when cancelled (immediately if already).
  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void throwIfCancelled() {
    if (_cancelled) throw const CancellationException();
  }
}

// ---------------------------------------------------------------------------
// Tile addressing
// ---------------------------------------------------------------------------

/// Identifies one tile in the pyramid by integer (level, x, y).
final class TileKey {
  final int level;
  final int x;
  final int y;

  const TileKey(this.level, this.x, this.y);

  /// The tile one level coarser that contains this tile.
  TileKey get parent => TileKey(level - 1, x >> 1, y >> 1);

  @override
  bool operator ==(Object other) =>
      other is TileKey &&
      other.level == level &&
      other.x == x &&
      other.y == y;

  @override
  int get hashCode => Object.hash(level, x, y);

  @override
  String toString() => 'TileKey($level,$x,$y)';
}

// ---------------------------------------------------------------------------
// Module 6 — rasterizer seam
// ---------------------------------------------------------------------------

/// What the manager asks the rasterizer to produce: the [key]'s world rectangle
/// rendered into a [pixelWidth] x [pixelHeight] raster.
final class TileRenderRequest {
  final TileKey key;
  final Aabb worldBounds;
  final int pixelWidth;
  final int pixelHeight;

  const TileRenderRequest({
    required this.key,
    required this.worldBounds,
    required this.pixelWidth,
    required this.pixelHeight,
  });
}

/// Produces tile rasters of type [T]. Implementations live outside the pure
/// engine (Flutter/pdfrx, native, or a test fake). Must honour [token]:
/// long renders should poll it and may throw [CancellationException].
abstract interface class TileRasterizer<T> {
  Future<T> rasterize(TileRenderRequest request, CancellationToken token);
}

// ---------------------------------------------------------------------------
// Module 4 — LRU cache with a hard byte ceiling
// ---------------------------------------------------------------------------

/// An LRU cache of tile payloads bounded by a hard byte ceiling. On insertion it
/// evicts least-recently-used entries (calling [dispose]) until the total
/// reported size is within [maxBytes]. Single-threaded use.
final class TileCache<T> {
  final int maxBytes;
  final int Function(T value) sizeOf;
  final void Function(T value) dispose;

  // LinkedHashMap preserves insertion order; we emulate access-order by
  // removing and reinserting on read/refresh, so the first key is the LRU.
  final LinkedHashMap<TileKey, T> _entries = LinkedHashMap<TileKey, T>();
  final Map<TileKey, int> _sizes = <TileKey, int>{};
  int _bytes = 0;

  TileCache({
    required this.maxBytes,
    required this.sizeOf,
    required this.dispose,
  }) {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be > 0');
    }
  }

  int get currentBytes => _bytes;
  int get length => _entries.length;

  bool contains(TileKey key) => _entries.containsKey(key);

  /// Returns the cached value and marks it most-recently-used, or null.
  T? get(TileKey key) {
    final v = _entries.remove(key);
    if (v == null) return null;
    _entries[key] = v; // reinsert at MRU end
    return v;
  }

  /// Inserts or replaces [key]. Evicts LRU entries until within [maxBytes]. If a
  /// single value exceeds the ceiling it is disposed immediately and not stored.
  void put(TileKey key, T value) {
    final size = sizeOf(value);
    if (size < 0) {
      throw ArgumentError('sizeOf returned negative ($size) for $key');
    }
    // Replace existing.
    final existing = _entries.remove(key);
    if (existing != null) {
      _bytes -= _sizes.remove(key) ?? 0;
      dispose(existing);
    }
    if (size > maxBytes) {
      dispose(value); // cannot ever fit
      return;
    }
    _entries[key] = value;
    _sizes[key] = size;
    _bytes += size;
    _evictToCeiling();
  }

  void _evictToCeiling() {
    while (_bytes > maxBytes && _entries.isNotEmpty) {
      final oldestKey = _entries.keys.first;
      final v = _entries.remove(oldestKey) as T;
      _bytes -= _sizes.remove(oldestKey) ?? 0;
      dispose(v);
    }
  }

  /// Disposes and removes everything.
  void clear() {
    for (final v in _entries.values) {
      dispose(v);
    }
    _entries.clear();
    _sizes.clear();
    _bytes = 0;
  }
}

// ---------------------------------------------------------------------------
// A tile ready to be drawn this frame.
// ---------------------------------------------------------------------------

/// A cached tile selected for drawing, with the world rectangle it covers (the
/// painter converts that to screen space via the camera).
final class ReadyTile<T> {
  final TileKey key;
  final T value;
  final Aabb worldBounds;

  const ReadyTile(this.key, this.value, this.worldBounds);
}

// ---------------------------------------------------------------------------
// Module 4 — the tile manager / scheduler
// ---------------------------------------------------------------------------

/// Orchestrates tiling for one document layer: chooses the pyramid level for the
/// current camera, determines the needed tiles, serves cached ones, schedules
/// missing ones (cancellable), cancels obsolete in-flight work, and exposes a
/// gap-free draw set by falling back to coarser cached ancestors.
final class TileManager<T> {
  final TileRasterizer<T> rasterizer;
  final TileCache<T> cache;
  final LodPolicy lod;

  /// Screen-pixel ring rendered beyond the visible viewport so panning reveals
  /// ready tiles.
  final double bufferPx;

  /// Defensive cap on tiles requested in a single update (guards against a
  /// mis-chosen level producing millions of cells).
  final int maxTilesPerUpdate;

  /// Invoked (debounce yourself) whenever a newly rasterized tile lands, so the
  /// viewport can repaint.
  void Function()? onTileReady;

  final Map<TileKey, CancellationToken> _inflight =
      <TileKey, CancellationToken>{};
  Set<TileKey> _needed = <TileKey>{};

  TileManager({
    required this.rasterizer,
    required this.cache,
    required this.lod,
    this.bufferPx = 256.0,
    this.maxTilesPerUpdate = 4096,
    this.onTileReady,
  }) {
    if (bufferPx < 0) {
      throw ArgumentError.value(bufferPx, 'bufferPx', 'must be >= 0');
    }
    if (maxTilesPerUpdate <= 0) {
      throw ArgumentError.value(
          maxTilesPerUpdate, 'maxTilesPerUpdate', 'must be > 0');
    }
  }

  /// Number of tiles currently being rasterized.
  int get inflightCount => _inflight.length;

  /// World rectangle of a tile.
  Aabb tileWorldBounds(TileKey key) {
    final tws = lod.tileWorldSize(key.level);
    final minX = key.x * tws;
    final minY = key.y * tws;
    return Aabb(minX, minY, minX + tws, minY + tws);
  }

  /// Recomputes needed tiles for [camera]. Schedules missing tiles, cancels
  /// in-flight tiles that are no longer needed. Call on every camera change.
  void update(Camera camera) {
    final level = lod.levelForScale(camera.scale);
    final tws = lod.tileWorldSize(level);
    final view = camera.visibleWorldBounds(bufferPx: bufferPx);

    final x0 = (view.minX / tws).floor();
    final x1 = (view.maxX / tws).floor();
    final y0 = (view.minY / tws).floor();
    final y1 = (view.maxY / tws).floor();

    final countX = (x1 - x0 + 1);
    final countY = (y1 - y0 + 1);
    final total = countX * countY;

    final needed = <TileKey>{};
    if (total > 0 && total <= maxTilesPerUpdate) {
      for (var ty = y0; ty <= y1; ty++) {
        for (var tx = x0; tx <= x1; tx++) {
          needed.add(TileKey(level, tx, ty));
        }
      }
    }
    // If total exceeds the cap, `needed` stays smaller (only what we can serve);
    // the draw set will fall back to coarser ancestors, which is the correct
    // graceful behaviour rather than flooding the scheduler.
    _needed = needed;

    final pixelEdge = lod.tilePixelEdge(level, camera.scale);

    // Cancel obsolete in-flight work.
    final toCancel = <TileKey>[];
    for (final key in _inflight.keys) {
      if (!needed.contains(key)) toCancel.add(key);
    }
    for (final key in toCancel) {
      _inflight.remove(key)!.cancel();
    }

    // Schedule missing, not-already-in-flight tiles.
    for (final key in needed) {
      if (cache.contains(key) || _inflight.containsKey(key)) continue;
      _schedule(key, pixelEdge);
    }
  }

  void _schedule(TileKey key, int pixelEdge) {
    final token = CancellationToken();
    _inflight[key] = token;
    final req = TileRenderRequest(
      key: key,
      worldBounds: tileWorldBounds(key),
      pixelWidth: pixelEdge,
      pixelHeight: pixelEdge,
    );
    rasterizer.rasterize(req, token).then((value) {
      // Completed: only keep it if still wanted and not cancelled.
      final stillTracked = identical(_inflight[key], token);
      _inflight.remove(key);
      if (token.isCancelled || !stillTracked || !_needed.contains(key)) {
        cache.dispose(value);
        return;
      }
      cache.put(key, value);
      onTileReady?.call();
    }).catchError((Object e) {
      // Swallow cancellation; surface nothing for a tile that simply aborted.
      if (identical(_inflight[key], token)) _inflight.remove(key);
    });
  }

  /// The gap-free set of tiles to draw for [camera] this frame. For each needed
  /// cell it returns the cached tile if present, otherwise the nearest cached
  /// coarser ancestor (so something always shows). Deduplicated by key.
  List<ReadyTile<T>> collectDrawTiles(Camera camera) {
    final level = lod.levelForScale(camera.scale);
    final tws = lod.tileWorldSize(level);
    final view = camera.visibleWorldBounds(bufferPx: bufferPx);

    final x0 = (view.minX / tws).floor();
    final x1 = (view.maxX / tws).floor();
    final y0 = (view.minY / tws).floor();
    final y1 = (view.maxY / tws).floor();

    final seen = <TileKey>{};
    final out = <ReadyTile<T>>[];

    final countX = (x1 - x0 + 1);
    final countY = (y1 - y0 + 1);
    if (countX <= 0 || countY <= 0) return out;
    if (countX * countY > maxTilesPerUpdate) {
      // Too many fine cells; draw from the coarsest sensible ancestor band only.
      return out;
    }

    for (var ty = y0; ty <= y1; ty++) {
      for (var tx = x0; tx <= x1; tx++) {
        var key = TileKey(level, tx, ty);
        // Walk up until we find a cached tile or run out of levels.
        while (key.level >= lod.minLevel) {
          final v = cache.get(key);
          if (v != null) {
            if (seen.add(key)) {
              out.add(ReadyTile<T>(key, v, tileWorldBounds(key)));
            }
            break;
          }
          if (key.level == lod.minLevel) break;
          key = key.parent;
        }
      }
    }
    return out;
  }

  /// Cancels all in-flight rasterization (e.g. on document close).
  void cancelAll() {
    for (final t in _inflight.values) {
      t.cancel();
    }
    _inflight.clear();
    _needed = <TileKey>{};
  }

  /// Releases everything: cancels in-flight work and clears the cache.
  void dispose() {
    cancelAll();
    cache.clear();
  }
}
