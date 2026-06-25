// thumbnail_test.dart — run with: dart thumbnail_test.dart
import 'thumbnail_model.dart';

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

void eqList(List<Object?> a, List<Object?> b, [String? m]) {
  if (a.length != b.length) {
    throw Exception('${m ?? 'eqList'}: length ${a.length} != ${b.length}');
  }
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) {
      throw Exception('${m ?? 'eqList'}: [$i] ${a[i]} != ${b[i]}');
    }
  }
}

void approx(double a, double b, [double tol = 1e-9]) {
  if ((a - b).abs() > tol) throw Exception('approx: $a != $b');
}

void main() {
  group('fitWithin', () {
    test('landscape fits to width', () {
      final f = fitWithin(200, 100, 100, 100);
      approx(f.width, 100);
      approx(f.height, 50);
    });
    test('portrait fits to height', () {
      final f = fitWithin(100, 200, 100, 100);
      approx(f.width, 50);
      approx(f.height, 100);
    });
    test('square fills box', () {
      final f = fitWithin(50, 50, 120, 120);
      approx(f.width, 120);
      approx(f.height, 120);
    });
    test('A4 portrait into a cell', () {
      final f = fitWithin(595, 842, 150, 200);
      // limited by height: scale = 200/842
      approx(f.height, 200);
      approx(f.width, 595 * (200 / 842));
      check(f.width <= 150);
    });
    test('non-positive inputs -> zero', () {
      eq(fitWithin(0, 100, 50, 50), const ThumbFit(0, 0));
      eq(fitWithin(100, 100, 0, 50), const ThumbFit(0, 0));
    });
  });

  group('ThumbnailCache', () {
    test('keeps within cap, evicts oldest', () {
      final evicted = <int>[];
      final c = ThumbnailCache<String>(2, onEvict: (k, v) => evicted.add(k));
      c.put(0, 'a');
      c.put(1, 'b');
      eq(c.length, 2);
      eq(evicted.length, 0);
      c.put(2, 'c'); // evicts oldest (0)
      eq(c.length, 2);
      eqList(evicted, [0]);
      check(!c.contains(0));
      check(c.contains(1));
      check(c.contains(2));
    });

    test('get refreshes recency', () {
      final evicted = <int>[];
      final c = ThumbnailCache<String>(2, onEvict: (k, v) => evicted.add(k));
      c.put(0, 'a');
      c.put(1, 'b');
      c.get(0); // 0 becomes most-recent; 1 now oldest
      c.put(2, 'c'); // evicts 1, not 0
      eqList(evicted, [1]);
      check(c.contains(0));
      check(c.contains(2));
    });

    test('put existing updates value and recency', () {
      final evicted = <int>[];
      final c = ThumbnailCache<String>(2, onEvict: (k, v) => evicted.add(k));
      c.put(0, 'a');
      c.put(1, 'b');
      c.put(0, 'A'); // update 0, becomes most-recent; no eviction
      eq(c.length, 2);
      eq(evicted.length, 0);
      eq(c.get(0), 'A');
      c.put(2, 'c'); // oldest is now 1
      eqList(evicted, [1]);
    });

    test('get on missing returns null', () {
      final c = ThumbnailCache<String>(2);
      check(c.get(7) == null);
    });

    test('clear evicts everything', () {
      final evicted = <int>[];
      final c = ThumbnailCache<String>(4, onEvict: (k, v) => evicted.add(k));
      c.put(0, 'a');
      c.put(1, 'b');
      c.put(2, 'c');
      c.clear();
      eq(c.length, 0);
      eqList(evicted..sort(), [0, 1, 2]);
    });
  });

  print('---');
  print('thumbnail: $_passed passed, $_failed failed');
  if (_failed > 0) throw Exception('thumbnail tests failed');
}
