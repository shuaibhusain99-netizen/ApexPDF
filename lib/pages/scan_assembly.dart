// scan_assembly.dart
//
// Feature 5 — Scan-to-PDF assembly.
//
// Turns an ordered set of captured page images into a document plan. The image
// capture (camera / ML Kit document scanner) and the actual image->PDF byte
// assembly are native; the ordering, rotation, and page-size derivation here are
// pure Dart and tested.

import 'page_model.dart';

/// One captured page image destined to become a PDF page.
final class ScanPage {
  final String imageRef; // opaque id the native side resolves to image bytes
  final double widthPx;
  final double heightPx;
  final double dpi;
  final int rotationQuarter;

  ScanPage({
    required this.imageRef,
    required this.widthPx,
    required this.heightPx,
    this.dpi = 200,
    int rotation = 0,
  }) : rotationQuarter = ((rotation % 4) + 4) % 4 {
    if (imageRef.isEmpty) throw ArgumentError('imageRef must not be empty');
    if (!(widthPx > 0) || !(heightPx > 0)) {
      throw ArgumentError('image pixel dimensions must be positive');
    }
    if (!(dpi > 0)) throw ArgumentError('dpi must be positive');
  }

  /// Physical page size in PDF points (72 pt = 1 inch). Rotation does not change
  /// the stored size here; the native renderer applies the quarter turn.
  (double, double) pageSizePt() =>
      (widthPx / dpi * 72.0, heightPx / dpi * 72.0);
}

abstract final class ScanAssembler {
  /// Builds a page-list document where each scan image is one page.
  static PageListDocument toDocument(List<ScanPage> pages) => PageListDocument([
        for (final p in pages)
          PageEntry(PageRef(p.imageRef, 0), p.rotationQuarter),
      ]);

  /// Native-assembler plan: per-page image ref, page size (points), rotation.
  static List<Map<String, Object?>> toPlan(List<ScanPage> pages) => [
        for (final p in pages)
          () {
            final (w, h) = p.pageSizePt();
            return <String, Object?>{
              'image': p.imageRef,
              'pw': w,
              'ph': h,
              'rot': p.rotationQuarter,
              'dpi': p.dpi,
            };
          }(),
      ];
}
