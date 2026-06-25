// annotation_test.dart  — Feature 1 core tests (pure Dart, zero-dep harness).

import 'dart:typed_data';

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/annotations/annotation_model.dart';
import 'package:ultimate_pdf/annotations/annotation_store.dart';
import 'package:ultimate_pdf/annotations/annotation_commands.dart';
import 'package:ultimate_pdf/annotations/annotation_serialization.dart';

int _pass = 0, _fail = 0;
String _group = '';

void group(String name, void Function() body) {
  final p = _group;
  _group = name;
  body();
  _group = p;
}

void test(String name, void Function() body) {
  try {
    body();
    _pass++;
  } catch (e, st) {
    _fail++;
    print('  FAIL [$_group] $name\n    $e');
    final f = st.toString().split('\n').firstWhere(
        (l) => l.contains('annotation_test.dart'),
        orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

void eq(Object? a, Object? b, [String label = '']) {
  if (a is List && b is List) {
    var same = a.length == b.length;
    if (same) {
      for (var i = 0; i < a.length; i++) {
        if (a[i] != b[i]) {
          same = false;
          break;
        }
      }
    }
    if (!same) throw StateError('$label expected $b got $a');
    return;
  }
  if (a != b) throw StateError('$label expected $b got $a');
}

void throws(void Function() f, [String label = '']) {
  var t = false;
  try {
    f();
  } catch (_) {
    t = true;
  }
  if (!t) throw StateError('$label expected exception');
}

const black = 0xFF000000;

void main() {
  group('Model hit-testing', () {
    test('ink hits on the stroke, misses off it', () {
      final ink = InkAnnotation(
        id: 'i',
        pageIndex: 0,
        colorArgb: black,
        points: Float64List.fromList([0, 0, 10, 0, 10, 10]),
        strokeWidth: 2,
      );
      check(ink.hitTest(5, 0, 0.5), 'on horizontal seg');
      check(ink.hitTest(10, 5, 0.5), 'on vertical seg');
      check(!ink.hitTest(5, 5, 0.5), 'interior corner not on stroke');
      final b = ink.worldBounds;
      eq(b.minX, -1.0, 'bounds padded minX');
      eq(b.maxY, 11.0, 'bounds padded maxY');
    });

    test('highlight hits within any rect', () {
      final h = HighlightAnnotation(
        id: 'h',
        pageIndex: 0,
        colorArgb: black,
        rects: const [Aabb(0, 0, 10, 2), Aabb(0, 4, 8, 6)],
      );
      check(h.hitTest(5, 1, 0), 'first rect');
      check(h.hitTest(4, 5, 0), 'second rect');
      check(!h.hitTest(5, 3, 0), 'gap between rects');
      eq(h.worldBounds, const Aabb(0, 0, 10, 6), 'union bounds');
    });

    test('rectangle outline vs filled', () {
      final outline = ShapeAnnotation(
        id: 'r',
        pageIndex: 0,
        colorArgb: black,
        rect: const Aabb(0, 0, 10, 10),
        ellipse: false,
        filled: false,
        strokeWidth: 1,
      );
      check(outline.hitTest(0, 5, 0.2), 'on left edge');
      check(!outline.hitTest(5, 5, 0.2), 'interior misses (outline only)');

      final filled = ShapeAnnotation(
        id: 'rf',
        pageIndex: 0,
        colorArgb: black,
        rect: const Aabb(0, 0, 10, 10),
        ellipse: false,
        filled: true,
        strokeWidth: 1,
      );
      check(filled.hitTest(5, 5, 0), 'interior hits when filled');
    });

    test('line and note picking', () {
      final line = LineAnnotation(
        id: 'l',
        pageIndex: 0,
        colorArgb: black,
        x1: 0,
        y1: 0,
        x2: 10,
        y2: 10,
        strokeWidth: 2,
      );
      check(line.hitTest(5, 5, 0.5), 'on the line');
      check(!line.hitTest(5, 0, 0.5), 'off the line');

      final note = NoteAnnotation(
        id: 'n',
        pageIndex: 0,
        colorArgb: black,
        x: 50,
        y: 50,
        text: 'hi',
        iconRadius: 12,
      );
      check(note.hitTest(55, 55, 0), 'within icon radius');
      check(!note.hitTest(70, 70, 0), 'outside icon radius');
    });

    test('model validates inputs', () {
      throws(
          () => InkAnnotation(
              id: 'x',
              pageIndex: 0,
              colorArgb: black,
              points: Float64List.fromList([0, 0, 1]),
              strokeWidth: 1),
          'odd points');
      throws(
          () => NoteAnnotation(
              id: '',
              pageIndex: 0,
              colorArgb: black,
              x: 0,
              y: 0,
              text: ''),
          'empty id');
    });
  });

  group('AnnotationStore', () {
    Annotation rect(String id, Aabb r) => ShapeAnnotation(
          id: id,
          pageIndex: 0,
          colorArgb: black,
          rect: r,
          ellipse: false,
          filled: true,
          strokeWidth: 1,
        );

    test('add / update / remove and version bumps', () {
      final s = AnnotationStore();
      final v0 = s.version;
      s.add(rect('a', const Aabb(0, 0, 10, 10)));
      check(s.version > v0, 'version bumped on add');
      eq(s.length, 1);
      check(s.contains('a'), 'contains a');
      s.update(rect('a', const Aabb(100, 100, 110, 110)));
      eq(s.getById('a') is ShapeAnnotation, true);
      s.remove('a');
      eq(s.length, 0, 'removed');
      throws(() => s.update(rect('ghost', const Aabb(0, 0, 1, 1))), 'update unknown');
    });

    test('spatial query matches brute force', () {
      final s = AnnotationStore();
      final boxes = <String, Aabb>{
        'a': const Aabb(0, 0, 5, 5),
        'b': const Aabb(20, 20, 25, 25),
        'c': const Aabb(3, 3, 8, 8),
        'd': const Aabb(100, 0, 110, 5),
      };
      boxes.forEach((id, r) => s.add(rect(id, r)));

      const query = Aabb(2, 2, 9, 9); // should hit a and c
      final got = s.idsInRect(query).toSet();
      final expected = <String>{};
      boxes.forEach((id, r) {
        if (r.intersects(query)) expected.add(id);
      });
      check(got.length == expected.length && got.containsAll(expected),
          'spatial query: got $got expected $expected');
    });

    test('hitTest returns the topmost (highest z) annotation', () {
      final s = AnnotationStore();
      s.add(rect('under', const Aabb(0, 0, 10, 10)));
      s.add(rect('over', const Aabb(0, 0, 10, 10))); // same area, added later
      final hit = s.hitTest(5, 5);
      check(hit != null, 'something hit');
      eq(hit!.id, 'over', 'topmost by z-order');
    });

    test('query reflects updated geometry', () {
      final s = AnnotationStore();
      s.add(rect('m', const Aabb(0, 0, 5, 5)));
      eq(s.idsInRect(const Aabb(0, 0, 1, 1)), ['m'], 'before move');
      s.update(rect('m', const Aabb(50, 50, 55, 55)));
      eq(s.idsInRect(const Aabb(0, 0, 1, 1)).isEmpty, true, 'moved away');
      eq(s.idsInRect(const Aabb(50, 50, 51, 51)), ['m'], 'at new location');
    });

    test('tolerance lets a near-miss pick an ink stroke', () {
      final s = AnnotationStore();
      s.add(InkAnnotation(
        id: 'k',
        pageIndex: 0,
        colorArgb: black,
        points: Float64List.fromList([0, 0, 100, 0]),
        strokeWidth: 1,
      ));
      check(s.hitTest(50, 0.4, toleranceWorld: 0) != null, 'within half-stroke');
      check(s.hitTest(50, 3, toleranceWorld: 0) == null, 'too far, no tolerance');
      check(s.hitTest(50, 3, toleranceWorld: 4) != null, 'tolerance rescues pick');
    });
  });

  group('Undo / redo', () {
    Annotation note(String id) => NoteAnnotation(
        id: id, pageIndex: 0, colorArgb: black, x: 0, y: 0, text: id);

    test('execute then undo then redo', () {
      final s = AnnotationStore();
      final stack = CommandStack(s);
      stack.execute(AddAnnotationCommand(note('a')));
      eq(s.length, 1, 'added');
      check(stack.canUndo && !stack.canRedo, 'undo available');
      stack.undo();
      eq(s.length, 0, 'undone');
      check(!stack.canUndo && stack.canRedo, 'redo available');
      stack.redo();
      eq(s.length, 1, 'redone');
    });

    test('new command clears the redo branch', () {
      final s = AnnotationStore();
      final stack = CommandStack(s);
      stack.execute(AddAnnotationCommand(note('a')));
      stack.execute(AddAnnotationCommand(note('b')));
      stack.undo(); // removes b
      check(stack.canRedo, 'redo present after undo');
      stack.execute(AddAnnotationCommand(note('c')));
      check(!stack.canRedo, 'redo branch discarded');
      eq(s.length, 2, 'a and c present');
      check(s.contains('a') && s.contains('c') && !s.contains('b'), 'correct set');
    });

    test('remove and update commands reverse correctly', () {
      final s = AnnotationStore();
      s.add(note('a'));
      final stack = CommandStack(s);
      stack.execute(RemoveAnnotationCommand(s.getById('a')!));
      eq(s.length, 0, 'removed');
      stack.undo();
      eq(s.length, 1, 'remove undone');

      final prev = s.getById('a')!;
      final next = NoteAnnotation(
          id: 'a', pageIndex: 0, colorArgb: 0xFFFF0000, x: 9, y: 9, text: 'a');
      stack.execute(UpdateAnnotationCommand(previous: prev, next: next));
      eq((s.getById('a') as NoteAnnotation).x, 9.0, 'updated');
      stack.undo();
      eq((s.getById('a') as NoteAnnotation).x, 0.0, 'update reverted');
    });

    test('history is bounded by maxDepth', () {
      final s = AnnotationStore();
      final stack = CommandStack(s, maxDepth: 2);
      stack.execute(AddAnnotationCommand(note('a')));
      stack.execute(AddAnnotationCommand(note('b')));
      stack.execute(AddAnnotationCommand(note('c')));
      eq(stack.undoDepth, 2, 'depth capped');
      eq(s.length, 3, 'all applied though');
    });
  });

  group('Serialization round-trip', () {
    void roundTrip(Annotation a) {
      final json = AnnotationCodec.toJson(a);
      final back = AnnotationCodec.fromJson(json);
      eq(back.kind, a.kind, 'kind preserved');
      eq(back.id, a.id, 'id preserved');
      eq(back.pageIndex, a.pageIndex, 'page preserved');
      eq(back.colorArgb, a.colorArgb, 'color preserved');
      eq(back.worldBounds, a.worldBounds, 'bounds preserved for ${a.kind}');
    }

    test('every annotation kind survives encode/decode', () {
      roundTrip(InkAnnotation(
        id: 'i',
        pageIndex: 2,
        colorArgb: 0xFF112233,
        points: Float64List.fromList([0, 0, 5, 5, 10, 0]),
        strokeWidth: 3,
      ));
      roundTrip(HighlightAnnotation(
        id: 'h',
        pageIndex: 0,
        colorArgb: 0x80FFFF00,
        rects: const [Aabb(0, 0, 10, 2), Aabb(0, 4, 8, 6)],
      ));
      roundTrip(ShapeAnnotation(
        id: 'r',
        pageIndex: 1,
        colorArgb: 0xFF00FF00,
        rect: const Aabb(1, 2, 3, 4),
        ellipse: true,
        filled: false,
        strokeWidth: 2,
      ));
      roundTrip(LineAnnotation(
        id: 'l',
        pageIndex: 0,
        colorArgb: black,
        x1: 1,
        y1: 2,
        x2: 30,
        y2: 40,
        strokeWidth: 1.5,
      ));
      roundTrip(NoteAnnotation(
        id: 'n',
        pageIndex: 3,
        colorArgb: 0xFFFF0000,
        x: 50,
        y: 60,
        text: 'hello',
        iconRadius: 14,
      ));
    });

    test('encodeAll / decodeAll preserves a collection', () {
      final items = <Annotation>[
        NoteAnnotation(
            id: 'n1', pageIndex: 0, colorArgb: black, x: 0, y: 0, text: 'a'),
        ShapeAnnotation(
            id: 's1',
            pageIndex: 0,
            colorArgb: black,
            rect: const Aabb(0, 0, 5, 5),
            ellipse: false,
            filled: true,
            strokeWidth: 1),
      ];
      final decoded = AnnotationCodec.decodeAll(AnnotationCodec.encodeAll(items));
      eq(decoded.length, 2, 'count preserved');
      eq(decoded[0].id, 'n1');
      eq(decoded[1].id, 's1');
    });

    test('decode rejects malformed input', () {
      throws(
          () => AnnotationCodec.fromJson({'kind': 'bogus', 'id': 'x', 'page': 0, 'color': 0}),
          'unknown kind');
      throws(
          () => AnnotationCodec.fromJson({'kind': 'note', 'id': 'x'}),
          'missing fields');
    });
  });

  print('');
  print('============== annotations (feature 1) test summary =========');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
