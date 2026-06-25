// viewer_screen.dart
//
// The reading surface: an immersive, content-first viewport with the floating
// instrument dock (annotation tools) and a frosted page-nav pill anchored at the
// bottom. Document actions (undo / redo / save) live in the app bar; the empty
// state is an invitation, not a dead end.

import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:pdfrx/pdfrx.dart';

import '../viewport/pdf_viewport.dart';
import '../annotations/annotation_store.dart';
import '../annotations/annotation_overlay.dart';
import '../annotations/annotation_writer.dart';
import '../annotations/instrument_dock.dart';
import '../search/document_search_controller.dart';
import '../outline/outline_model.dart';
import '../outline/outline_loader.dart';
import '../thumbnails/thumbnail_panel.dart';
import '../reading/continuous_reader.dart';
import '../theme/app_theme.dart';

class ViewerScreen extends StatefulWidget {
  const ViewerScreen({super.key});

  @override
  State<ViewerScreen> createState() => _ViewerScreenState();
}

class _ViewerScreenState extends State<ViewerScreen> {
  PdfDocument? _doc;
  String? _path;
  int _pageIndex = 0;
  bool _loading = false;
  bool _saving = false;
  String? _error;

  final Map<int, AnnotationStore> _stores = <int, AnnotationStore>{};
  AnnotationController? _annot;

  DocumentSearchController? _search;
  final TextEditingController _searchField = TextEditingController();
  bool _searchMode = false;
  Timer? _debounce;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  DocumentOutline? _outline;

  ReadingMode _mode = ReadingMode.paper;

  bool _continuous = false;
  final ContinuousReaderController _reader = ContinuousReaderController();

  void _cycleMode() => setState(() => _mode = _mode.next);

  void _toggleContinuous() {
    setState(() => _continuous = !_continuous);
    if (!_continuous) _bindController(); // re-sync markup to the current page
  }

  // The reader reports the page under the viewport centre while scrolling.
  void _onReaderPage(int i) {
    if (i != _pageIndex) setState(() => _pageIndex = i);
  }

  // Tapping a page in the reader opens it in single-page (markup) mode.
  void _openInPageMode(int i) {
    final doc = _doc;
    if (doc == null) return;
    setState(() {
      _pageIndex = i.clamp(0, doc.pages.length - 1);
      _continuous = false;
    });
    _bindController();
  }

  Future<void> _openThumbnails() async {
    final doc = _doc;
    if (doc == null) return;
    final picked = await ThumbnailPanel.show(context, doc, _pageIndex);
    if (picked != null) _goToPage(picked);
  }

  IconData _modeIcon(ReadingMode m) => switch (m) {
        ReadingMode.paper => Icons.light_mode_outlined,
        ReadingMode.sepia => Icons.local_cafe_outlined,
        ReadingMode.night => Icons.dark_mode_outlined,
      };

  void _goToPage(int page) {
    final doc = _doc;
    if (doc == null) return;
    final next = page.clamp(0, doc.pages.length - 1);
    if (next != _pageIndex) {
      setState(() => _pageIndex = next);
      if (!_continuous) _bindController();
    }
    if (_continuous) _reader.jumpToPage(next);
  }

  Future<void> _loadOutlineFor(PdfDocument doc) async {
    try {
      final outline = await loadDocumentOutline(doc);
      if (mounted && identical(_doc, doc)) {
        setState(() => _outline = outline);
      }
    } catch (_) {
      // A missing or malformed outline simply means no contents panel.
    }
  }

  void _onSearchChanged() {
    final a = _search?.active;
    if (a != null && a.pageIndex != _pageIndex) {
      _pageIndex = a.pageIndex;
      _bindController();
    }
    if (mounted) setState(() {});
  }

  void _runSearch(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 280), () {
      _search?.search(query);
    });
  }

  void _enterSearch() => setState(() => _searchMode = true);

  void _exitSearch() {
    _debounce?.cancel();
    _searchField.clear();
    _search?.clear();
    setState(() => _searchMode = false);
  }

  void _bindController() {
    _annot?.dispose();
    final store = _stores.putIfAbsent(_pageIndex, () => AnnotationStore());
    _annot = AnnotationController(store: store, pageIndex: _pageIndex);
  }

  Future<void> _openFile() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['pdf'],
      );
      final path = result?.files.single.path;
      if (path == null) {
        setState(() => _loading = false);
        return;
      }
      final doc = await PdfDocument.openFile(path);
      _doc?.dispose();
      _stores.clear();
      setState(() {
        _doc = doc;
        _path = path;
        _pageIndex = 0;
        _loading = false;
      });
      _bindController();
      _search?.dispose();
      _search = DocumentSearchController(doc)..addListener(_onSearchChanged);
      _searchField.clear();
      _searchMode = false;
      _outline = null;
      _loadOutlineFor(doc);
    } catch (e) {
      setState(() {
        _error = 'Could not open that PDF. It may be damaged or password-protected.';
        _loading = false;
      });
    }
  }

  void _go(int delta) => _goToPage(_pageIndex + delta);

  String _outPath(String src) {
    final lower = src.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return '${src.substring(0, src.length - 4)}-annotated.pdf';
    }
    return '$src-annotated.pdf';
  }

  String _baseName(String? path) {
    if (path == null) return 'Ultimate PDF';
    final parts = path.split('/');
    return parts.isEmpty ? path : parts.last;
  }

  Future<void> _save() async {
    final src = _path;
    if (src == null || _saving) return;
    final total = _stores.values.fold<int>(0, (n, s) => n + s.length);
    if (total == 0) {
      _toast('Nothing to save yet — add a mark first.');
      return;
    }
    setState(() => _saving = true);
    try {
      final out = await PdfAnnotationWriter.burnStores(
        srcPath: src,
        outPath: _outPath(src),
        stores: _stores.values,
      );
      _toast('Saved to ${_baseName(out)}');
    } on AnnotationWriteException catch (e) {
      _toast('Save failed: ${e.message}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchField.dispose();
    _search?.dispose();
    _annot?.dispose();
    _doc?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final doc = _doc;
    final hasDoc = doc != null && _annot != null;
    final hasOutline = hasDoc && _outline != null && _outline!.isNotEmpty;

    return Scaffold(
      key: _scaffoldKey,
      extendBodyBehindAppBar: hasDoc,
      drawer: hasOutline ? _outlineDrawer() : null,
      appBar: _appBar(hasDoc, hasOutline),
      body: _buildBody(doc),
    );
  }

  PreferredSizeWidget _appBar(bool hasDoc, bool hasOutline) {
    if (_searchMode && _search != null) {
      return AppBar(
        titleSpacing: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'Close search',
          onPressed: _exitSearch,
        ),
        title: TextField(
          controller: _searchField,
          autofocus: true,
          textInputAction: TextInputAction.search,
          decoration: const InputDecoration(
            border: InputBorder.none,
            hintText: 'Find in document',
          ),
          onChanged: _runSearch,
          onSubmitted: (_) => _search!.next(),
        ),
        actions: [
          ListenableBuilder(
            listenable: _search!,
            builder: (context, _) {
              final total = _search!.total;
              final label = total == 0
                  ? (_search!.isRunning ? '…' : '0')
                  : '${_search!.activeIndex + 1}/$total';
              final enabled = total > 0;
              return Row(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: Text(label,
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13)),
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_up),
                    tooltip: 'Previous match',
                    onPressed: enabled ? () => _search!.previous() : null,
                  ),
                  IconButton(
                    icon: const Icon(Icons.keyboard_arrow_down),
                    tooltip: 'Next match',
                    onPressed: enabled ? () => _search!.next() : null,
                  ),
                ],
              );
            },
          ),
          const SizedBox(width: 4),
        ],
      );
    }

    return AppBar(
      automaticallyImplyLeading: false,
      leading: hasOutline
          ? IconButton(
              icon: const Icon(Icons.toc),
              tooltip: 'Contents',
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            )
          : null,
      title: Text(_baseName(_path), overflow: TextOverflow.ellipsis),
      actions: [
        if (hasDoc) ...[
          IconButton(
            icon: Icon(_continuous
                ? Icons.article_outlined
                : Icons.view_day_outlined),
            tooltip: _continuous ? 'Single page' : 'Continuous scroll',
            onPressed: _toggleContinuous,
          ),
          IconButton(
            icon: const Icon(Icons.search),
            tooltip: 'Find in document',
            onPressed: _enterSearch,
          ),
          _saving
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(Icons.save_outlined),
                  tooltip: 'Save annotated copy',
                  onPressed: _save,
                ),
        ],
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: 'Open a document',
          onPressed: _loading ? null : _openFile,
        ),
        const SizedBox(width: 4),
      ],
    );
  }

  Widget _outlineDrawer() {
    final outline = _outline!;
    final active = outline.activeEntryForPage(_pageIndex);
    final items = outline.visibleItems();
    return Drawer(
      width: 320,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 8, 12),
              child: Row(
                children: [
                  Text('Contents',
                      style: Theme.of(context).textTheme.titleLarge),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.close),
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: items.length,
                itemBuilder: (context, i) =>
                    _outlineRow(outline, items[i], active),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _outlineRow(
      DocumentOutline outline, FlatOutlineItem item, OutlineEntry? active) {
    final scheme = Theme.of(context).colorScheme;
    final isActive = identical(item.entry, active);
    final navigable = item.pageIndex != null;
    return InkWell(
      onTap: navigable
          ? () {
              _goToPage(item.pageIndex!);
              Navigator.of(context).pop();
            }
          : null,
      child: Container(
        color: isActive ? scheme.primary.withValues(alpha: 0.10) : null,
        padding: EdgeInsets.only(
          left: 12.0 + item.depth * 16.0,
          right: 8,
          top: 10,
          bottom: 10,
        ),
        child: Row(
          children: [
            SizedBox(
              width: 28,
              child: item.hasChildren
                  ? IconButton(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        item.expanded
                            ? Icons.keyboard_arrow_down
                            : Icons.keyboard_arrow_right,
                        size: 20,
                      ),
                      onPressed: () =>
                          setState(() => outline.toggle(item.entry)),
                    )
                  : const SizedBox.shrink(),
            ),
            Expanded(
              child: Text(
                item.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.3,
                  fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  color: navigable
                      ? (isActive ? scheme.primary : scheme.onSurface)
                      : scheme.onSurfaceVariant,
                ),
              ),
            ),
            if (navigable)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: Text(
                  '${item.pageIndex! + 1}',
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(PdfDocument? doc) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _MessageState(
        icon: Icons.error_outline,
        title: 'That file would not open',
        body: _error!,
        actionLabel: 'Choose another file',
        onAction: _openFile,
      );
    }
    if (doc == null || _annot == null) {
      return _emptyState();
    }

    final pageCount = doc.pages.length;

    if (_continuous) {
      return Stack(
        children: [
          Positioned.fill(child: ColoredBox(color: _mode.canvasColor)),
          Positioned.fill(
            child: ContinuousReader(
              document: doc,
              initialPage: _pageIndex,
              pageFilter: _mode.pageFilter,
              controller: _reader,
              onPageChanged: _onReaderPage,
              onOpenPage: _openInPageMode,
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              minimum: const EdgeInsets.only(bottom: 12),
              child: _pageNavPill(pageCount),
            ),
          ),
        ],
      );
    }

    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: _mode.canvasColor)),
        Positioned.fill(
          child: PdfViewport(
            key: ValueKey<int>(_pageIndex),
            page: doc.pages[_pageIndex],
            annotationController: _annot,
            searchRects: _search?.rectsOnPage(_pageIndex) ?? const [],
            activeSearchRects:
                _search?.activeRectsOnPage(_pageIndex) ?? const [],
            pageFilter: _mode.pageFilter,
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            top: false,
            minimum: const EdgeInsets.only(bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(child: InstrumentDock(controller: _annot!)),
                const SizedBox(height: 10),
                _pageNavPill(pageCount),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _pageNavPill(int pageCount) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = (isDark ? AppColors.slateSurface : Colors.white)
        .withValues(alpha: 0.9);
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(999),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: Icon(_modeIcon(_mode), size: 20),
                  tooltip: 'Reading mode: ${_mode.label}',
                  onPressed: _cycleMode,
                ),
                Container(
                    width: 1, height: 22, color: scheme.outlineVariant),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.grid_view_rounded, size: 19),
                  tooltip: 'Page thumbnails',
                  onPressed: _openThumbnails,
                ),
                Container(
                    width: 1, height: 22, color: scheme.outlineVariant),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_left, size: 22),
                  onPressed: _pageIndex > 0 ? () => _go(-1) : null,
                ),
                Text(
                  '${_pageIndex + 1} / $pageCount',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                    color: scheme.onSurface,
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.chevron_right, size: 22),
                  onPressed:
                      _pageIndex < pageCount - 1 ? () => _go(1) : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState() {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: scheme.primary,
                borderRadius: BorderRadius.circular(22),
                boxShadow: [
                  BoxShadow(
                    color: scheme.primary.withValues(alpha: 0.4),
                    blurRadius: 28,
                    offset: const Offset(0, 12),
                  ),
                ],
              ),
              child: Icon(Icons.architecture,
                  size: 40, color: scheme.onPrimary),
            ),
            const SizedBox(height: 22),
            Text('Ultimate PDF',
                style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 8),
            Text(
              'A calm place to read and mark up.',
              style: TextStyle(
                  fontSize: 14, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 26),
            FilledButton.icon(
              onPressed: _openFile,
              icon: const Icon(Icons.menu_book_outlined, size: 18),
              label: const Text('Open a document'),
            ),
            const SizedBox(height: 14),
            Text(
              'Private by design — files never leave your device.',
              style: TextStyle(
                  fontSize: 12, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 30),
            Wrap(
              spacing: 8,
              children: [
                _FeatureChip(icon: Icons.draw, label: 'Annotate', dark: isDark),
                _FeatureChip(
                    icon: Icons.search, label: 'Search', dark: isDark),
                _FeatureChip(
                    icon: Icons.toc, label: 'Contents', dark: isDark),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FeatureChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool dark;
  const _FeatureChip(
      {required this.icon, required this.label, required this.dark});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: dark ? AppColors.slateSurface : Colors.white,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: scheme.onSurfaceVariant),
          const SizedBox(width: 6),
          Text(label,
              style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: dark ? AppColors.slateText : AppColors.ink2)),
        ],
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String actionLabel;
  final VoidCallback onAction;

  const _MessageState({
    required this.icon,
    required this.title,
    required this.body,
    required this.actionLabel,
    required this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 44, color: scheme.onSurfaceVariant),
            const SizedBox(height: 16),
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(body,
                textAlign: TextAlign.center,
                style: TextStyle(color: scheme.onSurfaceVariant)),
            const SizedBox(height: 22),
            FilledButton(onPressed: onAction, child: Text(actionLabel)),
          ],
        ),
      ),
    );
  }
}
