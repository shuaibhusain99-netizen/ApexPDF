// page_serialization.dart
//
// Feature 5 — Page operations & scan assembly (interchange format).
//
// The page-list plan and scan plan are serialized to JSON and handed to the
// native layer that performs the real PDF page-tree edits / image->PDF build.

import 'page_model.dart';
import 'scan_assembly.dart';

abstract final class PageOpsCodec {
  static Map<String, Object?> docToJson(PageListDocument d) => {
        'pages': [
          for (final e in d.pages)
            {
              'src': e.source.sourceId,
              'sp': e.source.sourcePage,
              'rot': e.rotationQuarter,
            }
        ],
      };

  static PageListDocument docFromJson(Map<String, Object?> j) {
    final pages = j['pages'];
    if (pages is! List) throw const FormatException('"pages" must be a List');
    final entries = <PageEntry>[];
    for (final e in pages) {
      if (e is! Map) throw const FormatException('page entry must be a map');
      final m = e.cast<String, Object?>();
      final src = m['src'];
      final sp = m['sp'];
      if (src is! String) throw const FormatException('"src" must be String');
      if (sp is! int) throw const FormatException('"sp" must be int');
      final rot = m['rot'];
      entries.add(PageEntry(PageRef(src, sp), rot is int ? rot : 0));
    }
    return PageListDocument(entries);
  }

  static Map<String, Object?> scanPageToJson(ScanPage p) => {
        'image': p.imageRef,
        'w': p.widthPx,
        'h': p.heightPx,
        'dpi': p.dpi,
        'rot': p.rotationQuarter,
      };

  static ScanPage scanPageFromJson(Map<String, Object?> j) {
    double d(String k) {
      final v = j[k];
      if (v is num) return v.toDouble();
      throw FormatException('"$k" must be a number');
    }

    final image = j['image'];
    if (image is! String) throw const FormatException('"image" must be String');
    final rot = j['rot'];
    return ScanPage(
      imageRef: image,
      widthPx: d('w'),
      heightPx: d('h'),
      dpi: d('dpi'),
      rotation: rot is int ? rot : 0,
    );
  }

  static List<Map<String, Object?>> encodeScanPages(Iterable<ScanPage> ps) =>
      ps.map(scanPageToJson).toList(growable: false);

  static List<ScanPage> decodeScanPages(List<Object?> items) => items
      .map((e) => scanPageFromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);
}
