// outline_model.dart
//
// Document outline (table of contents / bookmarks) core. Pure Dart, fully
// testable, and decoupled from pdfrx: the app adapter converts pdfrx outline
// nodes into [OutlineEntry] trees (resolving destinations to 0-based page
// indices); this layer owns the navigation logic — flattening with depth,
// expand/collapse, and "which section am I in" for the current page.

/// A node in the outline tree.
class OutlineEntry {
  final String title;

  /// 0-based destination page, or null for a non-navigable heading.
  final int? pageIndex;

  final List<OutlineEntry> children;

  OutlineEntry({
    required this.title,
    this.pageIndex,
    List<OutlineEntry>? children,
  }) : children = children ?? const <OutlineEntry>[];

  bool get hasChildren => children.isNotEmpty;
}

/// A flattened, render-ready row: the entry plus its depth and expansion state.
class FlatOutlineItem {
  final OutlineEntry entry;
  final int depth;
  final bool expanded;
  const FlatOutlineItem(this.entry, this.depth, this.expanded);

  String get title => entry.title;
  int? get pageIndex => entry.pageIndex;
  bool get hasChildren => entry.hasChildren;
}

/// The outline with collapse state and navigation queries.
class DocumentOutline {
  final List<OutlineEntry> roots;

  /// Nodes whose children are hidden. Default: everything expanded.
  final Set<OutlineEntry> _collapsed = <OutlineEntry>{};

  DocumentOutline(this.roots);

  bool get isEmpty => roots.isEmpty;
  bool get isNotEmpty => roots.isNotEmpty;

  int get totalCount {
    var c = 0;
    void walk(List<OutlineEntry> ns) {
      for (final n in ns) {
        c++;
        walk(n.children);
      }
    }

    walk(roots);
    return c;
  }

  bool isExpanded(OutlineEntry e) => !_collapsed.contains(e);

  void toggle(OutlineEntry e) {
    if (!e.hasChildren) return;
    if (_collapsed.contains(e)) {
      _collapsed.remove(e);
    } else {
      _collapsed.add(e);
    }
  }

  void expandAll() => _collapsed.clear();

  void collapseAll() {
    _collapsed.clear();
    void collect(List<OutlineEntry> ns) {
      for (final n in ns) {
        if (n.hasChildren) {
          _collapsed.add(n);
          collect(n.children);
        }
      }
    }

    collect(roots);
  }

  /// The visible rows in reading order, honoring collapse state.
  List<FlatOutlineItem> visibleItems() {
    final out = <FlatOutlineItem>[];
    void walk(List<OutlineEntry> ns, int depth) {
      for (final n in ns) {
        final exp = isExpanded(n);
        out.add(FlatOutlineItem(n, depth, exp));
        if (n.hasChildren && exp) walk(n.children, depth + 1);
      }
    }

    walk(roots, 0);
    return out;
  }

  /// The entry whose destination is the greatest page <= [pageIndex] — i.e. the
  /// section the reader is currently inside. Ties resolve to the later entry in
  /// reading order. Considers the whole tree regardless of collapse state.
  OutlineEntry? activeEntryForPage(int pageIndex) {
    OutlineEntry? best;
    void walk(List<OutlineEntry> ns) {
      for (final n in ns) {
        final p = n.pageIndex;
        if (p != null && p <= pageIndex) {
          if (best == null || p >= best!.pageIndex!) best = n;
        }
        walk(n.children);
      }
    }

    walk(roots);
    return best;
  }
}
