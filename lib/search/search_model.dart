// search_model.dart
//
// Find-in-document core. Pure Dart, fully testable: it operates on a page's
// extracted text plus per-character boxes already expressed in WORLD space
// (top-left, y-down) — the app adapter does the pdfrx extraction and the
// PDF->world coordinate conversion, so this layer carries no engine coupling.
//
// Responsibilities:
//   * case / whole-word substring matching with stable code-unit indices
//     (no lowercasing of the whole string, which can change length and break
//     index alignment for characters like U+0130),
//   * turning a match span into merged, line-level highlight rectangles,
//   * aggregating matches across pages with wrap-around navigation.

import '../engine/viewport_core.dart';

/// Matching options.
class SearchOptions {
  final bool caseSensitive;
  final bool wholeWord;
  const SearchOptions({this.caseSensitive = false, this.wholeWord = false});
}

/// A single occurrence of the query on a page.
class SearchMatch {
  final int pageIndex;

  /// Half-open code-unit range [start, end) into the page's full text.
  final int start;
  final int end;

  /// Highlight boxes in world space — one per visual line the match spans.
  final List<Aabb> rects;

  const SearchMatch({
    required this.pageIndex,
    required this.start,
    required this.end,
    required this.rects,
  });

  int get length => end - start;
}

/// Word-character test (Unicode letters, numbers, underscore) for whole-word
/// boundary checks. Applied per code unit; lone surrogate halves read as
/// non-word, which is acceptable for boundary purposes.
final RegExp _wordChar = RegExp(r'[\p{L}\p{N}_]', unicode: true);
bool _isWordChar(int codeUnit) =>
    _wordChar.hasMatch(String.fromCharCode(codeUnit));

String _lower(int codeUnit) => String.fromCharCode(codeUnit).toLowerCase();

bool _charEquals(int a, int b, bool caseSensitive) {
  if (a == b) return true;
  if (caseSensitive) return false;
  return _lower(a) == _lower(b);
}

/// Merge boxes that belong to the same visual line into single rectangles.
/// Boxes arrive in reading order; a vertical gap (no y-overlap with the current
/// line band) starts a new line. Exposed for direct testing.
List<Aabb> mergeBoxesIntoLines(List<Aabb> boxes) {
  if (boxes.isEmpty) return const <Aabb>[];
  final out = <Aabb>[];
  Aabb cur = boxes.first;
  for (var k = 1; k < boxes.length; k++) {
    final b = boxes[k];
    final overlapsVertically = b.minY < cur.maxY && b.maxY > cur.minY;
    if (overlapsVertically) {
      cur = cur.union(b);
    } else {
      out.add(cur);
      cur = b;
    }
  }
  out.add(cur);
  return out;
}

/// One page's extracted text with per-code-unit world-space boxes.
class PageText {
  final int pageIndex;
  final String text;

  /// Aligned 1:1 with [text] code units; an entry may be null when the source
  /// did not provide a box for that character.
  final List<Aabb?> charBoxes;

  PageText({
    required this.pageIndex,
    required this.text,
    required this.charBoxes,
  }) {
    if (charBoxes.length != text.length) {
      throw ArgumentError(
          'charBoxes length (${charBoxes.length}) must equal text length '
          '(${text.length})');
    }
  }

  /// All non-overlapping matches of [query] on this page, in reading order.
  List<SearchMatch> findMatches(String query,
      [SearchOptions options = const SearchOptions()]) {
    final n = text.length;
    final m = query.length;
    if (m == 0 || m > n) return const <SearchMatch>[];

    final out = <SearchMatch>[];
    var i = 0;
    while (i <= n - m) {
      var matched = true;
      for (var j = 0; j < m; j++) {
        if (!_charEquals(
            text.codeUnitAt(i + j), query.codeUnitAt(j), options.caseSensitive)) {
          matched = false;
          break;
        }
      }
      if (matched && (!options.wholeWord || _isWordBoundary(i, i + m))) {
        out.add(SearchMatch(
          pageIndex: pageIndex,
          start: i,
          end: i + m,
          rects: _rectsFor(i, i + m),
        ));
        i += m; // non-overlapping
      } else {
        i++;
      }
    }
    return out;
  }

  bool _isWordBoundary(int start, int end) {
    final beforeOk = start == 0 || !_isWordChar(text.codeUnitAt(start - 1));
    final afterOk =
        end >= text.length || !_isWordChar(text.codeUnitAt(end));
    return beforeOk && afterOk;
  }

  List<Aabb> _rectsFor(int start, int end) {
    final boxes = <Aabb>[];
    for (var k = start; k < end; k++) {
      final b = charBoxes[k];
      if (b != null) boxes.add(b);
    }
    return mergeBoxesIntoLines(boxes);
  }
}

/// Accumulates matches across pages and tracks the active match.
///
/// Pages are expected to be added in ascending order so [matches] stays in
/// document reading order; the active index defaults to the first match found.
class SearchResults {
  final List<SearchMatch> _all = <SearchMatch>[];
  int _active = -1;
  String query = '';

  List<SearchMatch> get matches => List<SearchMatch>.unmodifiable(_all);
  int get length => _all.length;
  bool get isEmpty => _all.isEmpty;
  bool get isNotEmpty => _all.isNotEmpty;
  int get activeIndex => _active;

  SearchMatch? get active =>
      (_active >= 0 && _active < _all.length) ? _all[_active] : null;

  void clear() {
    _all.clear();
    _active = -1;
    query = '';
  }

  /// Append a page's matches. No-op for an empty list. Activates the first
  /// match the first time any matches are added.
  void addPage(List<SearchMatch> pageMatches) {
    if (pageMatches.isEmpty) return;
    _all.addAll(pageMatches);
    if (_active == -1) _active = 0;
  }

  /// Advance to the next match (wraps to the first).
  SearchMatch? next() {
    if (_all.isEmpty) return null;
    _active = (_active + 1) % _all.length;
    return active;
  }

  /// Step to the previous match (wraps to the last).
  SearchMatch? previous() {
    if (_all.isEmpty) return null;
    _active = (_active - 1 + _all.length) % _all.length;
    return active;
  }

  /// Make the match at [index] active. Out-of-range values are ignored.
  void setActive(int index) {
    if (index >= 0 && index < _all.length) _active = index;
  }

  List<SearchMatch> matchesOnPage(int pageIndex) =>
      <SearchMatch>[for (final m in _all) if (m.pageIndex == pageIndex) m];
}
