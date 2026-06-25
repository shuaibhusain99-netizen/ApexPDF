// redaction_test.dart — Feature 2 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/redaction/redaction_model.dart';

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
        .firstWhere((l) => l.contains('redaction_test.dart'), orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

void eq(Object? a, Object? b, [String l = '']) {
  if (a is List && b is List) {
    var s = a.length == b.length;
    if (s) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) {
          s = false;
          break;
        }
      }
    }
    if (!s) throw StateError('$l expected $b got $a');
    return;
  }
  if (a != b) throw StateError('$l expected $b got $a');
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

RedactionRegion reg(String id, int page, Aabb r) =>
    RedactionRegion(id: id, pageIndex: page, rect: r);

void main() {
  group('Planning', () {
    test('regionsForPage groups by page', () {
      final p = RedactionPlan()
        ..add(reg('a', 0, const Aabb(0, 0, 10, 10)))
        ..add(reg('b', 1, const Aabb(0, 0, 10, 10)))
        ..add(reg('c', 0, const Aabb(20, 20, 30, 30)));
      eq(p.regionsForPage(0).length, 2, 'page 0 has two');
      eq(p.regionsForPage(1).length, 1, 'page 1 has one');
      eq(p.regionsForPage(2).length, 0, 'page 2 empty');
    });

    test('runsToRedact selects exactly the runs under a box', () {
      final p = RedactionPlan()..add(reg('r', 0, const Aabb(10, 10, 50, 20)));
      final runs = const [
        TextRun('SECRET', Aabb(12, 11, 40, 19)), // inside
        TextRun('public', Aabb(12, 30, 40, 38)), // below box
        TextRun('faraway', Aabb(55, 10, 60, 20)), // right of box
      ];
      final hit = p.runsToRedact(0, runs).map((r) => r.text).toList();
      eq(hit, ['SECRET'], 'only the covered run');
    });

    test('redactedStrings collects distinct trimmed text', () {
      final p = RedactionPlan()
        ..add(reg('r1', 0, const Aabb(0, 0, 100, 10)))
        ..add(reg('r2', 1, const Aabb(0, 0, 100, 10)));
      final byPage = {
        0: const [TextRun('  SECRET ', Aabb(1, 1, 50, 9))],
        1: const [TextRun('SECRET', Aabb(1, 1, 50, 9))],
      };
      final s = p.redactedStrings(byPage);
      eq(s.length, 1, 'deduped + trimmed');
      check(s.contains('SECRET'), 'has SECRET');
    });

    test('no regions on a page redacts nothing', () {
      final p = RedactionPlan()..add(reg('r', 5, const Aabb(0, 0, 10, 10)));
      eq(p.runsToRedact(0, const [TextRun('x', Aabb(0, 0, 5, 5))]).length, 0);
    });
  });

  group('Verification', () {
    final plan = RedactionPlan()..add(reg('r', 0, const Aabb(10, 10, 50, 20)));

    test('passes when covered text is gone', () {
      final post = {
        0: const [TextRun('public', Aabb(12, 30, 40, 38))], // SECRET removed
      };
      final res = plan.verify(post);
      check(res.ok, 'should pass: ${res.violations}');
    });

    test('fails geometrically when text remains under a box', () {
      final post = {
        0: const [TextRun('SECRET', Aabb(12, 11, 40, 19))], // still there
      };
      final res = plan.verify(post);
      check(!res.ok, 'should fail');
      check(res.violations.first.contains('still under region'), 'reason');
    });

    test('fails textually when a redacted string survives elsewhere', () {
      final post = {
        0: const [TextRun('clean', Aabb(0, 100, 10, 110))],
        1: const [TextRun('SECRET leaked here', Aabb(0, 0, 80, 8))], // page 1
      };
      final res = plan.verify(post, mustNotSurvive: {'SECRET'});
      check(!res.ok, 'should fail on residue');
      check(res.violations.any((v) => v.contains('still present')), 'reason');
    });

    test('passes textual check when string absent', () {
      final post = {
        0: const [TextRun('nothing sensitive', Aabb(0, 100, 50, 110))],
      };
      final res = plan.verify(post, mustNotSurvive: {'SECRET'});
      check(res.ok, 'should pass: ${res.violations}');
    });
  });

  group('Serialization', () {
    test('region round-trips through JSON', () {
      final r = RedactionRegion(
        id: 'z',
        pageIndex: 3,
        rect: const Aabb(1, 2, 30, 40),
        fillArgb: 0xFF101010,
      );
      final back = RedactionCodec.fromJson(RedactionCodec.toJson(r));
      eq(back.id, 'z');
      eq(back.pageIndex, 3);
      eq(back.fillArgb, 0xFF101010);
      eq(back.rect, const Aabb(1, 2, 30, 40), 'rect preserved');
    });

    test('encodeAll/decodeAll preserves a set', () {
      final rs = [
        reg('a', 0, const Aabb(0, 0, 5, 5)),
        reg('b', 2, const Aabb(9, 9, 20, 20)),
      ];
      final back = RedactionCodec.decodeAll(RedactionCodec.encodeAll(rs));
      eq(back.length, 2);
      eq(back[1].pageIndex, 2);
    });

    test('decode rejects malformed region', () {
      throws(() => RedactionCodec.fromJson({'id': 'x', 'page': 0, 'rect': [1, 2, 3]}),
          'bad rect length');
      throws(() => RedactionCodec.fromJson({'id': 5, 'page': 0, 'rect': [1, 2, 3, 4]}),
          'bad id type');
    });
  });

  print('');
  print('=============== redaction (feature 2) test summary ==========');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
