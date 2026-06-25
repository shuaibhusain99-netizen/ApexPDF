// thumbnail_panel.dart
//
// A full-screen page browser. Renders each page once via pdfrx into a ui.Image,
// held in the tested bounded ThumbnailCache (so a long document cannot accumulate
// unbounded images — evicted and closed images are disposed). GridView.builder
// renders only visible cells; tapping a page returns its index to the caller.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:pdfrx/pdfrx.dart';

import 'thumbnail_model.dart';
import '../theme/app_theme.dart';

class ThumbnailPanel extends StatefulWidget {
  final PdfDocument document;
  final int currentPage;

  const ThumbnailPanel({
    super.key,
    required this.document,
    required this.currentPage,
  });

  /// Opens the panel and resolves to the selected 0-based page, or null.
  static Future<int?> show(
    BuildContext context,
    PdfDocument document,
    int currentPage,
  ) {
    return Navigator.of(context).push<int>(
      MaterialPageRoute<int>(
        builder: (_) =>
            ThumbnailPanel(document: document, currentPage: currentPage),
      ),
    );
  }

  @override
  State<ThumbnailPanel> createState() => _ThumbnailPanelState();
}

class _ThumbnailPanelState extends State<ThumbnailPanel> {
  // Render target width in pixels — crisp on phone-sized cells.
  static const int _targetPx = 220;

  late final ThumbnailCache<ui.Image> _cache;
  final Set<int> _inFlight = <int>{};
  bool _disposed = false;

  @override
  void initState() {
    super.initState();
    _cache = ThumbnailCache<ui.Image>(80, onEvict: (_, img) => img.dispose());
  }

  @override
  void dispose() {
    _disposed = true;
    _cache.clear(); // disposes every resident image
    super.dispose();
  }

  Future<void> _ensure(int index) async {
    if (_disposed || _cache.contains(index) || _inFlight.contains(index)) {
      return;
    }
    _inFlight.add(index);
    try {
      final page = widget.document.pages[index];
      const w = _targetPx;
      final h = (w * page.height / page.width).round();
      final rendered = await page.render(
        width: w,
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
      // Skip a page that fails to render; its cell keeps the placeholder.
    } finally {
      _inFlight.remove(index);
    }
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.document.pages.length;
    return Scaffold(
      appBar: AppBar(
        title: Text('Pages · $count'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Close',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.all(16),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          maxCrossAxisExtent: 150,
          mainAxisSpacing: 18,
          crossAxisSpacing: 14,
          childAspectRatio: 0.66,
        ),
        itemCount: count,
        itemBuilder: (context, i) {
          _ensure(i); // dedup'd; no setState before its first await
          return _ThumbCell(
            index: i,
            image: _cache.get(i), // refreshes recency for visible cells
            isCurrent: i == widget.currentPage,
            onTap: () => Navigator.of(context).pop(i),
          );
        },
      ),
    );
  }
}

class _ThumbCell extends StatelessWidget {
  final int index;
  final ui.Image? image;
  final bool isCurrent;
  final VoidCallback onTap;

  const _ThumbCell({
    required this.index,
    required this.image,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final img = image;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: isCurrent ? scheme.primary : scheme.outlineVariant,
                  width: isCurrent ? 2.5 : 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.ink.withValues(alpha: 0.10),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: img == null
                  ? Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: scheme.outlineVariant,
                        ),
                      ),
                    )
                  : RawImage(image: img, fit: BoxFit.contain),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '${index + 1}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: isCurrent ? FontWeight.w700 : FontWeight.w500,
              color: isCurrent ? scheme.primary : scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
