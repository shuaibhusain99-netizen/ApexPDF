// annotation_serialization.dart
//
// Feature 1 — Annotations (persistence / interchange).
//
// JSON (de)serialization for the sealed Annotation hierarchy. This is the
// on-disk sidecar format AND the payload handed across the platform channel to
// the native PdfBox-Android writer that embeds annotations as real PDF
// annotation dictionaries. Pure Dart, exhaustive, validated on decode.

import 'dart:typed_data';

import '../engine/viewport_core.dart' show Aabb;
import 'annotation_model.dart';

abstract final class AnnotationCodec {
  /// Encodes a single annotation to a JSON-safe map.
  static Map<String, Object?> toJson(Annotation a) {
    final base = <String, Object?>{
      'kind': a.kind.name,
      'id': a.id,
      'page': a.pageIndex,
      'color': a.colorArgb,
    };
    switch (a) {
      case InkAnnotation():
        base['points'] = a.points.toList(growable: false);
        base['stroke'] = a.strokeWidth;
      case HighlightAnnotation():
        base['rects'] = a.rects.map(_rectToList).toList(growable: false);
      case ShapeAnnotation():
        base['rect'] = _rectToList(a.rect);
        base['ellipse'] = a.ellipse;
        base['filled'] = a.filled;
        base['stroke'] = a.strokeWidth;
      case LineAnnotation():
        base['p'] = <double>[a.x1, a.y1, a.x2, a.y2];
        base['stroke'] = a.strokeWidth;
      case NoteAnnotation():
        base['x'] = a.x;
        base['y'] = a.y;
        base['text'] = a.text;
        base['r'] = a.iconRadius;
    }
    return base;
  }

  /// Decodes a single annotation from a map. Throws [FormatException] on any
  /// missing/ill-typed field.
  static Annotation fromJson(Map<String, Object?> j) {
    final kindName = _str(j, 'kind');
    final kind = AnnotationKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => throw FormatException('unknown annotation kind: $kindName'),
    );
    final id = _str(j, 'id');
    final page = _int(j, 'page');
    final color = _int(j, 'color');

    switch (kind) {
      case AnnotationKind.ink:
        return InkAnnotation(
          id: id,
          pageIndex: page,
          colorArgb: color,
          points: Float64List.fromList(_doubleList(j, 'points')),
          strokeWidth: _double(j, 'stroke'),
        );
      case AnnotationKind.highlight:
        final raw = _list(j, 'rects');
        final rects = raw
            .map((e) => _listToRect(e as List))
            .toList(growable: false);
        return HighlightAnnotation(
          id: id,
          pageIndex: page,
          colorArgb: color,
          rects: rects,
        );
      case AnnotationKind.rectangle:
      case AnnotationKind.ellipse:
        return ShapeAnnotation(
          id: id,
          pageIndex: page,
          colorArgb: color,
          rect: _listToRect(_list(j, 'rect')),
          ellipse: kind == AnnotationKind.ellipse || _bool(j, 'ellipse'),
          filled: _bool(j, 'filled'),
          strokeWidth: _double(j, 'stroke'),
        );
      case AnnotationKind.line:
        final p = _doubleList(j, 'p');
        if (p.length != 4) {
          throw const FormatException('line "p" must have 4 numbers');
        }
        return LineAnnotation(
          id: id,
          pageIndex: page,
          colorArgb: color,
          x1: p[0],
          y1: p[1],
          x2: p[2],
          y2: p[3],
          strokeWidth: _double(j, 'stroke'),
        );
      case AnnotationKind.note:
        return NoteAnnotation(
          id: id,
          pageIndex: page,
          colorArgb: color,
          x: _double(j, 'x'),
          y: _double(j, 'y'),
          text: _str(j, 'text'),
          iconRadius: _double(j, 'r'),
        );
    }
  }

  static List<Map<String, Object?>> encodeAll(Iterable<Annotation> items) =>
      items.map(toJson).toList(growable: false);

  static List<Annotation> decodeAll(List<Object?> items) => items
      .map((e) => fromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);

  // --- helpers --------------------------------------------------------------

  static List<double> _rectToList(Aabb r) => <double>[r.minX, r.minY, r.maxX, r.maxY];

  static Aabb _listToRect(List<Object?> l) {
    if (l.length != 4) {
      throw FormatException('rect must have 4 numbers, got ${l.length}');
    }
    return Aabb(
      _asDouble(l[0]),
      _asDouble(l[1]),
      _asDouble(l[2]),
      _asDouble(l[3]),
    );
  }

  static double _asDouble(Object? v) {
    if (v is num) return v.toDouble();
    throw FormatException('expected number, got ${v.runtimeType}');
  }

  static String _str(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is String) return v;
    throw FormatException('field "$k" must be a String');
  }

  static int _int(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw FormatException('field "$k" must be an int');
  }

  static double _double(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is num) return v.toDouble();
    throw FormatException('field "$k" must be a number');
  }

  static bool _bool(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is bool) return v;
    throw FormatException('field "$k" must be a bool');
  }

  static List<Object?> _list(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is List) return v;
    throw FormatException('field "$k" must be a List');
  }

  static List<double> _doubleList(Map<String, Object?> j, String k) =>
      _list(j, k).map(_asDouble).toList(growable: false);
}
