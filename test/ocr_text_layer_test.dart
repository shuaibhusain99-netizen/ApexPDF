// ocr_text_layer_test.dart — Feature 3 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/ocr/ocr_model.dart';
import 'package:ultimate_pdf/ocr/ocr_text_layer.dart';

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
    final f = st.toString().split('\n').firstWhere(
        (l) => l.contains('ocr_text_layer_test.dart'),
        orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

void eq(Object? a, Object? b, [String l = '']) {
  if (a != b) throw StateError('$l expected "$b" got "$a"');
}

void near(double a, double b, [double eps = 1e-9, String l = '']) {
  if ((a - b).abs() > eps) throw StateError('$l expected ~$b got $a');
}

void throws(void Function() f, [String l = '']) {
  var t = false;
  try {
    f();
  } catch (_) {
    t = true;
  }
  if (!t) throw StateError('$l expected exception');
}

PageGeometry geom() => PageGeometry(
    imageWidthPx: 1000, imageHeightPx: 2000, pageWidthPt: 500, pageHeightPt: 1000);

void main() {
  group('PageGeometry', () {
    test('pixel corners map into PDF space with y-flip', () {
      final g = geom(); // sx=sy=0.5
      var (x, y) = g.pdfPoint(0, 0);
      near(x, 0, 1e-9, 'tl x');
      near(y, 1000, 1e-9, 'tl y is page top');
      (x, y) = g.pdfPoint(1000, 2000);
      near(x, 500, 1e-9, 'br x');
      near(y, 0, 1e-9, 'br y is page bottom');
      (x, y) = g.pdfPoint(500, 1000);
      near(x, 250, 1e-9, 'mid x');
      near(y, 500, 1e-9, 'mid y');
    });
  });

  group('Word placement', () {
    test('font size, origin, and Tz reproduce the box width', () {
      final g = geom();
      final w = OcrWord(text: 'Test', pixelBounds: const Aabb(100, 100, 300, 140));
      final p = OcrTextLayerBuilder.place(w, g);
      near(p.fontSizePt, 20, 1e-9, 'font from box height');
      near(p.originXPt, 50, 1e-9, 'origin x');
      near(p.originYPt, 930, 1e-9, 'origin y = box bottom in PDF');
      // default estimator: 0.5em advance => natural width = 4*0.5*20 = 40 pt
      final natural = 4 * 0.5 * p.fontSizePt;
      final reproduced = natural * p.horizScalePercent / 100.0;
      final boxWidthPt = (300 - 100) * g.sx; // 100 pt
      near(reproduced, boxWidthPt, 1e-6, 'Tz reproduces scanned width');
    });

    test('text matrix carries rotation', () {
      final g = geom();
      final w = OcrWord(
          text: 'x', pixelBounds: const Aabb(0, 0, 10, 10), angleRadians: 0);
      final m = OcrTextLayerBuilder.place(w, g).textMatrix;
      eq(m.length, 6);
      near(m[0], 1, 1e-9, 'cos0');
      near(m[1], 0, 1e-9, 'sin0');
    });
  });

  group('Content stream', () {
    test('invisible stream: BT/3 Tr/ET, op suppression, blank skipped', () {
      final g = geom();
      final page = OcrPage(
        pageIndex: 0,
        imageWidthPx: 1000,
        imageHeightPx: 2000,
        words: [
          OcrWord(text: 'AB', pixelBounds: const Aabb(0, 0, 100, 40)),
          OcrWord(text: '   ', pixelBounds: const Aabb(0, 60, 100, 100)), // blank
          OcrWord(text: 'CD', pixelBounds: const Aabb(0, 100, 100, 140)),
        ],
      );
      final s = OcrTextLayerBuilder.buildContentStream(page, g);
      check(s.startsWith('BT'), 'starts with BT');
      check(s.trimRight().endsWith('ET'), 'ends with ET');
      check(s.contains('3 Tr'), 'invisible render mode');
      // Same height for both words => Tf and Tz emitted once.
      eq('/F0 20 Tf'.allMatches(s).length, 1, 'Tf emitted once');
      eq('250 Tz'.allMatches(s).length, 1, 'Tz emitted once');
      check(s.contains('1 0 0 1 0 980 Tm'), 'AB matrix');
      check(s.contains('1 0 0 1 0 930 Tm'), 'CD matrix');
      check(s.contains('(AB) Tj') && s.contains('(CD) Tj'), 'both words drawn');
      check(!s.contains('( ') && !s.contains('Tj\n( '), 'blank word skipped');
    });
  });

  group('PDF string escaping', () {
    test('structural and control characters', () {
      eq(OcrTextLayerBuilder.escapePdfString(r'(a)\b'), r'\(a\)\\b', 'parens+slash');
      eq(OcrTextLayerBuilder.escapePdfString('a\nb'), r'a\nb', 'newline');
      eq(OcrTextLayerBuilder.escapePdfString('x\ty'), r'x\ty', 'tab');
    });

    test('high Latin-1 byte becomes octal', () {
      eq(OcrTextLayerBuilder.escapePdfString('\u00e9'), r'\351', 'e-acute octal');
    });

    test('code unit > 0xFF is rejected (needs CID font)', () {
      throws(() => OcrTextLayerBuilder.escapePdfString('\u4e2d'), 'CJK rejected');
    });
  });

  group('Serialization', () {
    test('searchable page round-trips', () {
      final g = geom();
      final page = OcrPage(
        pageIndex: 2,
        imageWidthPx: 1000,
        imageHeightPx: 2000,
        words: [OcrWord(text: 'Hi', pixelBounds: const Aabb(10, 10, 60, 40))],
      );
      final sp = SearchablePage(
        pageIndex: page.pageIndex,
        geometry: g,
        textContentStream: OcrTextLayerBuilder.buildContentStream(page, g),
        imageRef: 'img2.jpg',
      );
      final back = OcrLayerCodec.fromJson(OcrLayerCodec.toJson(sp));
      eq(back.pageIndex, 2);
      near(back.geometry.pageWidthPt, 500, 1e-9, 'page width preserved');
      eq(back.imageRef, 'img2.jpg');
      eq(back.textContentStream, sp.textContentStream, 'stream preserved');
    });

    test('decode rejects malformed page', () {
      throws(
          () => OcrLayerCodec.fromJson({'page': 0, 'geom': {}}), 'missing stream');
      throws(() => OcrLayerCodec.fromJson({'page': 'x'}), 'bad page type');
    });
  });

  print('');
  print('=========== searchable-pdf/ocr (feature 3) test summary =====');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
