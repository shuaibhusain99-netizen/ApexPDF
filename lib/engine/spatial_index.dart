// spatial_index.dart
//
// Module 2 of the viewport engine: a static, bulk-loaded R-tree.
//
// Why this shape:
//  * IMMUTABLE / BULK-LOADED. Built once from all primitive boxes; on document
//    edit the index is rebuilt (O(n log n), infrequent) and swapped as a new
//    snapshot. This matches the single-source-of-truth + immutable-handoff model
//    the architecture requires, and keeps the *query* path — run every frame —
//    completely allocation-free.
//  * FLAT TYPED ARRAYS. Nodes live in Float64List/Int32List, not objects, so the
//    tree is cache-friendly and produces zero GC pressure.
//  * MORTON (Z-ORDER) PACKING. Items are spatially sorted before packing so
//    contiguous chunks form tight nodes. Morton is used (not Hilbert) because it
//    is simple enough to be obviously correct; Hilbert packing is a future
//    constant-factor optimization. Packing quality affects query *speed* only —
//    results are exact regardless (proven by the brute-force equivalence test).
//  * VISITOR QUERY. query(...) invokes a callback per hit and never allocates a
//    result list; the caller decides what to collect. A reusable internal stack
//    bounds recursion without the call stack.

import 'dart:typed_data';
import 'viewport_core.dart' show Aabb;

/// Builds an immutable [RTree]. Add every primitive's bounding box (receiving a
/// stable integer id back), then call [build].
final class RTreeBuilder {
  final List<double> _minX = <double>[];
  final List<double> _minY = <double>[];
  final List<double> _maxX = <double>[];
  final List<double> _maxY = <double>[];
  final int nodeSize;

  /// [nodeSize] is the branching factor (children per node). 16 is a good
  /// default balancing tree height against per-node scan cost.
  RTreeBuilder({this.nodeSize = 16}) {
    if (nodeSize < 2) {
      throw ArgumentError.value(nodeSize, 'nodeSize', 'must be >= 2');
    }
  }

  /// Adds an item's bounding box and returns its id (0-based, sequential).
  /// Throws if any coordinate is non-finite or min > max.
  int add(double minX, double minY, double maxX, double maxY) {
    if (!minX.isFinite ||
        !minY.isFinite ||
        !maxX.isFinite ||
        !maxY.isFinite) {
      throw ArgumentError('box must be finite '
          '(got $minX,$minY,$maxX,$maxY)');
    }
    if (minX > maxX || minY > maxY) {
      throw ArgumentError('box requires min <= max '
          '(got $minX,$minY,$maxX,$maxY)');
    }
    final id = _minX.length;
    _minX.add(minX);
    _minY.add(minY);
    _maxX.add(maxX);
    _maxY.add(maxY);
    return id;
  }

  /// Adds an [Aabb], returning its id.
  int addBox(Aabb box) => add(box.minX, box.minY, box.maxX, box.maxY);

  /// Number of items added so far.
  int get length => _minX.length;

  /// Produces the immutable index. The builder may be reused afterward.
  RTree build() => RTree._build(
        _minX,
        _minY,
        _maxX,
        _maxY,
        nodeSize,
      );
}

/// An immutable R-tree supporting allocation-free rectangle queries.
final class RTree {
  final int _numItems;
  final int _nodeSize;

  /// Flat node boxes: 4 doubles per node (minX,minY,maxX,maxY). Leaf nodes
  /// occupy indices [0, _numItems); internal nodes follow.
  final Float64List _boxes;

  /// Per node: for a leaf node, the original item id; for an internal node, the
  /// node index of its first child.
  final Int32List _refs;

  /// Exclusive end node-index of each level (level 0 == leaves).
  final Int32List _levelBounds;

  final int _numNodes;

  // Reusable traversal stack (single-threaded, non-reentrant queries).
  Int32List _stack = Int32List(256);

  RTree._({
    required int numItems,
    required int nodeSize,
    required Float64List boxes,
    required Int32List refs,
    required Int32List levelBounds,
    required int numNodes,
  })  : _numItems = numItems,
        _nodeSize = nodeSize,
        _boxes = boxes,
        _refs = refs,
        _levelBounds = levelBounds,
        _numNodes = numNodes;

  /// Number of indexed items.
  int get length => _numItems;

  /// True if the index holds no items (queries return immediately).
  bool get isEmpty => _numItems == 0;

  factory RTree._build(
    List<double> minXs,
    List<double> minYs,
    List<double> maxXs,
    List<double> maxYs,
    int nodeSize,
  ) {
    final numItems = minXs.length;

    if (numItems == 0) {
      return RTree._(
        numItems: 0,
        nodeSize: nodeSize,
        boxes: Float64List(0),
        refs: Int32List(0),
        levelBounds: Int32List.fromList(const <int>[0]),
        numNodes: 0,
      );
    }

    // --- level sizing -------------------------------------------------------
    final levelCounts = <int>[numItems];
    var n = numItems;
    var numNodes = numItems;
    while (n > 1) {
      n = (n + nodeSize - 1) ~/ nodeSize;
      numNodes += n;
      levelCounts.add(n);
    }
    final levelBounds = Int32List(levelCounts.length);
    var acc = 0;
    for (var i = 0; i < levelCounts.length; i++) {
      acc += levelCounts[i];
      levelBounds[i] = acc;
    }

    final boxes = Float64List(numNodes * 4);
    final refs = Int32List(numNodes);

    // --- global bounds for Morton normalization -----------------------------
    var gMinX = double.infinity,
        gMinY = double.infinity,
        gMaxX = double.negativeInfinity,
        gMaxY = double.negativeInfinity;
    for (var i = 0; i < numItems; i++) {
      if (minXs[i] < gMinX) gMinX = minXs[i];
      if (minYs[i] < gMinY) gMinY = minYs[i];
      if (maxXs[i] > gMaxX) gMaxX = maxXs[i];
      if (maxYs[i] > gMaxY) gMaxY = maxYs[i];
    }
    final spanX = (gMaxX - gMinX);
    final spanY = (gMaxY - gMinY);
    final invW = spanX > 0 ? 1.0 / spanX : 0.0;
    final invH = spanY > 0 ? 1.0 / spanY : 0.0;

    // --- Morton code per item, then sort a permutation ----------------------
    final order = Int32List(numItems);
    final codes = Int32List(numItems);
    const gridMax = 0xFFFF; // 16-bit per axis
    for (var i = 0; i < numItems; i++) {
      order[i] = i;
      final cx = (minXs[i] + maxXs[i]) * 0.5;
      final cy = (minYs[i] + maxYs[i]) * 0.5;
      final gx = (((cx - gMinX) * invW) * gridMax).floor().clamp(0, gridMax);
      final gy = (((cy - gMinY) * invH) * gridMax).floor().clamp(0, gridMax);
      codes[i] = _morton(gx, gy);
    }
    _sortByKey(order, codes, 0, numItems - 1);

    // --- fill leaf level in sorted order ------------------------------------
    for (var p = 0; p < numItems; p++) {
      final src = order[p];
      final b = p * 4;
      boxes[b] = minXs[src];
      boxes[b + 1] = minYs[src];
      boxes[b + 2] = maxXs[src];
      boxes[b + 3] = maxYs[src];
      refs[p] = src;
    }

    // --- build internal levels bottom-up ------------------------------------
    var read = 0;
    var write = numItems;
    for (var level = 0; level < levelBounds.length - 1; level++) {
      final end = levelBounds[level];
      while (read < end) {
        final childStart = read;
        var nMinX = double.infinity,
            nMinY = double.infinity,
            nMaxX = double.negativeInfinity,
            nMaxY = double.negativeInfinity;
        var cnt = 0;
        while (read < end && cnt < nodeSize) {
          final rb = read * 4;
          if (boxes[rb] < nMinX) nMinX = boxes[rb];
          if (boxes[rb + 1] < nMinY) nMinY = boxes[rb + 1];
          if (boxes[rb + 2] > nMaxX) nMaxX = boxes[rb + 2];
          if (boxes[rb + 3] > nMaxY) nMaxY = boxes[rb + 3];
          read++;
          cnt++;
        }
        final wb = write * 4;
        boxes[wb] = nMinX;
        boxes[wb + 1] = nMinY;
        boxes[wb + 2] = nMaxX;
        boxes[wb + 3] = nMaxY;
        refs[write] = childStart;
        write++;
      }
    }

    return RTree._(
      numItems: numItems,
      nodeSize: nodeSize,
      boxes: boxes,
      refs: refs,
      levelBounds: levelBounds,
      numNodes: numNodes,
    );
  }

  /// Smallest level-end strictly greater than [nodeIndex] (i.e. the exclusive
  /// upper bound of the level that [nodeIndex] belongs to).
  int _levelEndOf(int nodeIndex) {
    for (var k = 0; k < _levelBounds.length; k++) {
      if (nodeIndex < _levelBounds[k]) return _levelBounds[k];
    }
    return _numNodes;
  }

  void _ensureStack(int needed) {
    if (needed <= _stack.length) return;
    var cap = _stack.length;
    while (cap < needed) {
      cap <<= 1;
    }
    final grown = Int32List(cap);
    grown.setRange(0, _stack.length, _stack);
    _stack = grown;
  }

  /// Visits the id of every item whose box intersects the query rectangle.
  /// Return `false` from [visit] to stop early. Allocation-free. NOT reentrant
  /// (do not call query again from inside [visit] on the same tree).
  void query(
    double qMinX,
    double qMinY,
    double qMaxX,
    double qMaxY,
    bool Function(int id) visit,
  ) {
    if (_numItems == 0) return;
    if (!qMinX.isFinite ||
        !qMinY.isFinite ||
        !qMaxX.isFinite ||
        !qMaxY.isFinite) {
      throw ArgumentError('query box must be finite '
          '(got $qMinX,$qMinY,$qMaxX,$qMaxY)');
    }

    final root = _numNodes - 1;
    // Box-test the root before pushing.
    final rb = root * 4;
    if (qMinX > _boxes[rb + 2] ||
        qMinY > _boxes[rb + 3] ||
        qMaxX < _boxes[rb] ||
        qMaxY < _boxes[rb + 1]) {
      return;
    }

    var sp = 0;
    _ensureStack(1);
    _stack[sp++] = root;

    while (sp > 0) {
      final node = _stack[--sp];
      if (node < _numItems) {
        // Leaf item node; box already passed the test before it was pushed.
        if (!visit(_refs[node])) return;
        continue;
      }
      final childStart = _refs[node];
      final levelEnd = _levelEndOf(childStart);
      final childEnd = (childStart + _nodeSize) < levelEnd
          ? (childStart + _nodeSize)
          : levelEnd;
      // Reserve worst-case stack growth for this node's children.
      _ensureStack(sp + (childEnd - childStart));
      for (var c = childStart; c < childEnd; c++) {
        final cb = c * 4;
        if (qMinX > _boxes[cb + 2] ||
            qMinY > _boxes[cb + 3] ||
            qMaxX < _boxes[cb] ||
            qMaxY < _boxes[cb + 1]) {
          continue; // no overlap
        }
        _stack[sp++] = c;
      }
    }
  }

  /// Convenience [Aabb] query that collects all hit ids into a list.
  List<int> queryBox(Aabb box) {
    final out = <int>[];
    query(box.minX, box.minY, box.maxX, box.maxY, (id) {
      out.add(id);
      return true;
    });
    return out;
  }
}

// --------------------------- helpers (private) ------------------------------

/// Interleaves the low 16 bits of [x] and [y] into a 32-bit Morton (Z-order)
/// code. Standard magic-number bit spreading.
int _morton(int x, int y) => _part1by1(x) | (_part1by1(y) << 1);

int _part1by1(int n) {
  n &= 0xFFFF;
  n = (n | (n << 8)) & 0x00FF00FF;
  n = (n | (n << 4)) & 0x0F0F0F0F;
  n = (n | (n << 2)) & 0x33333333;
  n = (n | (n << 1)) & 0x55555555;
  return n;
}

/// In-place quicksort of [order] using [keys] (parallel array indexed the same
/// way as [order]'s *values* before sorting) as the comparison key. Both arrays
/// are permuted together so that after sorting, order[i]'s key is keys at its
/// new slot. Implemented iteratively to bound stack depth.
void _sortByKey(Int32List order, Int32List keys, int lo, int hi) {
  if (hi <= lo) return;
  // Iterative quicksort with an explicit bounds stack.
  final stack = <int>[lo, hi];
  while (stack.isNotEmpty) {
    final h = stack.removeLast();
    final l = stack.removeLast();
    if (h <= l) continue;
    // Median-of-three pivot on the key array (indexed by current order slot's
    // original index). NOTE: keys is indexed by ORIGINAL item index, so we read
    // keys[order[x]].
    final mid = l + ((h - l) >> 1);
    final pivot = _med3(
      keys[order[l]],
      keys[order[mid]],
      keys[order[h]],
    );
    var i = l;
    var j = h;
    while (i <= j) {
      while (keys[order[i]] < pivot) {
        i++;
      }
      while (keys[order[j]] > pivot) {
        j--;
      }
      if (i <= j) {
        final tmp = order[i];
        order[i] = order[j];
        order[j] = tmp;
        i++;
        j--;
      }
    }
    // Recurse into the smaller partition first (push larger) to keep stack small.
    if (j - l < h - i) {
      if (i < h) {
        stack.add(i);
        stack.add(h);
      }
      if (l < j) {
        stack.add(l);
        stack.add(j);
      }
    } else {
      if (l < j) {
        stack.add(l);
        stack.add(j);
      }
      if (i < h) {
        stack.add(i);
        stack.add(h);
      }
    }
  }
}

int _med3(int a, int b, int c) {
  if (a < b) {
    if (b < c) return b;
    return a < c ? c : a;
  } else {
    if (a < c) return a;
    return b < c ? c : b;
  }
}
