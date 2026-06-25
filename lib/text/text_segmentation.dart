// text_segmentation.dart
//
// Feature 7 — Multilingual text (segmentation + reordering).
//
// Splits a string into maximal same-script runs (the unit a shaper consumes),
// resolves the base paragraph direction by the first strong character (UAX #9
// P2/P3), and reorders runs for visual display under a TWO-LEVEL model (base
// direction + opposite-direction runs). Full nested bidi reordering and intra-run
// glyph shaping are native (ICU/HarfBuzz); this is the part that decides run
// boundaries, direction, and gross run order — which is what most text gets
// wrong before it ever reaches the shaper.

import 'text_script.dart';

enum TextDirection { ltr, rtl }

/// A maximal run of one script, with its direction and UTF-16 span.
final class ScriptRun {
  final String text;
  final TextScript script;
  final TextDirection direction;
  final int start; // UTF-16 code-unit offset into the source
  final int length; // UTF-16 code units

  const ScriptRun({
    required this.text,
    required this.script,
    required this.direction,
    required this.start,
    required this.length,
  });

  @override
  String toString() =>
      '${script.name}/${direction == TextDirection.rtl ? 'rtl' : 'ltr'}'
      '[$start,${start + length})="$text"';
}

abstract final class TextSegmenter {
  /// Base paragraph direction: the direction of the first strong character, or
  /// LTR when there is none (UAX #9 rule P2/P3).
  static TextDirection baseDirection(String s) {
    var i = 0;
    while (i < s.length) {
      final (cp, adv) = _decodeAt(s, i);
      switch (bidiClassOf(cp)) {
        case BidiClass.ltr:
          return TextDirection.ltr;
        case BidiClass.rtl:
          return TextDirection.rtl;
        case BidiClass.neutral:
          break;
      }
      i += adv;
    }
    return TextDirection.ltr;
  }

  /// Segments [s] into script runs. Script-neutral characters (spaces,
  /// punctuation, digits) are absorbed into the preceding run, or into the
  /// following run when they lead the string. A run containing only neutrals
  /// (e.g. an all-digit string) takes the base direction.
  static List<ScriptRun> segment(String s) {
    if (s.isEmpty) return const <ScriptRun>[];
    final base = baseDirection(s);
    final runs = <ScriptRun>[];

    var runStart = 0;
    TextScript? runScript; // strong script of the current run (null until set)
    var i = 0;

    void emit(int endExclusive) {
      final script = runScript ?? TextScript.common;
      final dir = script == TextScript.common
          ? base
          : (isStrongRtlScript(script) ? TextDirection.rtl : TextDirection.ltr);
      runs.add(ScriptRun(
        text: s.substring(runStart, endExclusive),
        script: script,
        direction: dir,
        start: runStart,
        length: endExclusive - runStart,
      ));
    }

    while (i < s.length) {
      final (cp, adv) = _decodeAt(s, i);
      final sc = scriptOf(cp);
      final neutral = sc == TextScript.common || sc == TextScript.unknown;

      if (!neutral) {
        if (runScript == null) {
          runScript = sc; // leading neutrals (if any) join this run
        } else if (sc != runScript) {
          emit(i); // close previous run at the boundary
          runStart = i;
          runScript = sc;
        }
      }
      i += adv;
    }
    emit(s.length);
    return runs;
  }

  /// Reorders logical runs into visual order under a two-level model: with an
  /// LTR base, maximal sequences of RTL runs are reversed; with an RTL base, the
  /// whole sequence is reversed and maximal sequences of LTR runs are reversed
  /// back. (Nested embeddings are an ICU/native concern.)
  static List<ScriptRun> reorderForDisplay(
    List<ScriptRun> runs,
    TextDirection base,
  ) {
    final out = List<ScriptRun>.of(runs);
    if (base == TextDirection.rtl) {
      _reverseRange(out, 0, out.length);
      _reverseRuns(out, (r) => r.direction == TextDirection.ltr);
    } else {
      _reverseRuns(out, (r) => r.direction == TextDirection.rtl);
    }
    return out;
  }

  // Reverses each maximal contiguous span where [match] is true.
  static void _reverseRuns(List<ScriptRun> list, bool Function(ScriptRun) match) {
    var i = 0;
    while (i < list.length) {
      if (!match(list[i])) {
        i++;
        continue;
      }
      var j = i;
      while (j < list.length && match(list[j])) {
        j++;
      }
      _reverseRange(list, i, j);
      i = j;
    }
  }

  static void _reverseRange(List<ScriptRun> list, int start, int endExclusive) {
    var a = start, b = endExclusive - 1;
    while (a < b) {
      final t = list[a];
      list[a] = list[b];
      list[b] = t;
      a++;
      b--;
    }
  }

  /// Decodes the code point at UTF-16 index [i], returning (codePoint, advance).
  static (int, int) _decodeAt(String s, int i) {
    final cu = s.codeUnitAt(i);
    if (cu >= 0xD800 && cu <= 0xDBFF && i + 1 < s.length) {
      final lo = s.codeUnitAt(i + 1);
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        return (0x10000 + ((cu - 0xD800) << 10) + (lo - 0xDC00), 2);
      }
    }
    return (cu, 1);
  }
}
