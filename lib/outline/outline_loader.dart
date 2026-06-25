// outline_loader.dart
//
// Builds the tested DocumentOutline from pdfrx's outline nodes, resolving each
// node's destination (1-based pageNumber) to a clamped 0-based page index.

import 'package:pdfrx/pdfrx.dart';

import 'outline_model.dart';

Future<DocumentOutline> loadDocumentOutline(PdfDocument doc) async {
  final nodes = await doc.loadOutline();
  final pageCount = doc.pages.length;

  OutlineEntry convert(PdfOutlineNode node) {
    int? pageIndex;
    final dest = node.dest;
    if (dest != null && pageCount > 0) {
      final pi = dest.pageNumber - 1; // pdfrx pageNumber is 1-based
      pageIndex = pi < 0 ? 0 : (pi >= pageCount ? pageCount - 1 : pi);
    }
    return OutlineEntry(
      title: node.title,
      pageIndex: pageIndex,
      children: node.children.map(convert).toList(),
    );
  }

  return DocumentOutline(nodes.map(convert).toList());
}
