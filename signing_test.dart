// page_model.dart
//
// Feature 5 — Page operations & scan assembly (document page-list model).
//
// Represents a document's page order and per-page rotation WITHOUT touching real
// PDF bytes, so reorder/rotate/delete/insert/duplicate/merge can be modeled and
// tested deterministically. A PageEntry points at an original page in some
// source (sourceId + sourcePage) — for assembled scans, sourceId is an image id.
// Applying the resulting plan to actual PDF bytes (PDFium/PdfBox) is native.

/// Identifies an original page in a source document (or an image, for scans).
final class PageRef {
  final String sourceId;
  final int sourcePage;
  const PageRef(this.sourceId, this.sourcePage);

  @override
  bool operator ==(Object other) =>
      other is PageRef &&
      other.sourceId == sourceId &&
      other.sourcePage == sourcePage;

  @override
  int get hashCode => Object.hash(sourceId, sourcePage);

  @override
  String toString() => '$sourceId#$sourcePage';
}

/// A page in the working document: a source page plus a quarter-turn rotation
/// (0,1,2,3 = 0/90/180/270 clockwise). Immutable; [rotated] returns a new entry.
final class PageEntry {
  final PageRef source;
  final int rotationQuarter;

  PageEntry(this.source, [int rotation = 0])
      : rotationQuarter = ((rotation % 4) + 4) % 4;

  PageEntry rotated(int quarters) =>
      PageEntry(source, rotationQuarter + quarters);

  @override
  bool operator ==(Object other) =>
      other is PageEntry &&
      other.source == source &&
      other.rotationQuarter == rotationQuarter;

  @override
  int get hashCode => Object.hash(source, rotationQuarter);

  @override
  String toString() => '$source@${rotationQuarter * 90}';
}

/// Ordered, mutable list of pages with bounds-checked primitive operations.
/// Commands (page_commands.dart) drive these; nothing here mutates without an
/// explicit call, keeping revert logic simple.
final class PageListDocument {
  final List<PageEntry> _pages;

  PageListDocument(List<PageEntry> pages) : _pages = List<PageEntry>.of(pages);

  /// Builds a document of [pageCount] pages all drawn from one source.
  factory PageListDocument.fromSource(String sourceId, int pageCount) {
    if (pageCount < 0) throw ArgumentError('pageCount must be >= 0');
    return PageListDocument(
      List.generate(pageCount, (i) => PageEntry(PageRef(sourceId, i))),
    );
  }

  int get pageCount => _pages.length;
  bool get isEmpty => _pages.isEmpty;
  List<PageEntry> get pages => List.unmodifiable(_pages);

  PageEntry entryAt(int i) {
    _check(i);
    return _pages[i];
  }

  void insert(int i, PageEntry e) {
    if (i < 0 || i > _pages.length) {
      throw RangeError.range(i, 0, _pages.length, 'i', 'insert index');
    }
    _pages.insert(i, e);
  }

  PageEntry removeAt(int i) {
    _check(i);
    return _pages.removeAt(i);
  }

  void setEntry(int i, PageEntry e) {
    _check(i);
    _pages[i] = e;
  }

  void _check(int i) {
    if (i < 0 || i >= _pages.length) {
      throw RangeError.range(i, 0, _pages.length - 1, 'i', 'page index');
    }
  }

  PageListDocument copy() => PageListDocument(_pages);

  /// Page indices grouped into chunks of [n] (the last chunk may be shorter).
  List<List<int>> splitRangesEvery(int n) {
    if (n < 1) throw ArgumentError('n must be >= 1');
    final out = <List<int>>[];
    for (var start = 0; start < _pages.length; start += n) {
      final end = (start + n) > _pages.length ? _pages.length : start + n;
      out.add([for (var i = start; i < end; i++) i]);
    }
    return out;
  }

  /// A new document containing only [indices] (in the given order). Used for
  /// "extract pages" / split export.
  PageListDocument extractPages(List<int> indices) {
    for (final i in indices) {
      _check(i);
    }
    return PageListDocument([for (final i in indices) _pages[i]]);
  }

  /// Compact signature for tests/diffing (e.g. ["doc#0@0", "doc#2@90"]).
  List<String> signature() => _pages.map((e) => e.toString()).toList();
}
