// document_search_controller.dart
//
// Bridges pdfrx text extraction to the tested search core. Extraction is async,
// cached per page, and cancellable: starting a new query (or clearing) supersedes
// any in-flight run via a generation counter, so typing never piles up work.

import 'package:flutter/foundation.dart';
import 'package:pdfrx/pdfrx.dart';

import '../engine/viewport_core.dart';
import 'search_model.dart';

enum SearchStatus { idle, running, done }

class DocumentSearchController extends ChangeNotifier {
  DocumentSearchController(this._doc);

  final PdfDocument _doc;
  final SearchResults _results = SearchResults();
  final Map<int, PageText> _cache = <int, PageText>{};

  SearchStatus _status = SearchStatus.idle;
  String _query = '';
  int _gen = 0;

  SearchStatus get status => _status;
  String get query => _query;
  bool get hasQuery => _query.isNotEmpty;
  bool get isRunning => _status == SearchStatus.running;

  int get total => _results.length;
  int get activeIndex => _results.activeIndex;
  SearchMatch? get active => _results.active;

  /// Merged highlight rects (world space) for every match on [pageIndex].
  List<Aabb> rectsOnPage(int pageIndex) {
    final out = <Aabb>[];
    for (final m in _results.matchesOnPage(pageIndex)) {
      out.addAll(m.rects);
    }
    return out;
  }

  /// Merged highlight rects (world space) for the active match, if it is on
  /// [pageIndex]; otherwise empty.
  List<Aabb> activeRectsOnPage(int pageIndex) {
    final a = _results.active;
    if (a == null || a.pageIndex != pageIndex) return const <Aabb>[];
    return a.rects;
  }

  /// Run a new search. Empty query clears results.
  Future<void> search(
    String query, {
    SearchOptions options = const SearchOptions(),
  }) async {
    _query = query;
    final myGen = ++_gen;
    _results.clear();
    _results.query = query;

    if (query.isEmpty) {
      _status = SearchStatus.idle;
      notifyListeners();
      return;
    }

    _status = SearchStatus.running;
    notifyListeners();

    final pageCount = _doc.pages.length;
    for (var i = 0; i < pageCount; i++) {
      if (_gen != myGen) return; // superseded by a newer query
      PageText pt;
      try {
        pt = await _pageText(i);
      } catch (_) {
        continue; // skip a page whose text cannot be read
      }
      if (_gen != myGen) return;

      final matches = pt.findMatches(query, options);
      if (matches.isNotEmpty) {
        _results.addPage(matches);
        notifyListeners(); // surface first hits (and jump target) immediately
      }
      // Yield so a large document does not block the UI thread.
      await Future<void>.delayed(Duration.zero);
    }

    if (_gen != myGen) return;
    _status = SearchStatus.done;
    notifyListeners();
  }

  void clear() {
    ++_gen;
    _query = '';
    _results.clear();
    _status = SearchStatus.idle;
    notifyListeners();
  }

  SearchMatch? next() {
    final m = _results.next();
    notifyListeners();
    return m;
  }

  SearchMatch? previous() {
    final m = _results.previous();
    notifyListeners();
    return m;
  }

  Future<PageText> _pageText(int pageIndex) async {
    final cached = _cache[pageIndex];
    if (cached != null) return cached;

    final page = _doc.pages[pageIndex];
    final pageHeight = page.height;
    final pageText = await page.loadText();
    final full = pageText.fullText;

    // Per-code-unit boxes, converted PDF (y-up) -> world (y-down).
    final boxes = List<Aabb?>.filled(full.length, null);
    for (final f in pageText.fragments) {
      final start = f.index;
      final span = f.end - f.index;
      final rects = f.charRects;
      for (var k = 0; k < span; k++) {
        final pos = start + k;
        if (pos < 0 || pos >= full.length) break;
        final r = k < rects.length ? rects[k] : f.bounds;
        boxes[pos] = Aabb(
          r.left,
          pageHeight - r.top,
          r.right,
          pageHeight - r.bottom,
        );
      }
    }

    final pt = PageText(pageIndex: pageIndex, text: full, charBoxes: boxes);
    _cache[pageIndex] = pt;
    return pt;
  }
}
