// page_ops_test.dart — Feature 5 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/pages/page_model.dart';
import 'package:ultimate_pdf/pages/page_commands.dart';
import 'package:ultimate_pdf/pages/scan_assembly.dart';
import 'package:ultimate_pdf/pages/page_serialization.dart';

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
        .firstWhere((l) => l.contains('page_ops_test.dart'), orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

bool _deepEq(Object? a, Object? b) {
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_deepEq(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

void eq(Object? a, Object? b, [String l = '']) {
  if (!_deepEq(a, b)) throw StateError('$l expected $b got $a');
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

PageListDocument doc4() => PageListDocument.fromSource('d', 4);

void main() {
  group('Reversible operations', () {
    test('move forward then revert', () {
      final d = doc4();
      final c = MovePageCommand(0, 2);
      c.apply(d);
      eq(d.signature(), ['d#1@0', 'd#2@0', 'd#0@0', 'd#3@0'], 'after move 0->2');
      c.revert(d);
      eq(d.signature(), ['d#0@0', 'd#1@0', 'd#2@0', 'd#3@0'], 'restored');
    });

    test('move backward then revert', () {
      final d = doc4();
      final c = MovePageCommand(3, 1);
      c.apply(d);
      eq(d.signature(), ['d#0@0', 'd#3@0', 'd#1@0', 'd#2@0'], 'after move 3->1');
      c.revert(d);
      eq(d.signature(), ['d#0@0', 'd#1@0', 'd#2@0', 'd#3@0'], 'restored');
    });

    test('rotate normalizes and reverts', () {
      final d = doc4();
      RotatePageCommand(1, 5).apply(d); // 5 quarters == 1
      eq(d.entryAt(1).rotationQuarter, 1, 'normalized to 90');
      RotatePageCommand(1, 5).revert(d);
      eq(d.entryAt(1).rotationQuarter, 0, 'back to 0');
    });

    test('delete and insert reverse', () {
      final d = doc4();
      final del = DeletePageCommand(2);
      del.apply(d);
      eq(d.pageCount, 3, 'deleted');
      del.revert(d);
      eq(d.signature(), ['d#0@0', 'd#1@0', 'd#2@0', 'd#3@0'], 'restored');

      final ins = InsertPageCommand(1, PageEntry(const PageRef('x', 0)));
      ins.apply(d);
      eq(d.signature()[1], 'x#0@0', 'inserted at 1');
      ins.revert(d);
      eq(d.pageCount, 4, 'insert reverted');
    });

    test('duplicate places a copy after and reverts', () {
      final d = doc4();
      DuplicatePageCommand(0).apply(d);
      eq(d.signature(), ['d#0@0', 'd#0@0', 'd#1@0', 'd#2@0', 'd#3@0'], 'dup');
      DuplicatePageCommand(0).revert(d);
      eq(d.pageCount, 4, 'reverted');
    });

    test('append (merge) and revert', () {
      final d = doc4();
      final extra = [
        PageEntry(const PageRef('m', 0)),
        PageEntry(const PageRef('m', 1)),
      ];
      final c = AppendPagesCommand(extra);
      c.apply(d);
      eq(d.pageCount, 6, 'appended');
      eq(d.signature().last, 'm#1@0', 'last is merged page');
      c.revert(d);
      eq(d.pageCount, 4, 'merge reverted');
    });
  });

  group('Undo/redo stack', () {
    test('sequence undo/redo and redo-branch clear', () {
      final d = doc4();
      final s = PageCommandStack(d);
      s.execute(MovePageCommand(0, 3));
      s.execute(RotatePageCommand(0, 1));
      final afterBoth = d.signature();
      s.undo();
      s.undo();
      eq(d.signature(), ['d#0@0', 'd#1@0', 'd#2@0', 'd#3@0'], 'fully undone');
      s.redo();
      s.redo();
      eq(d.signature(), afterBoth, 'fully redone');
      // new command after undo clears redo
      s.undo();
      s.execute(DeletePageCommand(0));
      check(!s.canRedo, 'redo branch cleared');
    });
  });

  group('Split / extract', () {
    test('splitRangesEvery chunks indices', () {
      final d = PageListDocument.fromSource('d', 5);
      eq(d.splitRangesEvery(2), [
        [0, 1],
        [2, 3],
        [4],
      ], 'chunked');
    });

    test('extractPages builds a sub-document', () {
      final d = PageListDocument.fromSource('d', 5);
      final sub = d.extractPages([0, 2, 4]);
      eq(sub.signature(), ['d#0@0', 'd#2@0', 'd#4@0'], 'extracted');
    });
  });

  group('Scan assembly', () {
    test('page size derives from pixels and dpi', () {
      final p = ScanPage(imageRef: 'p1', widthPx: 850, heightPx: 1100, dpi: 100);
      final (w, h) = p.pageSizePt();
      near(w, 612, 1e-9, 'US Letter width');
      near(h, 792, 1e-9, 'US Letter height');
    });

    test('assembles images into a document and plan', () {
      final pages = [
        ScanPage(imageRef: 'a', widthPx: 850, heightPx: 1100, dpi: 100),
        ScanPage(imageRef: 'b', widthPx: 850, heightPx: 1100, dpi: 100, rotation: 1),
      ];
      final d = ScanAssembler.toDocument(pages);
      eq(d.signature(), ['a#0@0', 'b#0@90'], 'doc from scans');
      final plan = ScanAssembler.toPlan(pages);
      eq(plan.length, 2);
      near(plan[0]['pw'] as double, 612, 1e-9, 'plan page width');
      eq(plan[1]['rot'], 1, 'rotation carried');
    });
  });

  group('Serialization', () {
    test('document round-trips with rotation', () {
      final d = doc4();
      RotatePageCommand(1, 1).apply(d);
      MovePageCommand(0, 2).apply(d);
      final back = PageOpsCodec.docFromJson(PageOpsCodec.docToJson(d));
      eq(back.signature(), d.signature(), 'plan preserved');
    });

    test('scan page round-trips', () {
      final p = ScanPage(
          imageRef: 'img', widthPx: 1000, heightPx: 1500, dpi: 150, rotation: 2);
      final back = PageOpsCodec.scanPageFromJson(PageOpsCodec.scanPageToJson(p));
      eq(back.imageRef, 'img');
      near(back.widthPx, 1000, 1e-9);
      eq(back.rotationQuarter, 2);
    });

    test('decode rejects malformed input', () {
      throws(() => PageOpsCodec.docFromJson({'pages': 'nope'}), 'bad pages');
      throws(() => PageOpsCodec.docFromJson({
            'pages': [
              {'sp': 0}
            ]
          }), 'missing src');
      throws(() => PageOpsCodec.scanPageFromJson({'image': 'x'}), 'missing dims');
    });
  });

  print('');
  print('============ page ops + scan (feature 5) test summary =======');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
