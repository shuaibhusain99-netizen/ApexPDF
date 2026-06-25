// form_store.dart
//
// Feature 4 — Forms / AcroForm (document container + mutation + validation).

import 'dart:collection';

import 'form_model.dart';

/// A single validation problem: which field, what went wrong.
final class FieldError {
  final String name;
  final String message;
  const FieldError(this.name, this.message);
  @override
  String toString() => message;
}

/// All form fields in a document, with typed mutators and validation.
final class AcroForm {
  final LinkedHashMap<String, FormField> _byName =
      LinkedHashMap<String, FormField>();
  int _version = 0;

  int get version => _version;
  int get length => _byName.length;
  Iterable<FormField> get fields => _byName.values;

  FormField? getField(String name) => _byName[name];
  bool contains(String name) => _byName.containsKey(name);

  void add(FormField field) {
    if (_byName.containsKey(field.name)) {
      throw ArgumentError('duplicate field name ${field.name}');
    }
    _byName[field.name] = field;
    _version++;
  }

  /// Fields with at least one widget on [pageIndex] (for overlay rendering).
  List<FormField> fieldsOnPage(int pageIndex) => _byName.values
      .where((f) => f.widgets.any((w) => w.pageIndex == pageIndex))
      .toList(growable: false);

  // --- typed mutators -------------------------------------------------------

  void setText(String name, String value) {
    final f = _require<PdfTextField>(name);
    _guardEditable(f);
    f.value = value;
    _version++;
  }

  void setChecked(String name, bool checked) {
    final f = _require<CheckboxField>(name);
    _guardEditable(f);
    f.checked = checked;
    _version++;
  }

  /// Selects a radio option by export value, or clears it with null. Throws if
  /// the export value is not an option of the group.
  void selectRadio(String name, String? exportValue) {
    final f = _require<RadioGroupField>(name);
    _guardEditable(f);
    if (exportValue != null && !f.exportValues.contains(exportValue)) {
      throw ArgumentError('"$exportValue" is not an option of "$name"');
    }
    f.selected = exportValue;
    _version++;
  }

  void setChoice(String name, List<String> selection) {
    final f = _require<ChoiceField>(name);
    _guardEditable(f);
    if (!f.multiSelect && selection.length > 1) {
      throw ArgumentError('"$name" allows only one selection');
    }
    if (!f.editable) {
      for (final s in selection) {
        if (!f.options.contains(s)) {
          throw ArgumentError('"$name": "$s" is not an option');
        }
      }
    }
    f.selected = List<String>.of(selection);
    _version++;
  }

  void setSigned(String name, bool signed) {
    final f = _require<SignatureField>(name);
    f.signed = signed;
    _version++;
  }

  // --- validation -----------------------------------------------------------

  /// All validation problems across the document ([] when fully valid).
  List<FieldError> validateAll() {
    final out = <FieldError>[];
    for (final f in _byName.values) {
      for (final msg in f.validate()) {
        out.add(FieldError(f.name, msg));
      }
    }
    return out;
  }

  bool get isValid => validateAll().isEmpty;

  // --- helpers --------------------------------------------------------------

  T _require<T extends FormField>(String name) {
    final f = _byName[name];
    if (f == null) throw ArgumentError('no field named "$name"');
    if (f is! T) {
      throw ArgumentError('field "$name" is ${f.kind.name}, not a $T');
    }
    return f;
  }

  void _guardEditable(FormField f) {
    if (f.isReadOnly) throw StateError('field "${f.name}" is read-only');
  }
}
