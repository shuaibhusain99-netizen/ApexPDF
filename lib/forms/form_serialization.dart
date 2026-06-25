// form_serialization.dart
//
// Feature 4 — Forms / AcroForm (interchange format).
//
// JSON (de)serialization of form fields. This is what crosses the platform
// channel to the native reader (extract existing field defs + values from the
// PDF's AcroForm) and writer (flatten filled values back in). Exhaustive over
// the sealed field hierarchy; validated on decode.

import '../engine/viewport_core.dart' show Aabb;
import 'form_model.dart';

abstract final class AcroFormCodec {
  static Map<String, Object?> toJson(FormField f) {
    final base = <String, Object?>{
      'kind': f.kind.name,
      'name': f.name,
      'ro': f.isReadOnly,
      'req': f.isRequired,
    };
    switch (f) {
      case PdfTextField():
        base['page'] = f.pageIndex;
        base['rect'] = _rect(f.rect);
        base['value'] = f.value;
        base['multiline'] = f.multiline;
        if (f.maxLength != null) base['max'] = f.maxLength;
      case CheckboxField():
        base['page'] = f.pageIndex;
        base['rect'] = _rect(f.rect);
        base['checked'] = f.checked;
        base['on'] = f.onValue;
      case RadioGroupField():
        base['selected'] = f.selected;
        base['options'] = f.options
            .map((o) => {
                  'export': o.exportValue,
                  'page': o.pageIndex,
                  'rect': _rect(o.rect),
                })
            .toList(growable: false);
      case ChoiceField():
        base['page'] = f.pageIndex;
        base['rect'] = _rect(f.rect);
        base['options'] = f.options;
        base['selected'] = f.selected;
        base['multi'] = f.multiSelect;
        base['editable'] = f.editable;
      case SignatureField():
        base['page'] = f.pageIndex;
        base['rect'] = _rect(f.rect);
        base['signed'] = f.signed;
    }
    return base;
  }

  static FormField fromJson(Map<String, Object?> j) {
    final kindName = _str(j, 'kind');
    final kind = FormFieldKind.values.firstWhere(
      (k) => k.name == kindName,
      orElse: () => throw FormatException('unknown field kind: $kindName'),
    );
    final name = _str(j, 'name');
    final ro = _boolOr(j, 'ro', false);
    final req = _boolOr(j, 'req', false);

    switch (kind) {
      case FormFieldKind.text:
        return PdfTextField(
          name: name,
          pageIndex: _int(j, 'page'),
          rect: _toRect(_list(j, 'rect')),
          value: _strOr(j, 'value', ''),
          maxLength: j['max'] is int ? j['max'] as int : null,
          multiline: _boolOr(j, 'multiline', false),
          isReadOnly: ro,
          isRequired: req,
        );
      case FormFieldKind.checkbox:
        return CheckboxField(
          name: name,
          pageIndex: _int(j, 'page'),
          rect: _toRect(_list(j, 'rect')),
          checked: _boolOr(j, 'checked', false),
          onValue: _strOr(j, 'on', 'Yes'),
          isReadOnly: ro,
          isRequired: req,
        );
      case FormFieldKind.radio:
        final opts = _list(j, 'options').map((e) {
          final m = (e as Map).cast<String, Object?>();
          return RadioOption(
            exportValue: _str(m, 'export'),
            pageIndex: _int(m, 'page'),
            rect: _toRect(_list(m, 'rect')),
          );
        }).toList();
        return RadioGroupField(
          name: name,
          options: opts,
          selected: j['selected'] is String ? j['selected'] as String : null,
          isReadOnly: ro,
          isRequired: req,
        );
      case FormFieldKind.choice:
        return ChoiceField(
          name: name,
          pageIndex: _int(j, 'page'),
          rect: _toRect(_list(j, 'rect')),
          options: _list(j, 'options').map((e) => e as String).toList(),
          selected:
              _list(j, 'selected').map((e) => e as String).toList(),
          multiSelect: _boolOr(j, 'multi', false),
          editable: _boolOr(j, 'editable', false),
          isReadOnly: ro,
          isRequired: req,
        );
      case FormFieldKind.signature:
        return SignatureField(
          name: name,
          pageIndex: _int(j, 'page'),
          rect: _toRect(_list(j, 'rect')),
          signed: _boolOr(j, 'signed', false),
          isReadOnly: ro,
          isRequired: req,
        );
    }
  }

  static List<Map<String, Object?>> encodeAll(Iterable<FormField> fs) =>
      fs.map(toJson).toList(growable: false);

  static List<FormField> decodeAll(List<Object?> items) => items
      .map((e) => fromJson((e as Map).cast<String, Object?>()))
      .toList(growable: false);

  // --- helpers --------------------------------------------------------------

  static List<double> _rect(Aabb r) => [r.minX, r.minY, r.maxX, r.maxY];

  static Aabb _toRect(List<Object?> l) {
    if (l.length != 4) {
      throw FormatException('rect must have 4 numbers, got ${l.length}');
    }
    double d(Object? v) =>
        v is num ? v.toDouble() : throw const FormatException('rect needs numbers');
    return Aabb(d(l[0]), d(l[1]), d(l[2]), d(l[3]));
  }

  static String _str(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is String) return v;
    throw FormatException('field "$k" must be a String');
  }

  static String _strOr(Map<String, Object?> j, String k, String fallback) {
    final v = j[k];
    return v is String ? v : fallback;
  }

  static int _int(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is int) return v;
    if (v is num) return v.toInt();
    throw FormatException('field "$k" must be an int');
  }

  static bool _boolOr(Map<String, Object?> j, String k, bool fallback) {
    final v = j[k];
    return v is bool ? v : fallback;
  }

  static List<Object?> _list(Map<String, Object?> j, String k) {
    final v = j[k];
    if (v is List) return v;
    throw FormatException('field "$k" must be a List');
  }
}
