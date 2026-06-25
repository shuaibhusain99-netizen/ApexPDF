// search_test.dart — run with: dart search_test.dart
import 'viewport_core.dart';
import 'search_model.dart';

int _passed = 0, _failed = 0;
String _group = '';
void group(String n, void Function() body) {
  _group = n;
  body();
}

void test(String n, void Function() body) {
  try {
    body();
    _passed++;
  } catch (e) {
    _failed++;
    print('FAIL [$_group] $n: $e');
  }
}

void check(bool c, [String? m]) {
  if (!c) throw Exception(m ?? 'check failed');
}

void eq(Object? a, Object? b, [String? m]) {
  if (a != b) throw Exception('${m ?? 'eq'}: $a != $b');
}

void throwsErr(void Function() f, [String? m]) {
  try {
    f();
  } catch (_) {
    return;
  }
  throw Exception(m ?? 'expected throw');
}

List<Aabb?> lineBoxes(int len, {double w = 10, double y0 = 0, double y1 = 10}) =>
    <Aabb?>[for (var i = 0; i < len; i++) Aabb(i * w, y0, i * w + w, y1)];

void boxEq(Aabb a, double x0, double y0, double x1, double y1) {
  check(
      (a.minX - x0).abs() < 1e-9 &&
          (a.minY - y0).abs() < 1e-9 &&
          (a.maxX - x1).abs() < 1e-9 &&
          (a.maxY - y1).abs() < 1e-9,
      'box $a != ($x0,$y0,$x1,$y1)');
}

void main() {
  group('mergeBoxesIntoLines', () {
    test('empty -> empty', () => eq(mergeBoxesIntoLines(const []).length, 0));
    test('single -> one', () {
      final r = mergeBoxesIntoLines([Aabb(0, 0, 10, 10)]);
      eq(r.length, 1);
      boxEq(r.first, 0, 0, 10, 10);
    });
    test('same line overlap -> union', () {
      final r = mergeBoxesIntoLines([Aabb(0, 0, 10, 10), Aabb(10, 0, 25, 10)]);
      eq(r.length, 1);
      boxEq(r.first, 0, 0, 25, 10);
    });
    test('different lines -> two', () {
      final r = mergeBoxesIntoLines([Aabb(0, 0, 10, 10), Aabb(0, 20, 10, 30)]);
      eq(r.length, 2);
    });
  });

  group('findMatches', () {
    test('two single-line matches with merged rects', () {
      const s = 'the cat sat on the mat';
      final p = PageText(pageIndex: 0, text: s, charBoxes: lineBoxes(s.length));
      final m = p.findMatches('the');
      eq(m.length, 2);
      eq(m[0].start, 0);
      eq(m[0].end, 3);
      eq(m[1].start, 15);
      eq(m[1].end, 18);
      eq(m[0].rects.length, 1);
      boxEq(m[0].rects.first, 0, 0, 30, 10);
      boxEq(m[1].rects.first, 150, 0, 180, 10);
    });

    test('case-insensitive default, case-sensitive opt', () {
      final p =
          PageText(pageIndex: 1, text: 'Cat', charBoxes: lineBoxes(3));
      eq(p.findMatches('cat').length, 1);
      eq(p
          .findMatches('cat', const SearchOptions(caseSensitive: true))
          .length, 0);
    });

    test('whole-word filters substrings', () {
      const s = 'category cat';
      final p = PageText(pageIndex: 0, text: s, charBoxes: lineBoxes(s.length));
      eq(p.findMatches('cat').length, 2);
      final ww = p.findMatches('cat', const SearchOptions(wholeWord: true));
      eq(ww.length, 1);
      eq(ww.first.start, 9);
    });

    test('code-unit alignment across a surrogate pair', () {
      const s = '\u{1F600}abc'; // emoji (2 code units) + abc
      eq(s.length, 5);
      final boxes = <Aabb?>[
        Aabb(0, 0, 10, 10),
        Aabb(10, 0, 20, 10),
        Aabb(20, 0, 30, 10),
        Aabb(30, 0, 40, 10),
        Aabb(40, 0, 50, 10),
      ];
      final p = PageText(pageIndex: 2, text: s, charBoxes: boxes);
      final m = p.findMatches('abc');
      eq(m.length, 1);
      eq(m.first.start, 2);
      eq(m.first.end, 5);
      boxEq(m.first.rects.first, 20, 0, 50, 10);
    });

    test('null boxes are skipped in rects', () {
      final p = PageText(
          pageIndex: 0, text: 'ab', charBoxes: <Aabb?>[null, Aabb(10, 0, 20, 10)]);
      final m = p.findMatches('ab');
      eq(m.length, 1);
      eq(m.first.rects.length, 1);
      boxEq(m.first.rects.first, 10, 0, 20, 10);
    });

    test('match spanning two visual lines -> two rects', () {
      // a,b on line 1; c,d on line 2
      final boxes = <Aabb?>[
        Aabb(0, 0, 10, 10),
        Aabb(10, 0, 20, 10),
        Aabb(0, 20, 10, 30),
        Aabb(10, 20, 20, 30),
      ];
      final p = PageText(pageIndex: 0, text: 'abcd', charBoxes: boxes);
      final m = p.findMatches('abcd');
      eq(m.length, 1);
      eq(m.first.rects.length, 2);
    });

    test('empty query and over-long query return nothing', () {
      final p = PageText(pageIndex: 0, text: 'ab', charBoxes: lineBoxes(2));
      eq(p.findMatches('').length, 0);
      eq(p.findMatches('abc').length, 0);
    });

    test('charBoxes length must match text', () {
      throwsErr(() =>
          PageText(pageIndex: 0, text: 'abc', charBoxes: lineBoxes(2)));
    });
  });

  group('SearchResults', () {
    SearchMatch mk(int page, int start) =>
        SearchMatch(pageIndex: page, start: start, end: start + 3, rects: const []);

    test('aggregation, active default, wrap navigation', () {
      final r = SearchResults();
      r.addPage([mk(0, 0), mk(0, 10)]);
      r.addPage([mk(1, 5)]);
      eq(r.length, 3);
      eq(r.activeIndex, 0);
      eq(r.active!.pageIndex, 0);
      eq(r.next()!.start, 10);
      eq(r.next()!.pageIndex, 1);
      eq(r.next()!.start, 0); // wrapped
      eq(r.previous()!.pageIndex, 1); // wrapped back to last
    });

    test('matchesOnPage and setActive bounds', () {
      final r = SearchResults();
      r.addPage([mk(0, 0), mk(2, 4), mk(2, 40)]);
      eq(r.matchesOnPage(2).length, 2);
      r.setActive(2);
      eq(r.activeIndex, 2);
      r.setActive(99);
      eq(r.activeIndex, 2);
    });

    test('empty add is a no-op; clear resets', () {
      final r = SearchResults();
      r.addPage(const []);
      eq(r.isEmpty, true);
      eq(r.activeIndex, -1);
      r.addPage([mk(0, 0)]);
      r.clear();
      eq(r.isEmpty, true);
      eq(r.activeIndex, -1);
    });
  });

  print('---');
  print('search: $_passed passed, $_failed failed');
  if (_failed > 0) throw Exception('search tests failed');
}
