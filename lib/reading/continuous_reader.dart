// continuous_reader.dart
//
// A continuous vertical-scroll reading view. Pages are laid out with exact
// per-page extents from the tested ContinuousLayout, so scroll position maps
// precisely to pages and jump-to-page is exact without building every page.
// Each visible page is rendered once via pdfrx into a ui.Image held in a small
// bounded cache (disposed on eviction and on close). This mode is view-only —
// deep zoom and markup live in the single-page mode.

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'scroll_layout.dart';
import '../thumbnails/thumbnail_model.dart';
import '../theme/app_theme.dart';

/// Lets the host drive the reader (jump to a page) without a GlobalKey.
class ContinuousReaderController {
  _ContinuousReaderState? _state;

  void _attach(_ContinuousReaderState s) => _state = s;
  void _detach(_ContinuousReaderState s) {
    if (identical(_state, s)) _state = null;
  }

  bool get isAttached => _state != null;

  /// Scrolls so page [index] (0-based) is at the top of the viewport.
  void jumpToPage(int index) => _state?._jumpToPage(index);
}

class ContinuousReader extends StatefulWidget {
  final PdfDocument document;
  final int initialPage;
  final ColorFilter? pageFilter;
  final ContinuousReaderController? controller;
  final ValueChanged<int>? onPageChanged;
  final ValueChanged<int>? onOpenPage;

  const ContinuousReader({
    super.key,
    required this.document,
    required this.initialPage,
    this.pageFilter,
    this.controller,
    this.onPageChanged,
    this.onOpenPage,
  });

  @override
  State<ContinuousReader> createState() => _ContinuousReaderState();
}

class _ContinuousReaderState extends State<ContinuousReader> {
  static const double _hMargin = 12; // side margin around each page
  static const double _gap = 14; // vertical gap between pages
  static const int _maxPx = 1200; // render width cap (memory bound)

  final ScrollController _scroll = ScrollController();
  late final ThumbnailCache<ui.Image> _cache;
  final Set<int> _inFlight = <int>{};

  ContinuousLayout? _layout;
  double _lastWidth = -1;
  double _dpr = 1;
  int _currentPage = 0;
  bool _didInitialJump = false;
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _currentPage = widget.initialPage;
    _cache = ThumbnailCache<ui.Image>(6, onEvict: (_, img) => img.dispose());
    widget.controller?._attach(this);
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _disposed = true;
    widget.controller?._detach(this);
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    _cache.clear();
    super.dispose();
  }

  void _jumpToPage(int index) {
    final layout = _layout;
    if (layout == null || !_scroll.hasClients) return;
    final max = _scroll.position.maxScrollExtent;
    final off = layout.offsetOfPage(index).clamp(0.0, max);
    _scroll.jumpTo(off);
    _currentPage = index;
  }

  void _onScroll() {
    final layout = _layout;
    if (layout == null || !_scroll.hasClients) return;
    final center = _scroll.offset + _scroll.position.viewportDimension / 2;
    final p = layout.pageAtOffset(center);
    if (p != _currentPage) {
      _currentPage = p;
      widget.onPageChanged?.call(p);
    }
  }

  Future<void> _ensure(int index, int pixelWidth) async {
    if (_disposed || _cache.contains(index) || _inFlight.contains(index)) {
      return;
    }
    _inFlight.add(index);
    try {
      final page = widget.document.pages[index];
      final h = (pixelWidth * page.height / page.width).round();
      final rendered = await page.render(
        width: pixelWidth,
        height: h < 1 ? 1 : h,
        backgroundColor: const Color(0xFFFFFFFF),
      );
      if (_disposed || rendered == null) {
        rendered?.dispose();
        return;
      }
      final image = await rendered.createImage();
      rendered.dispose();
      if (_disposed) {
        image.dispose();
        return;
      }
      _cache.put(index, image);
      if (mounted) setState(() {});
    } catch (_) {
      // Leave the placeholder if a page fails to render.
    } finally {
      _inFlight.remove(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        _dpr = MediaQuery.of(context).devicePixelRatio;
        if (_layout == null || width != _lastWidth) {
          _lastWidth = width;
          final pageWidth = math.max(1.0, width - 2 * _hMargin);
          _layout = ContinuousLayout(
            pages: [
              for (final p in widget.document.pages)
                PageMetric(p.width, p.height),
            ],
            viewportWidth: pageWidth,
            gap: _gap,
          );
          if (!_didInitialJump) {
            _didInitialJump = true;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (!_disposed) _jumpToPage(widget.initialPage);
            });
          }
        }

        final layout = _layout!;
        if (layout.isEmpty) return const SizedBox.shrink();
        final pixelWidth =
            math.min(_maxPx, (layout.displayWidth * _dpr).round());

        return ListView.builder(
          controller: _scroll,
          itemCount: layout.count,
          itemExtentBuilder: (index, _) => layout.itemExtent(index),
          itemBuilder: (context, i) {
            _ensure(i, pixelWidth);
            return _ReaderPage(
              width: layout.displayWidth,
              height: layout.displayHeight(i),
              gap: _gap,
              image: _cache.get(i),
              filter: widget.pageFilter,
              onTap: () => widget.onOpenPage?.call(i),
            );
          },
        );
      },
    );
  }
}

class _ReaderPage extends StatelessWidget {
  final double width;
  final double height;
  final double gap;
  final ui.Image? image;
  final ColorFilter? filter;
  final VoidCallback onTap;

  const _ReaderPage({
    required this.width,
    required this.height,
    required this.gap,
    required this.image,
    required this.filter,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = image;
    Widget content;
    if (img == null) {
      content = Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: scheme.outlineVariant,
          ),
        ),
      );
    } else {
      final raw = RawImage(image: img, fit: BoxFit.fill);
      content = filter == null
          ? raw
          : ColorFiltered(colorFilter: filter!, child: raw);
    }

    return Padding(
      padding: EdgeInsets.only(bottom: gap),
      child: Center(
        child: Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: scheme.outlineVariant, width: 1),
            boxShadow: [
              BoxShadow(
                color: AppColors.ink.withValues(alpha: 0.10),
                blurRadius: 10,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: content,
          ),
        ),
      ),
    );
  }
}
