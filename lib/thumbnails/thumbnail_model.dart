// thumbnail_model.dart
//
// Thumbnail support core. Pure Dart, fully testable, no Flutter/pdfrx coupling:
//   * fitWithin — aspect-preserving sizing so thumbnails never distort,
//   * ThumbnailCache — a bounded LRU keyed by page index with an eviction
//     callback, so a 500-page document cannot accumulate unbounded images
//     (the app disposes the evicted ui.Image in onEvict).

import 'dart:collection';

/// A width/height pair in logical pixels.
class ThumbFit {
  final double width;
  final double height;
  const ThumbFit(this.width, this.height);

  @override
  bool operator ==(Object other) =>
      other is ThumbFit && other.width == width && other.height == height;

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => 'ThumbFit($width, $height)';
}

/// Scale (srcW x srcH) to fit inside (boxW x boxH) preserving aspect ratio.
/// Returns zero size if any input is non-positive.
ThumbFit fitWithin(double srcW, double srcH, double boxW, double boxH) {
  if (srcW <= 0 || srcH <= 0 || boxW <= 0 || boxH <= 0) {
    return const ThumbFit(0, 0);
  }
  final scale = (boxW / srcW) < (boxH / srcH) ? boxW / srcW : boxH / srcH;
  return ThumbFit(srcW * scale, srcH * scale);
}

/// A bounded LRU cache from page index to a rendered value [T].
///
/// Most-recently used entries are kept; the oldest are evicted once [maxEntries]
/// is exceeded. [onEvict] fires for every removed entry (use it to dispose
/// images). [get] refreshes recency so a visible thumbnail is not evicted next.
class ThumbnailCache<T> {
  final int maxEntries;
  final void Function(int key, T value)? onEvict;
  final LinkedHashMap<int, T> _map = LinkedHashMap<int, T>();

  ThumbnailCache(this.maxEntries, {this.onEvict})
      : assert(maxEntries > 0, 'maxEntries must be positive');

  int get length => _map.length;
  Iterable<int> get keys => _map.keys;
  bool contains(int key) => _map.containsKey(key);

  /// Returns the value for [key] (refreshing its recency) or null.
  T? get(int key) {
    final value = _map.remove(key);
    if (value == null) return null;
    _map[key] = value; // reinsert as most-recent
    return value;
  }

  /// Inserts or updates [key]; evicts the oldest entries beyond [maxEntries].
  void put(int key, T value) {
    _map.remove(key); // ensure reinsertion order is most-recent
    _map[key] = value;
    while (_map.length > maxEntries) {
      final oldest = _map.keys.first;
      final removed = _map.remove(oldest);
      if (removed != null) onEvict?.call(oldest, removed);
    }
  }

  /// Evicts everything (firing [onEvict] for each entry).
  void clear() {
    final entries = List<MapEntry<int, T>>.of(_map.entries);
    _map.clear();
    for (final e in entries) {
      onEvict?.call(e.key, e.value);
    }
  }
}
