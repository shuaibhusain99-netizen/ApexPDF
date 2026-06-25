// annotation_store.dart
//
// Feature 1 — Annotations (store + spatial queries).
//
// Holds a page's annotations in insertion order (= z-order; last drawn on top)
// and indexes their world bounds in the engine's R-tree so picking and viewport
// culling are O(log n + k) instead of linear. The index is rebuilt lazily on the
// next query after any mutation (immutable-snapshot model, consistent with the
// engine). A monotonic [version] lets the overlay know when to repaint.

import 'dart:collection';

import '../engine/viewport_core.dart' show Aabb;
import '../engine/spatial_index.dart' show RTree, RTreeBuilder;
import 'annotation_model.dart' show Annotation;

final class AnnotationStore {
  // Insertion-ordered: iteration order is the paint/z order.
  final LinkedHashMap<String, Annotation> _byId =
      LinkedHashMap<String, Annotation>();

  // Lazily (re)built spatial index + the id list it maps onto.
  RTree? _index;
  List<String> _indexIds = const <String>[];
  bool _dirty = true;

  int _version = 0;

  /// Increments on every mutation; bind your overlay's repaint to it.
  int get version => _version;

  int get length => _byId.length;
  bool get isEmpty => _byId.isEmpty;

  /// All annotations in z-order (bottom first). Returns an unmodifiable view.
  Iterable<Annotation> get all => _byId.values;

  Annotation? getById(String id) => _byId[id];

  bool contains(String id) => _byId.containsKey(id);

  /// Adds an annotation. Throws if its id already exists.
  void add(Annotation a) {
    if (_byId.containsKey(a.id)) {
      throw ArgumentError('duplicate annotation id ${a.id}');
    }
    _byId[a.id] = a;
    _invalidate();
  }

  /// Removes by id; returns the removed annotation or null.
  Annotation? remove(String id) {
    final removed = _byId.remove(id);
    if (removed != null) _invalidate();
    return removed;
  }

  /// Replaces an existing annotation (same id), preserving z-order position.
  /// Throws if the id is not present.
  void update(Annotation a) {
    if (!_byId.containsKey(a.id)) {
      throw ArgumentError('cannot update unknown annotation ${a.id}');
    }
    _byId[a.id] = a; // LinkedHashMap keeps the original position for existing keys
    _invalidate();
  }

  /// Removes everything.
  void clear() {
    if (_byId.isEmpty) return;
    _byId.clear();
    _invalidate();
  }

  void _invalidate() {
    _dirty = true;
    _version++;
  }

  void _ensureIndex() {
    if (!_dirty && _index != null) return;
    final builder = RTreeBuilder(nodeSize: 16);
    final ids = <String>[];
    for (final a in _byId.values) {
      builder.addBox(a.worldBounds);
      ids.add(a.id);
    }
    _index = builder.build();
    _indexIds = ids;
    _dirty = false;
  }

  /// Ids of annotations whose bounds intersect [worldRect] (e.g. the camera's
  /// visible world bounds). Order is unspecified.
  List<String> idsInRect(Aabb worldRect) {
    if (_byId.isEmpty) return const <String>[];
    _ensureIndex();
    final out = <String>[];
    _index!.query(
      worldRect.minX,
      worldRect.minY,
      worldRect.maxX,
      worldRect.maxY,
      (i) {
        out.add(_indexIds[i]);
        return true;
      },
    );
    return out;
  }

  /// Annotations intersecting [worldRect], returned in z-order (bottom first)
  /// so a renderer can paint them directly.
  List<Annotation> annotationsInRect(Aabb worldRect) {
    final hitIds = idsInRect(worldRect).toSet();
    if (hitIds.isEmpty) return const <Annotation>[];
    final out = <Annotation>[];
    for (final a in _byId.values) {
      if (hitIds.contains(a.id)) out.add(a);
    }
    return out;
  }

  /// The topmost annotation under the world-space point, or null. Uses the
  /// index to gather candidates, then precise per-annotation [Annotation.hitTest],
  /// returning the one drawn last (highest z).
  Annotation? hitTest(double x, double y, {double toleranceWorld = 0.0}) {
    if (_byId.isEmpty) return null;
    if (!x.isFinite || !y.isFinite) {
      throw ArgumentError('hit point must be finite (got $x,$y)');
    }
    if (toleranceWorld < 0) {
      throw ArgumentError.value(toleranceWorld, 'toleranceWorld', 'must be >= 0');
    }
    _ensureIndex();
    final candidates = <String>{};
    _index!.query(
      x - toleranceWorld,
      y - toleranceWorld,
      x + toleranceWorld,
      y + toleranceWorld,
      (i) {
        candidates.add(_indexIds[i]);
        return true;
      },
    );
    if (candidates.isEmpty) return null;
    // Walk in reverse z-order; first precise hit wins (topmost).
    Annotation? topmost;
    for (final a in _byId.values) {
      if (candidates.contains(a.id) && a.hitTest(x, y, toleranceWorld)) {
        topmost = a; // keep last (highest z) match
      }
    }
    return topmost;
  }
}
