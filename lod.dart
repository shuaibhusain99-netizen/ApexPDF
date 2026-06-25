// text_shaping_plan.dart
//
// Feature 7 — Multilingual text (shaping interchange).
//
// Bundles a string's base direction and script runs for the native shaper. Each
// run crosses the platform channel and is shaped by HarfBuzz with the font that
// PDFium fallback selects for that script; glyphs come back positioned. This
// file only carries the (tested) segmentation result across the boundary.

import 'text_script.dart';
import 'text_segmentation.dart';

/// A request to shape one logical string.
final class ShapingRequest {
  final String text;
  final TextDirection base;
  final List<ScriptRun> runs;

  const ShapingRequest({
    required this.text,
    required this.base,
    required this.runs,
  });

  /// Builds a request by segmenting [text].
  factory ShapingRequest.build(String text) => ShapingRequest(
        text: text,
        base: TextSegmenter.baseDirection(text),
        runs: TextSegmenter.segment(text),
      );
}

abstract final class ShapingCodec {
  static String _dir(TextDirection d) => d == TextDirection.rtl ? 'rtl' : 'ltr';

  static TextDirection _parseDir(Object? v) =>
      v == 'rtl' ? TextDirection.rtl : TextDirection.ltr;

  static Map<String, Object?> runToJson(ScriptRun r) => {
        'text': r.text,
        'script': r.script.name,
        'dir': _dir(r.direction),
        'start': r.start,
        'len': r.length,
      };

  static ScriptRun runFromJson(Map<String, Object?> j) {
    final text = j['text'];
    final start = j['start'];
    final len = j['len'];
    if (text is! String) throw const FormatException('"text" must be String');
    if (start is! int || len is! int) {
      throw const FormatException('"start"/"len" must be ints');
    }
    final script = TextScript.values.firstWhere(
      (s) => s.name == j['script'],
      orElse: () => TextScript.unknown,
    );
    return ScriptRun(
      text: text,
      script: script,
      direction: _parseDir(j['dir']),
      start: start,
      length: len,
    );
  }

  static Map<String, Object?> requestToJson(ShapingRequest r) => {
        'text': r.text,
        'base': _dir(r.base),
        'runs': r.runs.map(runToJson).toList(growable: false),
      };

  static ShapingRequest requestFromJson(Map<String, Object?> j) {
    final text = j['text'];
    if (text is! String) throw const FormatException('"text" must be String');
    final runs = j['runs'];
    if (runs is! List) throw const FormatException('"runs" must be a List');
    return ShapingRequest(
      text: text,
      base: _parseDir(j['base']),
      runs: runs
          .map((e) => runFromJson((e as Map).cast<String, Object?>()))
          .toList(growable: false),
    );
  }
}
