// ocr_model.dart
//
// Feature 3 — Searchable PDF / OCR (recognized-text data model).
//
// These types mirror what a native OCR engine (ML Kit Text Recognition v2 or
// Tesseract) emits for a page: words with pixel-space bounding boxes and a
// confidence. Recognition itself is native/on-device and cannot run in this
// sandbox; THIS model + the text-layer builder that consumes it are pure Dart
// and unit-tested. Image space convention: origin top-left, x right, y DOWN.

import '../engine/viewport_core.dart' show Aabb;

/// A single recognized word and where it sits on the page image (pixels).
final class OcrWord {
  final String text;
  final Aabb pixelBounds; // image pixels, y-down
  final double confidence; // 0..1
  final double angleRadians; // baseline rotation; 0 for axis-aligned

  OcrWord({
    required this.text,
    required this.pixelBounds,
    this.confidence = 1.0,
    this.angleRadians = 0.0,
  }) {
    if (!(confidence >= 0 && confidence <= 1)) {
      throw ArgumentError.value(confidence, 'confidence', 'must be 0..1');
    }
    if (!angleRadians.isFinite) {
      throw ArgumentError.value(angleRadians, 'angleRadians', 'must be finite');
    }
    if (!(pixelBounds.area >= 0)) {
      throw ArgumentError('pixelBounds must be valid');
    }
  }

  bool get isBlank => text.trim().isEmpty;
  double get pixelWidth => pixelBounds.width;
  double get pixelHeight => pixelBounds.height;
}

/// A line groups words sharing a baseline (used for nicer selection order).
final class OcrLine {
  final List<OcrWord> words;
  OcrLine(this.words) {
    if (words.isEmpty) throw ArgumentError('line needs >= 1 word');
  }

  Aabb get pixelBounds {
    var b = words.first.pixelBounds;
    for (var i = 1; i < words.length; i++) {
      b = b.union(words[i].pixelBounds);
    }
    return b;
  }

  String get text => words.map((w) => w.text).join(' ');
}

/// All recognized content for one page, plus the source image dimensions.
final class OcrPage {
  final int pageIndex;
  final double imageWidthPx;
  final double imageHeightPx;
  final List<OcrWord> words;

  OcrPage({
    required this.pageIndex,
    required this.imageWidthPx,
    required this.imageHeightPx,
    required this.words,
  }) {
    if (pageIndex < 0) throw ArgumentError('pageIndex must be >= 0');
    if (!(imageWidthPx > 0) || !(imageHeightPx > 0)) {
      throw ArgumentError('image dimensions must be positive');
    }
  }

  /// Words with non-empty text (blank OCR fragments are dropped).
  Iterable<OcrWord> get textWords => words.where((w) => !w.isBlank);
}
