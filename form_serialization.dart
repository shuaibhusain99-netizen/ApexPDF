// annotation_overlay.dart
//
// Feature 1 — Annotations (Flutter overlay + interaction).
//
// Draws annotations on top of the engine's tile painter using the SAME camera
// transform, so they track the document under pan/zoom/rotate. The pure-Dart
// model/store/commands/serialization are fully unit-tested; THIS file is the
// Flutter-facing layer and is validated by `flutter analyze`/on-device, not by
// the in-container Dart tests.
//
// Wiring: place AnnotationOverlayPainter in a CustomPaint above the viewport's
// CustomPaint, and wrap the viewport in an AnnotationGestureLayer that converts
// pointer positions to world space via the live Camera. When the active tool is
// AnnotationTool.none, let the viewport's own scale gestures pan/zoom; when a
// drawing tool is active, the gesture layer captures strokes instead.

import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../engine/viewport_core.dart';
import 'annotation_model.dart';
import 'annotation_store.dart';
import 'annotation_commands.dart';

enum AnnotationTool { none, ink, highlight, rectangle, ellipse, line, note, erase }

/// Owns annotation editing state for one page and drives undo/redo.
class AnnotationController extends ChangeNotifier {
  final AnnotationStore store;
  late final CommandStack _commands = CommandStack(store);
  final AnnotationIdGenerator _ids = AnnotationIdGenerator();
  final int pageIndex;

  AnnotationTool _tool = AnnotationTool.none;
  int _colorArgb = 0xFF2962FF;
  double _strokeWidth = 3.0;

  /// In-progress geometry in WORLD coordinates (null when not drawing).
  final List<Offset> _draftWorld = <Offset>[];
  Offset? _draftStart;

  /// Bumped on every visible change so the painter can decide to repaint.
  int revision = 0;

  AnnotationController({required this.store, required this.pageIndex});

  AnnotationTool get tool => _tool;
  set tool(AnnotationTool t) {
    if (t == _tool) return;
    _tool = t;
    _cancelDraft();
    _bump();
  }

  int get colorArgb => _colorArgb;
  set colorArgb(int c) {
    _colorArgb = c;
    _bump();
  }

  double get strokeWidth => _strokeWidth;
  set strokeWidth(double w) {
    _strokeWidth = w;
    _bump();
  }

  bool get canUndo => _commands.canUndo;
  bool get canRedo => _commands.canRedo;
  List<Offset> get draftWorld => List.unmodifiable(_draftWorld);
  Offset? get draftStart => _draftStart;

  bool get isDrawingTool =>
      _tool != AnnotationTool.none && _tool != AnnotationTool.erase;

  void undo() {
    _commands.undo();
    _bump();
  }

  void redo() {
    _commands.redo();
    _bump();
  }

  // --- gesture entry points (world coordinates) -----------------------------

  void pointerDown(Offset world) {
    switch (_tool) {
      case AnnotationTool.ink:
        _draftWorld
          ..clear()
          ..add(world);
      case AnnotationTool.highlight:
      case AnnotationTool.rectangle:
      case AnnotationTool.ellipse:
      case AnnotationTool.line:
        _draftStart = world;
        _draftWorld
          ..clear()
          ..add(world)
          ..add(world);
      case AnnotationTool.note:
        _commitNote(world);
      case AnnotationTool.erase:
        _eraseAt(world);
      case AnnotationTool.none:
        return;
    }
    _bump();
  }

  void pointerMove(Offset world) {
    if (_tool == AnnotationTool.ink) {
      _draftWorld.add(world);
      _bump();
    } else if (_draftStart != null) {
      if (_draftWorld.length >= 2) {
        _draftWorld[1] = world;
      }
      _bump();
    }
  }

  void pointerUp() {
    switch (_tool) {
      case AnnotationTool.ink:
        _commitInk();
      case AnnotationTool.highlight:
        _commitHighlight();
      case AnnotationTool.rectangle:
      case AnnotationTool.ellipse:
        _commitShape(ellipse: _tool == AnnotationTool.ellipse);
      case AnnotationTool.line:
        _commitLine();
      case AnnotationTool.note:
      case AnnotationTool.erase:
      case AnnotationTool.none:
        break;
    }
    _cancelDraft();
    _bump();
  }

  // --- commit helpers -------------------------------------------------------

  void _commitInk() {
    if (_draftWorld.length < 2) return;
    final pts = Float64List(_draftWorld.length * 2);
    for (var i = 0; i < _draftWorld.length; i++) {
      pts[i * 2] = _draftWorld[i].dx;
      pts[i * 2 + 1] = _draftWorld[i].dy;
    }
    _commands.execute(AddAnnotationCommand(InkAnnotation(
      id: _ids.next(),
      pageIndex: pageIndex,
      colorArgb: _colorArgb,
      points: pts,
      strokeWidth: _strokeWidth,
    )));
  }

  Aabb? _draftRect() {
    final s = _draftStart;
    if (s == null || _draftWorld.length < 2) return null;
    final e = _draftWorld[1];
    return Aabb.fromPoints(s.dx, s.dy, e.dx, e.dy);
  }

  void _commitHighlight() {
    final r = _draftRect();
    if (r == null || r.area <= 0) return;
    _commands.execute(AddAnnotationCommand(HighlightAnnotation(
      id: _ids.next(),
      pageIndex: pageIndex,
      colorArgb: (_colorArgb & 0x00FFFFFF) | 0x66000000, // force translucency
      rects: [r],
    )));
  }

  void _commitShape({required bool ellipse}) {
    final r = _draftRect();
    if (r == null || r.area <= 0) return;
    _commands.execute(AddAnnotationCommand(ShapeAnnotation(
      id: _ids.next(),
      pageIndex: pageIndex,
      colorArgb: _colorArgb,
      rect: r,
      ellipse: ellipse,
      filled: false,
      strokeWidth: _strokeWidth,
    )));
  }

  void _commitLine() {
    final s = _draftStart;
    if (s == null || _draftWorld.length < 2) return;
    final e = _draftWorld[1];
    if ((e - s).distance < 1e-6) return;
    _commands.execute(AddAnnotationCommand(LineAnnotation(
      id: _ids.next(),
      pageIndex: pageIndex,
      colorArgb: _colorArgb,
      x1: s.dx,
      y1: s.dy,
      x2: e.dx,
      y2: e.dy,
      strokeWidth: _strokeWidth,
    )));
  }

  void _commitNote(Offset world) {
    _commands.execute(AddAnnotationCommand(NoteAnnotation(
      id: _ids.next(),
      pageIndex: pageIndex,
      colorArgb: _colorArgb,
      x: world.dx,
      y: world.dy,
      text: '',
    )));
  }

  void _eraseAt(Offset world) {
    final hit = store.hitTest(world.dx, world.dy, toleranceWorld: _strokeWidth);
    if (hit != null) {
      _commands.execute(RemoveAnnotationCommand(hit));
    }
  }

  void _cancelDraft() {
    _draftStart = null;
    _draftWorld.clear();
  }

  void _bump() {
    revision++;
    notifyListeners();
  }
}

/// Paints committed annotations (for the active page, within view) plus the
/// in-progress draft, using the camera transform.
class AnnotationOverlayPainter extends CustomPainter {
  final Camera camera;
  final AnnotationController controller;

  AnnotationOverlayPainter({required this.camera, required this.controller})
      : super(repaint: controller);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.clipRect(Offset.zero & size);

    final viewWorld = camera.visibleWorldBounds(bufferPx: 64);
    final visible = controller.store
        .annotationsInRect(viewWorld)
        .where((a) => a.pageIndex == controller.pageIndex);

    // Geometry in world space via the camera transform (handles rotation/zoom).
    canvas.save();
    canvas.transform(camera.worldToScreen.toCanvasMatrix4());
    for (final a in visible) {
      _drawWorld(canvas, a);
    }
    _drawDraft(canvas);
    canvas.restore();

    // Notes: fixed-size icons in screen space at projected anchors.
    for (final a in visible) {
      if (a is NoteAnnotation) {
        final p = camera.worldToScreenPoint(a.x, a.y);
        _drawNoteIcon(canvas, Offset(p.x, p.y), Color(a.colorArgb));
      }
    }
  }

  void _drawWorld(Canvas canvas, Annotation a) {
    final color = Color(a.colorArgb);
    switch (a) {
      case InkAnnotation():
        canvas.drawPath(_inkPath(a.points), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = a.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color
          ..isAntiAlias = true);
      case HighlightAnnotation():
        final p = Paint()
          ..style = PaintingStyle.fill
          ..color = color;
        for (final r in a.rects) {
          canvas.drawRect(Rect.fromLTRB(r.minX, r.minY, r.maxX, r.maxY), p);
        }
      case ShapeAnnotation():
        final p = Paint()
          ..style = a.filled ? PaintingStyle.fill : PaintingStyle.stroke
          ..strokeWidth = a.strokeWidth
          ..color = color
          ..isAntiAlias = true;
        final rect = Rect.fromLTRB(a.rect.minX, a.rect.minY, a.rect.maxX, a.rect.maxY);
        if (a.ellipse) {
          canvas.drawOval(rect, p);
        } else {
          canvas.drawRect(rect, p);
        }
      case LineAnnotation():
        canvas.drawLine(Offset(a.x1, a.y1), Offset(a.x2, a.y2), Paint()
          ..strokeWidth = a.strokeWidth
          ..strokeCap = StrokeCap.round
          ..color = color
          ..isAntiAlias = true);
      case NoteAnnotation():
        break; // drawn in screen space
    }
  }

  void _drawDraft(Canvas canvas) {
    if (!controller.isDrawingTool) return;
    final pts = controller.draftWorld;
    if (pts.length < 2) return;
    final color = Color(controller.colorArgb);
    switch (controller.tool) {
      case AnnotationTool.ink:
        final path = Path()..moveTo(pts.first.dx, pts.first.dy);
        for (var i = 1; i < pts.length; i++) {
          path.lineTo(pts[i].dx, pts[i].dy);
        }
        canvas.drawPath(path, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = controller.strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..color = color);
      case AnnotationTool.line:
        canvas.drawLine(pts[0], pts[1], Paint()
          ..strokeWidth = controller.strokeWidth
          ..color = color);
      case AnnotationTool.rectangle:
      case AnnotationTool.highlight:
        final r = Rect.fromPoints(pts[0], pts[1]);
        canvas.drawRect(r, Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = controller.strokeWidth
          ..color = color);
      case AnnotationTool.ellipse:
        canvas.drawOval(Rect.fromPoints(pts[0], pts[1]), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = controller.strokeWidth
          ..color = color);
      default:
        break;
    }
  }

  Path _inkPath(Float64List p) {
    final path = Path()..moveTo(p[0], p[1]);
    for (var i = 2; i + 1 < p.length; i += 2) {
      path.lineTo(p[i], p[i + 1]);
    }
    return path;
  }

  void _drawNoteIcon(Canvas canvas, Offset center, Color color) {
    const r = 10.0;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCircle(center: center, radius: r),
        const Radius.circular(3),
      ),
      Paint()..color = color,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCircle(center: center, radius: r),
        const Radius.circular(3),
      ),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
  }

  @override
  bool shouldRepaint(covariant AnnotationOverlayPainter old) =>
      old.controller.revision != controller.revision ||
      old.camera.center != camera.center ||
      old.camera.scale != camera.scale ||
      old.camera.rotation != camera.rotation;
}

/// Routes raw pointer events to the controller in WORLD coordinates when a
/// drawing/erase tool is active; otherwise lets events fall through to the
/// viewport's own pan/zoom gestures. Provide a [cameraOf] callback returning the
/// live camera so screen->world uses the current transform.
class AnnotationGestureLayer extends StatelessWidget {
  final AnnotationController controller;
  final Camera Function() cameraOf;
  final Widget child;

  const AnnotationGestureLayer({
    super.key,
    required this.controller,
    required this.cameraOf,
    required this.child,
  });

  Offset _toWorld(Offset local) {
    final w = cameraOf().screenToWorldPoint(local.dx, local.dy);
    return Offset(w.x, w.y);
  }

  @override
  Widget build(BuildContext context) {
    final active = controller.tool != AnnotationTool.none;
    if (!active) return child;
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => controller.pointerDown(_toWorld(e.localPosition)),
      onPointerMove: (e) => controller.pointerMove(_toWorld(e.localPosition)),
      onPointerUp: (_) => controller.pointerUp(),
      onPointerCancel: (_) => controller.pointerUp(),
      child: child,
    );
  }
}
