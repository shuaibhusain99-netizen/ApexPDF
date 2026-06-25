// text_test.dart — Feature 7 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/text/text_script.dart';
import 'package:ultimate_pdf/text/text_segmentation.dart';
import 'package:ultimate_pdf/text/text_shaping_plan.dart';

int _pass = 0, _fail = 0;
String _g = '';

void group(String n, void Function() b) {
  final p = _g;
  _g = n;
  b();
  _g = p;
}

void test(String n, void Function() b) {
  try {
    b();
    _pass++;
  } catch (e, st) {
    _fail++;
    print('  FAIL [$_g] $n\n    $e');
    final f = st
        .toString()
        .split('\n')
        .firstWhere((l) => l.contains('text_test.dart'), orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

void eq(Object? a, Object? b, [String l = '']) {
  if (a is List && b is List) {
    if (a.length != b.length) throw StateError('$l len ${a.length} vs ${b.length}: $a');
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) throw StateError('$l at $i: ${a[i]} vs ${b[i]}');
    }
    return;
  }
  if (a != b) throw StateError('$l expected "$b" got "$a"');
}

// Sample strings (kept as escapes to stay ASCII-safe in source).
const arabic = '\u0645\u0631\u062D\u0628\u0627'; // "مرحبا"
const hebrew = '\u05E9\u05DC\u05D5\u05DD'; // "שלום"
const han = '\u4E2D\u6587'; // "中文"

// Build a fake run with just a direction, for reordering tests.
ScriptRun run(String tag, TextDirection d) =>
    ScriptRun(text: tag, script: TextScript.latin, direction: d, start: 0, length: 1);

List<String> tags(List<ScriptRun> rs) => rs.map((r) => r.text).toList();

void main() {
  group('Script detection', () {
    test('classifies representative code points', () {
      eq(scriptOf(0x41), TextScript.latin, 'A');
      eq(scriptOf(0x20), TextScript.common, 'space');
      eq(scriptOf(0x35), TextScript.common, 'digit 5');
      eq(scriptOf(0x0627), TextScript.arabic, 'arabic alef');
      eq(scriptOf(0x05D0), TextScript.hebrew, 'hebrew alef');
      eq(scriptOf(0x4E2D), TextScript.han, 'han');
      eq(scriptOf(0x3042), TextScript.hiragana, 'hiragana');
      eq(scriptOf(0xAC00), TextScript.hangul, 'hangul');
      eq(scriptOf(0x0E01), TextScript.thai, 'thai');
      eq(scriptOf(0x0414), TextScript.cyrillic, 'cyrillic');
      check(isStrongRtlScript(TextScript.arabic), 'arabic is rtl');
      check(!isStrongRtlScript(TextScript.han), 'han is not rtl');
    });
  });

  group('Base direction', () {
    test('first strong character wins', () {
      eq(TextSegmenter.baseDirection('Hello'), TextDirection.ltr, 'latin');
      eq(TextSegmenter.baseDirection(arabic), TextDirection.rtl, 'arabic');
      eq(TextSegmenter.baseDirection('123 $arabic'), TextDirection.rtl,
          'digits are neutral, arabic is first strong');
      eq(TextSegmenter.baseDirection('   '), TextDirection.ltr, 'no strong -> ltr');
      eq(TextSegmenter.baseDirection('$hebrew abc'), TextDirection.rtl, 'hebrew');
    });
  });

  group('Segmentation', () {
    test('single-script string is one run', () {
      final r = TextSegmenter.segment('abc def');
      eq(r.length, 1, 'one run (space absorbed)');
      eq(r.first.script, TextScript.latin);
      eq(r.first.length, 7, 'covers whole string');
    });

    test('script boundary splits, neutral attaches to preceding', () {
      final r = TextSegmenter.segment('abc $arabic'); // "abc " + arabic
      eq(r.length, 2, 'two runs');
      eq(r[0].script, TextScript.latin);
      eq(r[0].text, 'abc ', 'trailing space stays with latin');
      eq(r[1].script, TextScript.arabic);
      eq(r[1].direction, TextDirection.rtl, 'arabic run is rtl');
    });

    test('trailing neutrals fold into the strong run', () {
      final r = TextSegmenter.segment('$arabic 123');
      eq(r.length, 1, 'arabic absorbs space + digits');
      eq(r.first.script, TextScript.arabic);
    });

    test('all-neutral string takes base direction', () {
      final r = TextSegmenter.segment('123');
      eq(r.length, 1);
      eq(r.first.script, TextScript.common);
      eq(r.first.direction, TextDirection.ltr, 'base ltr');
    });

    test('surrogate pairs advance correctly', () {
      // U+20000 (CJK ext B) is a surrogate pair; then ASCII 'a'.
      final s = '\u{20000}a';
      final r = TextSegmenter.segment(s);
      eq(r.length, 2, 'han then latin');
      eq(r[0].script, TextScript.han);
      eq(r[0].length, 2, 'pair counted as 2 code units');
      eq(r[1].text, 'a');
    });
  });

  group('Visual reordering (two-level)', () {
    test('LTR base: maximal RTL run sequences reverse', () {
      final logical = [
        run('L', TextDirection.ltr),
        run('R1', TextDirection.rtl),
        run('R2', TextDirection.rtl),
        run('L2', TextDirection.ltr),
      ];
      final v = TextSegmenter.reorderForDisplay(logical, TextDirection.ltr);
      eq(tags(v), ['L', 'R2', 'R1', 'L2'], 'rtl pair reversed in place');
    });

    test('LTR base: a single RTL run is unchanged in order', () {
      final logical = [
        run('L', TextDirection.ltr),
        run('R', TextDirection.rtl),
        run('L2', TextDirection.ltr),
      ];
      eq(tags(TextSegmenter.reorderForDisplay(logical, TextDirection.ltr)),
          ['L', 'R', 'L2'], 'order preserved');
    });

    test('RTL base: whole reversed, LTR runs restored', () {
      final logical = [
        run('R1', TextDirection.rtl),
        run('L1', TextDirection.ltr),
        run('R2', TextDirection.rtl),
      ];
      eq(tags(TextSegmenter.reorderForDisplay(logical, TextDirection.rtl)),
          ['R2', 'L1', 'R1'], 'reversed with L kept');
    });

    test('RTL base: consecutive LTR runs keep left-to-right order', () {
      final logical = [
        run('L1', TextDirection.ltr),
        run('L2', TextDirection.ltr),
      ];
      eq(tags(TextSegmenter.reorderForDisplay(logical, TextDirection.rtl)),
          ['L1', 'L2'], 'latin sequence stays ltr inside rtl paragraph');
    });
  });

  group('Serialization', () {
    test('shaping request round-trips', () {
      final req = ShapingRequest.build('abc $arabic 123');
      final back = ShapingCodec.requestFromJson(ShapingCodec.requestToJson(req));
      eq(back.text, req.text, 'text');
      eq(back.base, req.base, 'base dir');
      eq(back.runs.length, req.runs.length, 'run count');
      eq(back.runs.first.script, req.runs.first.script, 'first script');
      eq(back.runs.last.direction, req.runs.last.direction, 'last dir');
    });

    test('han request builds an ltr single run', () {
      final req = ShapingRequest.build(han);
      eq(req.base, TextDirection.ltr, 'cjk base ltr');
      eq(req.runs.length, 1);
      eq(req.runs.first.script, TextScript.han);
    });
  });

  print('');
  print('============= multilingual text (feature 7) summary =========');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
