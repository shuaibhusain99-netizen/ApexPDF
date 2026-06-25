// ocr_text_layer.dart
//
// Feature 3 — Searchable PDF / OCR (invisible text-layer builder).
//
// Turns recognized words (pixel boxes) into a PDF text content stream drawn in
// render mode 3 (invisible): the page image stays visible, but the text is
// selectable and searchable, positioned so selection highlights line up with
// the scanned glyphs. The trick: pick font size from the box height, then set a
// per-word horizontal scale (Tz) so the invisible glyph run's width equals the
// scanned word's width (real glyph metrics won't match the scan).
//
// Pure Dart and unit-tested. The native parts are (a) the OCR recognition that
// produces OcrPage, and (b) assembling the final PDF bytes (embedding the page
// image XObject + a font resource + this content stream) via PdfBox-Android or
// a pure-Dart pdf writer. Non-Latin-1 text needs a Type0/CID font with ToUnicode
// (the native multilingual path, Feature 7) — this builder rejects it explicitly
// rather than silently corrupting searchability.

import 'dart:math' as math;

import 'ocr_model.dart';

/// Maps between image-pixel space (origin top-left, y-down) and PDF user space
/// (origin bottom-left, y-up) for one page.
final class PageGeometry {
  final double imageWidthPx;
  final double imageHeightPx;
  final double pageWidthPt;
  final double pageHeightPt;

  /// Pixel→point scale on each axis (independent; handles aspect differences).
  final double sx;
  final double sy;

  PageGeometry({
    required this.imageWidthPx,
    required this.imageHeightPx,
    required this.pageWidthPt,
    required this.pageHeightPt,
  })  : sx = pageWidthPt / imageWidthPx,
        sy = pageHeightPt / imageHeightPx {
    if (!(imageWidthPx > 0) ||
        !(imageHeightPx > 0) ||
        !(pageWidthPt > 0) ||
        !(pageHeightPt > 0)) {
      throw ArgumentError('all geometry dimensions must be positive');
    }
  }

  /// Image pixel (px,py) → PDF point (x,y). Flips the vertical axis.
  (double, double) pdfPoint(double px, double py) =>
      (px * sx, pageHeightPt - py * sy);
}

/// Estimates the natural advance width (points) of [text] at [fontSizePt] for a
/// simple font. Default models a monospace-ish 0.5em advance per code unit; pass
/// a metrics-backed estimator for tighter selection alignment.
typedef GlyphWidthEstimator = double Function(String text, double fontSizePt);

double _defaultGlyphWidth(String text, double fontSizePt) =>
    text.length * 0.5 * fontSizePt;

/// Resolved placement for one invisible word.
final class TextPlacement {
  final String text;
  final double originXPt; // baseline origin (PDF points)
  final double originYPt;
  final double fontSizePt;
  final double horizScalePercent; // Tz
  final double angleRadians;

  const TextPlacement({
    required this.text,
    required this.originXPt,
    required this.originYPt,
    required this.fontSizePt,
    required this.horizScalePercent,
    required this.angleRadians,
  });

  /// The 6-component text matrix [a b c d e f] (rotation about the origin;
  /// horizontal scale is applied separately via Tz, vertical via font size).
  List<double> get textMatrix {
    final c = math.cos(angleRadians), s = math.sin(angleRadians);
    return <double>[c, s, -s, c, originXPt, originYPt];
  }
}

abstract final class OcrTextLayerBuilder {
  /// Minimum font size to emit (guards degenerate boxes).
  static const double minFontSizePt = 0.5;

  /// Computes placement for a single word.
  static TextPlacement place(
    OcrWord word,
    PageGeometry geom, {
    GlyphWidthEstimator estimator = _defaultGlyphWidth,
  }) {
    final b = word.pixelBounds;
    final fontSize = math.max((b.height) * geom.sy, minFontSizePt);
    final originX = b.minX * geom.sx;
    final originY = geom.pageHeightPt - b.maxY * geom.sy; // box bottom in PDF
    final boxWidthPt = b.width * geom.sx;

    final natural = estimator(word.text, fontSize);
    var tz = 100.0;
    if (natural > 0 && boxWidthPt > 0) {
      tz = (boxWidthPt / natural) * 100.0;
      tz = tz.clamp(1.0, 100000.0);
    }
    return TextPlacement(
      text: word.text,
      originXPt: originX,
      originYPt: originY,
      fontSizePt: fontSize,
      horizScalePercent: tz,
      angleRadians: word.angleRadians,
    );
  }

  /// Builds the full invisible text content stream for a page. Blank words are
  /// skipped. [fontResource] is the resource name (e.g. /F0) the assembler maps
  /// to an embedded font.
  static String buildContentStream(
    OcrPage page,
    PageGeometry geom, {
    GlyphWidthEstimator estimator = _defaultGlyphWidth,
    String fontResource = 'F0',
  }) {
    final out = StringBuffer();
    out.writeln('BT');
    out.writeln('3 Tr'); // invisible render mode (persists until changed)

    double? lastSize;
    double? lastTz;
    for (final w in page.textWords) {
      final p = place(w, geom, estimator: estimator);
      if (lastSize != p.fontSizePt) {
        out.writeln('/$fontResource ${_num(p.fontSizePt)} Tf');
        lastSize = p.fontSizePt;
      }
      if (lastTz != p.horizScalePercent) {
        out.writeln('${_num(p.horizScalePercent)} Tz');
        lastTz = p.horizScalePercent;
      }
      final m = p.textMatrix;
      out.writeln(
          '${_num(m[0])} ${_num(m[1])} ${_num(m[2])} ${_num(m[3])} ${_num(m[4])} ${_num(m[5])} Tm');
      out.writeln('(${escapePdfString(p.text)}) Tj');
    }
    out.write('ET');
    return out.toString();
  }

  /// Formats a double as a compact, locale-independent PDF number.
  static String _num(double v) {
    if (v == 0) v = 0.0; // normalize -0
    var s = v.toStringAsFixed(3);
    if (s.contains('.')) {
      s = s.replaceAll(RegExp(r'0+$'), '');
      if (s.endsWith('.')) s = s.substring(0, s.length - 1);
    }
    return s == '-0' ? '0' : s;
  }

  /// Escapes a string for a PDF literal `( ... )`. Handles the structural
  /// characters and control codes; bytes 0x80–0xFF become 3-digit octal.
  /// Throws on code units > 0xFF (those require a Type0/CID font — the native
  /// multilingual path), instead of silently corrupting the text.
  static String escapePdfString(String text) {
    final b = StringBuffer();
    for (final cu in text.codeUnits) {
      switch (cu) {
        case 0x5C: // backslash
          b.write(r'\\');
        case 0x28: // (
          b.write(r'\(');
        case 0x29: // )
          b.write(r'\)');
        case 0x0A:
          b.write(r'\n');
        case 0x0D:
          b.write(r'\r');
        case 0x09:
          b.write(r'\t');
        case 0x08:
          b.write(r'\b');
        case 0x0C:
          b.write(r'\f');
        default:
          if (cu >= 0x20 && cu <= 0x7E) {
            b.writeCharCode(cu);
          } else if (cu <= 0xFF) {
            b.write('\\');
            b.write(cu.toRadixString(8).padLeft(3, '0'));
          } else {
            throw UnsupportedError(
                'code unit U+${cu.toRadixString(16).toUpperCase()} requires a '
                'Type0/CID font (native multilingual path), not a simple font');
          }
      }
    }
    return b.toString();
  }
}

/// One page of a searchable PDF: the visible image (referenced by the assembler)
/// plus the invisible text content stream and the geometry that produced it.
final class SearchablePage {
  final int pageIndex;
  final PageGeometry geometry;
  final String textContentStream;
  final String? imageRef;

  const SearchablePage({
    required this.pageIndex,
    required this.geometry,
    required this.textContentStream,
    this.imageRef,
  });
}

/// Serialization of searchable pages — the payload for the native PDF assembler.
abstract final class OcrLayerCodec {
  static Map<String, Object?> toJson(SearchablePage p) => {
        'page': p.pageIndex,
        'geom': {
          'iw': p.geometry.imageWidthPx,
          'ih': p.geometry.imageHeightPx,
          'pw': p.geometry.pageWidthPt,
          'ph': p.geometry.pageHeightPt,
        },
        'stream': p.textContentStream,
        if (p.imageRef != null) 'image': p.imageRef,
      };

  static SearchablePage fromJson(Map<String, Object?> j) {
    final page = j['page'];
    final g = j['geom'];
    final stream = j['stream'];
    if (page is! int) throw const FormatException('"page" must be int');
    if (g is! Map) throw const FormatException('"geom" must be a map');
    if (stream is! String) throw const FormatException('"stream" must be String');
    double d(Object? v) =>
        v is num ? v.toDouble() : throw const FormatException('geom needs numbers');
    final image = j['image'];
    return SearchablePage(
      pageIndex: page,
      geometry: PageGeometry(
        imageWidthPx: d(g['iw']),
        imageHeightPx: d(g['ih']),
        pageWidthPt: d(g['pw']),
        pageHeightPt: d(g['ph']),
      ),
      textContentStream: stream,
      imageRef: image is String ? image : null,
    );
  }

  static List<Map<String, Object?>> encodeAll(Iterable<SearchablePage> ps) =>
      ps.map(toJson).toList(growable: false);

  static List<SearchablePage> decodeAll(List<Object?> items) => items
      .map((e) => fromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);
}
