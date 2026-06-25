// scroll_layout.dart
//
// Continuous (vertical) reading layout. Pure Dart, fully testable, no Flutter:
// given each page's intrinsic size, a viewport width, and an inter-page gap, it
// lays pages out fit-to-width in a single column and answers the questions a
// scroll view needs — per-item extent, total height, which page sits at a scroll
// offset (O(log n)), the visible range, and the offset that brings a page to top.

import 'dart:math' as math;

/// A page's intrinsic size in PDF points.
class PageMetric {
  final double width;
  final double height;
  const PageMetric(this.width, this.height);
}

class ContinuousLayout {
  /// Logical width pages are laid out at (full column width).
  final double viewportWidth;

  /// Vertical gap rendered below each page.
  final double gap;

  final List<double> _displayHeight; // fit-to-width display height per page
  final List<double> _top; // cumulative top offset of each page's extent
  final double _totalHeight;

  const ContinuousLayout._(
    this.viewportWidth,
    this.gap,
    this._displayHeight,
    this._top,
    this._totalHeight,
  );

  /// Builds the layout in a single pass over [pages].
  factory ContinuousLayout({
    required List<PageMetric> pages,
    required double viewportWidth,
    double gap = 12,
  }) {
    final displayHeight = List<double>.filled(pages.length, 0);
    final top = List<double>.filled(pages.length, 0);
    var y = 0.0;
    for (var i = 0; i < pages.length; i++) {
      final p = pages[i];
      final h = (p.width > 0) ? p.height * (viewportWidth / p.width) : 0.0;
      displayHeight[i] = h;
      top[i] = y;
      y += h + gap; // trailing gap after each page (incl. the last)
    }
    return ContinuousLayout._(viewportWidth, gap, displayHeight, top, y);
  }

  int get count => _displayHeight.length;
  bool get isEmpty => count == 0;
  double get totalHeight => _totalHeight;
  double get displayWidth => viewportWidth;

  double displayHeight(int index) => _displayHeight[index];

  /// Extent of item [index] for a scroll view (page height + trailing gap).
  double itemExtent(int index) => _displayHeight[index] + gap;

  /// Top offset that scrolls page [index] to the top of the viewport.
  double offsetOfPage(int index) {
    if (isEmpty) return 0;
    final i = index < 0 ? 0 : (index >= count ? count - 1 : index);
    return _top[i];
  }

  /// The page whose extent contains scroll offset [y] (clamped to range).
  int pageAtOffset(double y) {
    if (isEmpty) return 0;
    if (y <= 0) return 0;
    if (y >= _totalHeight) return count - 1;
    var lo = 0, hi = count - 1, ans = 0; // largest index with _top[index] <= y
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (_top[mid] <= y) {
        ans = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return ans;
  }

  /// Inclusive [first, last] page indices intersecting the scroll window.
  (int, int) visibleRange(double scrollTop, double viewportHeight) {
    if (isEmpty) return (0, 0);
    final first = pageAtOffset(scrollTop);
    final last = pageAtOffset(scrollTop + math.max(0, viewportHeight));
    return (first, last);
  }
}
