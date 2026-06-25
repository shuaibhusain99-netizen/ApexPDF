// outline_test.dart — run with: dart outline_test.dart
import 'outline_model.dart';

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

void eq(Object? a, Object? b, [String? m]) {
  if (a != b) throw Exception('${m ?? 'eq'}: $a != $b');
}

void check(bool c, [String? m]) {
  if (!c) throw Exception(m ?? 'check failed');
}

DocumentOutline sample() {
  final a1 = OutlineEntry(title: 'A.1', pageIndex: 1);
  final a2 = OutlineEntry(title: 'A.2', pageIndex: 3);
  final a = OutlineEntry(title: 'A', pageIndex: 0, children: [a1, a2]);
  final b1 = OutlineEntry(title: 'B.1', pageIndex: 6);
  final b = OutlineEntry(title: 'B', pageIndex: 5, children: [b1]);
  final c = OutlineEntry(title: 'C', pageIndex: 10);
  return DocumentOutline([a, b, c]);
}

void main() {
  group('visibleItems / depth', () {
    test('all expanded by default', () {
      final o = sample();
      final v = o.visibleItems();
      eq(v.length, 6);
      eq(v[0].title, 'A');
      eq(v[0].depth, 0);
      eq(v[1].title, 'A.1');
      eq(v[1].depth, 1);
      eq(v[3].title, 'B');
      eq(v[5].title, 'C');
    });

    test('toggle collapses a subtree', () {
      final o = sample();
      final a = o.roots.first;
      o.toggle(a);
      check(!o.isExpanded(a));
      final v = o.visibleItems();
      eq(v.length, 4); // A, B, B.1, C
      eq(v[0].title, 'A');
      eq(v[1].title, 'B');
    });

    test('collapseAll then expandAll', () {
      final o = sample();
      o.collapseAll();
      eq(o.visibleItems().length, 3); // A, B, C (children hidden)
      o.expandAll();
      eq(o.visibleItems().length, 6);
    });

    test('toggle is a no-op on leaves', () {
      final o = sample();
      final c = o.roots.last; // no children
      o.toggle(c);
      eq(o.visibleItems().length, 6);
    });
  });

  group('activeEntryForPage', () {
    test('selects the section containing the page', () {
      final o = sample();
      eq(o.activeEntryForPage(0)!.title, 'A');
      eq(o.activeEntryForPage(2)!.title, 'A.1');
      eq(o.activeEntryForPage(4)!.title, 'A.2');
      eq(o.activeEntryForPage(5)!.title, 'B');
      eq(o.activeEntryForPage(7)!.title, 'B.1');
      eq(o.activeEntryForPage(10)!.title, 'C');
      eq(o.activeEntryForPage(100)!.title, 'C');
    });

    test('null before the first destination', () {
      final o = DocumentOutline([
        OutlineEntry(title: 'Intro', pageIndex: 3),
      ]);
      check(o.activeEntryForPage(0) == null);
      eq(o.activeEntryForPage(3)!.title, 'Intro');
    });

    test('ties resolve to the later entry in reading order', () {
      final o = DocumentOutline([
        OutlineEntry(title: 'First', pageIndex: 2),
        OutlineEntry(title: 'Second', pageIndex: 2),
      ]);
      eq(o.activeEntryForPage(2)!.title, 'Second');
    });

    test('non-navigable headings (null page) are skipped', () {
      final o = DocumentOutline([
        OutlineEntry(title: 'Part One', children: [
          OutlineEntry(title: 'Chapter', pageIndex: 4),
        ]),
      ]);
      eq(o.activeEntryForPage(5)!.title, 'Chapter');
      // the null-page heading is still visible as a row
      eq(o.visibleItems().first.title, 'Part One');
      check(o.visibleItems().first.pageIndex == null);
    });
  });

  group('misc', () {
    test('empty outline', () {
      final o = DocumentOutline(const []);
      check(o.isEmpty);
      eq(o.visibleItems().length, 0);
      check(o.activeEntryForPage(0) == null);
    });

    test('totalCount counts all nodes', () {
      eq(sample().totalCount, 6);
    });
  });

  print('---');
  print('outline: $_passed passed, $_failed failed');
  if (_failed > 0) throw Exception('outline tests failed');
}
