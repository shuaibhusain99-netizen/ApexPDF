// form_model.dart
//
// Feature 4 — Forms / AcroForm (field model + validation).
//
// Models interactive PDF form fields and their on-page widget rectangles. The
// field/value/validation logic is pure Dart and unit-tested here; reading the
// existing AcroForm dictionary and writing filled values back into the PDF is
// native (PdfBox-Android or PDFium) and cannot run in this sandbox. Widget rects
// are PDF points (world space), matching the viewport engine.

import '../engine/viewport_core.dart' show Aabb;

enum FormFieldKind { text, checkbox, radio, choice, signature }

/// One visible widget of a field on a page (a field can have several, e.g. a
/// radio group's buttons).
final class FieldWidget {
  final int pageIndex;
  final Aabb rect; // PDF points
  /// Export value for this specific widget (checkbox "on" state, radio kid).
  final String? exportValue;

  const FieldWidget({
    required this.pageIndex,
    required this.rect,
    this.exportValue,
  });
}

/// Base type for all form fields. Sealed for exhaustive handling.
sealed class FormField {
  /// Fully-qualified field name (unique within the document).
  final String name;
  bool isReadOnly;
  final bool isRequired;

  FormField({
    required this.name,
    this.isReadOnly = false,
    this.isRequired = false,
  }) {
    if (name.isEmpty) throw ArgumentError('field name must not be empty');
  }

  FormFieldKind get kind;

  /// All on-page widgets for this field.
  List<FieldWidget> get widgets;

  /// Returns validation error messages ([] when the field is valid).
  List<String> validate();

  bool get hasWidgetOnAnyPage => widgets.isNotEmpty;
}

/// Free-text field (single or multi-line).
final class PdfTextField extends FormField {
  String value;
  final int? maxLength;
  final bool multiline;
  final int pageIndex;
  final Aabb rect;

  PdfTextField({
    required super.name,
    required this.pageIndex,
    required this.rect,
    this.value = '',
    this.maxLength,
    this.multiline = false,
    super.isReadOnly,
    super.isRequired,
  }) {
    if (maxLength != null && maxLength! < 0) {
      throw ArgumentError.value(maxLength, 'maxLength', 'must be >= 0');
    }
  }

  @override
  FormFieldKind get kind => FormFieldKind.text;

  @override
  List<FieldWidget> get widgets =>
      [FieldWidget(pageIndex: pageIndex, rect: rect)];

  @override
  List<String> validate() {
    final e = <String>[];
    if (isRequired && value.trim().isEmpty) e.add('"$name" is required');
    if (maxLength != null && value.length > maxLength!) {
      e.add('"$name" exceeds max length $maxLength');
    }
    return e;
  }
}

/// On/off checkbox.
final class CheckboxField extends FormField {
  bool checked;
  final String onValue; // export when checked (e.g. "Yes")
  final int pageIndex;
  final Aabb rect;

  CheckboxField({
    required super.name,
    required this.pageIndex,
    required this.rect,
    this.checked = false,
    this.onValue = 'Yes',
    super.isReadOnly,
    super.isRequired,
  }) {
    if (onValue.isEmpty || onValue == 'Off') {
      throw ArgumentError('checkbox onValue must be non-empty and not "Off"');
    }
  }

  @override
  FormFieldKind get kind => FormFieldKind.checkbox;

  /// AcroForm export state: the on-value when checked, else "Off".
  String get exportState => checked ? onValue : 'Off';

  @override
  List<FieldWidget> get widgets =>
      [FieldWidget(pageIndex: pageIndex, rect: rect, exportValue: onValue)];

  @override
  List<String> validate() {
    final e = <String>[];
    if (isRequired && !checked) e.add('"$name" must be checked');
    return e;
  }
}

/// One button of a radio group.
final class RadioOption {
  final String exportValue;
  final int pageIndex;
  final Aabb rect;
  const RadioOption({
    required this.exportValue,
    required this.pageIndex,
    required this.rect,
  });
}

/// Mutually-exclusive radio group (one field, several widgets).
final class RadioGroupField extends FormField {
  final List<RadioOption> options;
  String? selected; // an exportValue, or null

  RadioGroupField({
    required super.name,
    required this.options,
    this.selected,
    super.isReadOnly,
    super.isRequired,
  }) {
    if (options.isEmpty) throw ArgumentError('radio group needs options');
    final exports = options.map((o) => o.exportValue).toList();
    if (exports.toSet().length != exports.length) {
      throw ArgumentError('radio export values must be unique');
    }
    if (selected != null && !exports.contains(selected)) {
      throw ArgumentError('selected "$selected" is not an option of "$name"');
    }
  }

  @override
  FormFieldKind get kind => FormFieldKind.radio;

  Set<String> get exportValues =>
      options.map((o) => o.exportValue).toSet();

  @override
  List<FieldWidget> get widgets => options
      .map((o) => FieldWidget(
          pageIndex: o.pageIndex, rect: o.rect, exportValue: o.exportValue))
      .toList(growable: false);

  @override
  List<String> validate() {
    final e = <String>[];
    if (isRequired && selected == null) e.add('"$name" requires a selection');
    if (selected != null && !exportValues.contains(selected)) {
      e.add('"$name" has an invalid selection');
    }
    return e;
  }
}

/// Dropdown / list box. [editable] models a combo box that accepts custom text.
final class ChoiceField extends FormField {
  final List<String> options;
  List<String> selected;
  final bool multiSelect;
  final bool editable;
  final int pageIndex;
  final Aabb rect;

  ChoiceField({
    required super.name,
    required this.pageIndex,
    required this.rect,
    required this.options,
    List<String>? selected,
    this.multiSelect = false,
    this.editable = false,
    super.isReadOnly,
    super.isRequired,
  }) : selected = selected ?? <String>[];

  @override
  FormFieldKind get kind => FormFieldKind.choice;

  @override
  List<FieldWidget> get widgets =>
      [FieldWidget(pageIndex: pageIndex, rect: rect)];

  @override
  List<String> validate() {
    final e = <String>[];
    if (isRequired && selected.isEmpty) e.add('"$name" requires a selection');
    if (!multiSelect && selected.length > 1) {
      e.add('"$name" allows only one selection');
    }
    if (!editable) {
      for (final s in selected) {
        if (!options.contains(s)) e.add('"$name": "$s" is not an option');
      }
    }
    return e;
  }
}

/// Signature field (presence only; signing itself is Feature 6).
final class SignatureField extends FormField {
  bool signed;
  final int pageIndex;
  final Aabb rect;

  SignatureField({
    required super.name,
    required this.pageIndex,
    required this.rect,
    this.signed = false,
    super.isReadOnly,
    super.isRequired,
  });

  @override
  FormFieldKind get kind => FormFieldKind.signature;

  @override
  List<FieldWidget> get widgets =>
      [FieldWidget(pageIndex: pageIndex, rect: rect)];

  @override
  List<String> validate() {
    final e = <String>[];
    if (isRequired && !signed) e.add('"$name" must be signed');
    return e;
  }
}
