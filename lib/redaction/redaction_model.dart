// redaction_model.dart
//
// Feature 2 — Redaction (planning + verification core).
//
// TRUE redaction = permanently removing content, not just drawing a black box
// over it. The destructive step (rewriting page content streams, rasterizing,
// scrubbing metadata/XMP) is native (PdfBox-Android) and cannot run in this
// sandbox. What CAN be built and tested here, and is the part that actually
// makes redaction safe, is:
//
//   1. Given redaction rectangles + the page's extracted text runs (from pdfrx),
//      determine exactly which runs fall under a box and must be destroyed.
//   2. After the native step re-extracts text, VERIFY that nothing under a box
//      is still extractable and that no redacted string survives anywhere.
//
// Pure Dart; reuses the engine's R-tree for scale. Coordinates are PDF page
// points (world space), matching the viewport engine and pdfrx text geometry.

import '../engine/viewport_core.dart' show Aabb;
import '../engine/spatial_index.dart' show RTree, RTreeBuilder;

/// A rectangle on a page whose underlying content must be permanently removed.
final class RedactionRegion {
  final String id;
  final int pageIndex;
  final Aabb rect; // PDF points
  /// Fill drawn in place of removed content (ARGB). Opaque black by default.
  final int fillArgb;

  RedactionRegion({
    required this.id,
    required this.pageIndex,
    required this.rect,
    this.fillArgb = 0xFF000000,
  }) {
    if (id.isEmpty) throw ArgumentError('region id must not be empty');
    if (pageIndex < 0) throw ArgumentError('pageIndex must be >= 0');
    if (!(rect.area > 0)) {
      throw ArgumentError('redaction rect must have positive area');
    }
  }
}

/// A fragment of extracted text with its bounding box, as produced by the
/// viewer's text layer (pdfrx). Pure data.
final class TextRun {
  final String text;
  final Aabb bounds; // PDF points
  const TextRun(this.text, this.bounds);
}

/// Result of checking a page (or a verification pass).
final class RedactionResult {
  final bool ok;
  final List<String> violations;
  const RedactionResult(this.ok, this.violations);

  @override
  String toString() =>
      ok ? 'RedactionResult(ok)' : 'RedactionResult(${violations.length} violations)';
}

/// A set of redaction regions across pages, with the spatial logic that decides
/// what gets destroyed and the verification that proves it was.
final class RedactionPlan {
  final List<RedactionRegion> _regions = <RedactionRegion>[];

  // page -> immutable R-tree over that page's region rects (lazily built).
  final Map<int, RTree> _indexByPage = <int, RTree>{};
  final Map<int, List<RedactionRegion>> _regionsByPage =
      <int, List<RedactionRegion>>{};
  bool _dirty = true;

  int get regionCount => _regions.length;
  Iterable<RedactionRegion> get regions => _regions;

  void add(RedactionRegion r) {
    _regions.add(r);
    _dirty = true;
  }

  bool remove(String id) {
    final before = _regions.length;
    _regions.removeWhere((r) => r.id == id);
    final changed = _regions.length != before;
    if (changed) _dirty = true;
    return changed;
  }

  void clear() {
    _regions.clear();
    _dirty = true;
  }

  List<RedactionRegion> regionsForPage(int pageIndex) {
    _ensureIndex();
    return _regionsByPage[pageIndex] ?? const <RedactionRegion>[];
  }

  void _ensureIndex() {
    if (!_dirty) return;
    _indexByPage.clear();
    _regionsByPage.clear();
    final grouped = <int, List<RedactionRegion>>{};
    for (final r in _regions) {
      (grouped[r.pageIndex] ??= <RedactionRegion>[]).add(r);
    }
    grouped.forEach((page, regs) {
      final b = RTreeBuilder(nodeSize: 16);
      for (final r in regs) {
        b.addBox(r.rect);
      }
      _indexByPage[page] = b.build();
      _regionsByPage[page] = regs;
    });
    _dirty = false;
  }

  /// Which of [pageRuns] (text runs on [pageIndex]) intersect a redaction
  /// region and therefore MUST be removed by the native step. Order preserved.
  List<TextRun> runsToRedact(int pageIndex, List<TextRun> pageRuns) {
    _ensureIndex();
    final index = _indexByPage[pageIndex];
    final regs = _regionsByPage[pageIndex];
    if (index == null || regs == null || regs.isEmpty) return const <TextRun>[];
    final out = <TextRun>[];
    for (final run in pageRuns) {
      final rb = run.bounds;
      var hit = false;
      index.query(rb.minX, rb.minY, rb.maxX, rb.maxY, (i) {
        // R-tree box overlap is exact for AABBs, but re-check against the
        // specific region to be unambiguous about the contract.
        if (regs[i].rect.intersects(rb)) {
          hit = true;
          return false; // stop early
        }
        return true;
      });
      if (hit) out.add(run);
    }
    return out;
  }

  /// Concatenated text that will be destroyed on a page — for the audit log.
  String redactedTextForPage(int pageIndex, List<TextRun> pageRuns) =>
      runsToRedact(pageIndex, pageRuns).map((r) => r.text).join(' ');

  /// All distinct non-empty strings that the plan will destroy (across the
  /// supplied per-page run map). Used to drive the textual residue check.
  Set<String> redactedStrings(Map<int, List<TextRun>> runsByPage) {
    final set = <String>{};
    runsByPage.forEach((page, runs) {
      for (final r in runsToRedact(page, runs)) {
        final t = r.text.trim();
        if (t.isNotEmpty) set.add(t);
      }
    });
    return set;
  }

  /// VERIFY a completed redaction. [postRunsByPage] is text re-extracted from
  /// the OUTPUT pdf. Redaction is sound iff:
  ///   (a) no surviving run intersects any region (geometric), and
  ///   (b) none of [mustNotSurvive] appears in any surviving run (textual).
  /// Returns the violations found (empty => ok).
  RedactionResult verify(
    Map<int, List<TextRun>> postRunsByPage, {
    Set<String> mustNotSurvive = const <String>{},
  }) {
    _ensureIndex();
    final violations = <String>[];

    // (a) geometric: nothing extractable left under a box.
    postRunsByPage.forEach((page, runs) {
      final index = _indexByPage[page];
      final regs = _regionsByPage[page];
      if (index == null || regs == null) return;
      for (final run in runs) {
        final rb = run.bounds;
        index.query(rb.minX, rb.minY, rb.maxX, rb.maxY, (i) {
          if (regs[i].rect.intersects(rb)) {
            violations.add(
                'page $page: text "${_clip(run.text)}" still under region ${regs[i].id}');
            return false;
          }
          return true;
        });
      }
    });

    // (b) textual: a redacted string must not survive anywhere in the document.
    if (mustNotSurvive.isNotEmpty) {
      final survivors = <String>[];
      postRunsByPage.forEach((page, runs) {
        for (final run in runs) {
          survivors.add(run.text);
        }
      });
      final hay = survivors.join('\n');
      for (final needle in mustNotSurvive) {
        if (needle.isNotEmpty && hay.contains(needle)) {
          violations.add('redacted string "${_clip(needle)}" still present');
        }
      }
    }

    return RedactionResult(violations.isEmpty, violations);
  }

  static String _clip(String s) => s.length <= 40 ? s : '${s.substring(0, 40)}…';
}

/// JSON (de)serialization of regions — the payload handed to the native
/// PdfBox-Android redactor and the on-disk redaction set.
abstract final class RedactionCodec {
  static Map<String, Object?> toJson(RedactionRegion r) => {
        'id': r.id,
        'page': r.pageIndex,
        'rect': [r.rect.minX, r.rect.minY, r.rect.maxX, r.rect.maxY],
        'fill': r.fillArgb,
      };

  static RedactionRegion fromJson(Map<String, Object?> j) {
    final rect = j['rect'];
    if (rect is! List || rect.length != 4) {
      throw const FormatException('region "rect" must be 4 numbers');
    }
    double d(Object? v) =>
        v is num ? v.toDouble() : throw const FormatException('rect needs numbers');
    final id = j['id'];
    final page = j['page'];
    final fill = j['fill'];
    if (id is! String) throw const FormatException('region "id" must be String');
    if (page is! int) throw const FormatException('region "page" must be int');
    return RedactionRegion(
      id: id,
      pageIndex: page,
      rect: Aabb(d(rect[0]), d(rect[1]), d(rect[2]), d(rect[3])),
      fillArgb: fill is int ? fill : 0xFF000000,
    );
  }

  static List<Map<String, Object?>> encodeAll(Iterable<RedactionRegion> rs) =>
      rs.map(toJson).toList(growable: false);

  static List<RedactionRegion> decodeAll(List<Object?> items) => items
      .map((e) => fromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);
}
