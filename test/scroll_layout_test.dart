// scroll_layout_test.dart — run with: dart scroll_layout_test.dart
import 'scroll_layout.dart';

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

void approx(double a, double b, [double tol = 1e-9]) {
  if ((a - b).abs() > tol) throw Exception('approx: $a != $b');
}

void main() {
  group('uniform portrait', () {
    // 3 pages 100x200, width 100 -> displayH 200 each; gap 10 -> extent 210.
    final layout = ContinuousLayout(
      pages: const [
        PageMetric(100, 200),
        PageMetric(100, 200),
        PageMetric(100, 200),
      ],
      viewportWidth: 100,
      gap: 10,
    );

    test('count + display sizes', () {
      eq(layout.count, 3);
      approx(layout.displayWidth, 100);
      approx(layout.displayHeight(0), 200);
      approx(layout.itemExtent(0), 210);
    });
    test('offsets are cumulative', () {
      approx(layout.offsetOfPage(0), 0);
      approx(layout.offsetOfPage(1), 210);
      approx(layout.offsetOfPage(2), 420);
    });
    test('total height includes trailing gap', () {
      approx(layout.totalHeight, 630); // 3 * 210
    });
    test('pageAtOffset boundaries', () {
      eq(layout.pageAtOffset(0), 0);
      eq(layout.pageAtOffset(209), 0);
      eq(layout.pageAtOffset(210), 1);
      eq(layout.pageAtOffset(415), 1);
      eq(layout.pageAtOffset(420), 2);
      eq(layout.pageAtOffset(629), 2);
    });
    test('pageAtOffset clamps out of range', () {
      eq(layout.pageAtOffset(-50), 0);
      eq(layout.pageAtOffset(99999), 2);
    });
    test('visibleRange windows', () {
      eq(layout.visibleRange(0, 300), (0, 1));
      eq(layout.visibleRange(215, 400), (1, 2));
      eq(layout.visibleRange(0, 9999), (0, 2));
    });
  });

  group('mixed sizes', () {
    // square then tall, gap 0.
    final layout = ContinuousLayout(
      pages: const [PageMetric(100, 100), PageMetric(100, 300)],
      viewportWidth: 100,
      gap: 0,
    );
    test('heights differ', () {
      approx(layout.displayHeight(0), 100);
      approx(layout.displayHeight(1), 300);
      approx(layout.totalHeight, 400);
    });
    test('offsets + pageAtOffset', () {
      approx(layout.offsetOfPage(1), 100);
      eq(layout.pageAtOffset(50), 0);
      eq(layout.pageAtOffset(100), 1);
      eq(layout.pageAtOffset(399), 1);
    });
  });

  group('landscape scales to width', () {
    // 200x100 landscape at width 100 -> displayH 50.
    final layout = ContinuousLayout(
      pages: const [PageMetric(200, 100)],
      viewportWidth: 100,
      gap: 0,
    );
    test('width-scaled height', () {
      approx(layout.displayHeight(0), 50);
      approx(layout.totalHeight, 50);
    });
  });

  group('guards', () {
    test('zero-width page does not divide by zero', () {
      final layout = ContinuousLayout(
        pages: const [PageMetric(0, 100), PageMetric(100, 200)],
        viewportWidth: 100,
        gap: 0,
      );
      approx(layout.displayHeight(0), 0);
      approx(layout.displayHeight(1), 200);
      approx(layout.totalHeight, 200);
    });
    test('empty document', () {
      final layout =
          ContinuousLayout(pages: const [], viewportWidth: 100, gap: 10);
      check(layout.isEmpty);
      eq(layout.count, 0);
      approx(layout.totalHeight, 0);
      eq(layout.pageAtOffset(123), 0);
      approx(layout.offsetOfPage(5), 0);
      eq(layout.visibleRange(0, 500), (0, 0));
    });
  });

  print('---');
  print('scroll_layout: $_passed passed, $_failed failed');
  if (_failed > 0) throw Exception('scroll_layout tests failed');
}
