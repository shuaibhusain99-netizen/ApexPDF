// form_test.dart — Feature 4 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/forms/form_model.dart';
import 'package:ultimate_pdf/forms/form_store.dart';
import 'package:ultimate_pdf/forms/form_serialization.dart';

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
        .firstWhere((l) => l.contains('form_test.dart'), orElse: () => '');
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
  if (a != b) throw StateError('$l expected "$b" got "$a"');
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

const r = Aabb(0, 0, 100, 20);

void main() {
  group('Field validation', () {
    test('text: required + maxLength', () {
      final empty = PdfTextField(
          name: 't', pageIndex: 0, rect: r, value: '', isRequired: true);
      check(empty.validate().isNotEmpty, 'required empty invalid');
      empty.value = 'hello';
      check(empty.validate().isEmpty, 'filled valid');
      final capped =
          PdfTextField(name: 't2', pageIndex: 0, rect: r, value: 'abcdef', maxLength: 3);
      check(capped.validate().any((m) => m.contains('max length')), 'too long');
      eq(capped.widgets.length, 1, 'one widget');
    });

    test('checkbox: export state + required', () {
      final c = CheckboxField(name: 'c', pageIndex: 0, rect: r, onValue: 'Yes');
      eq(c.exportState, 'Off', 'unchecked -> Off');
      c.checked = true;
      eq(c.exportState, 'Yes', 'checked -> on value');
      final reqd =
          CheckboxField(name: 'c2', pageIndex: 0, rect: r, isRequired: true);
      check(reqd.validate().isNotEmpty, 'required unchecked invalid');
    });

    test('radio: widgets, exports, validation', () {
      final radio = RadioGroupField(
        name: 'rg',
        isRequired: true,
        options: const [
          RadioOption(exportValue: 'a', pageIndex: 0, rect: r),
          RadioOption(exportValue: 'b', pageIndex: 1, rect: r),
        ],
      );
      eq(radio.widgets.length, 2, 'two widgets');
      check(radio.exportValues.containsAll({'a', 'b'}), 'exports');
      check(radio.validate().isNotEmpty, 'required, none selected');
      radio.selected = 'a';
      check(radio.validate().isEmpty, 'selected valid');
      throws(
          () => RadioGroupField(
              name: 'x',
              options: const [RadioOption(exportValue: 'a', pageIndex: 0, rect: r)],
              selected: 'zzz'),
          'invalid initial selection');
    });

    test('choice: membership, multi-select', () {
      final single = ChoiceField(
          name: 'ch',
          pageIndex: 0,
          rect: r,
          options: const ['x', 'y'],
          selected: ['z']);
      check(single.validate().any((m) => m.contains('not an option')), 'bad member');
      final multi = ChoiceField(
          name: 'ch2',
          pageIndex: 0,
          rect: r,
          options: const ['x', 'y'],
          selected: ['x', 'y'],
          multiSelect: false);
      check(multi.validate().any((m) => m.contains('only one')), 'too many');
      final editable = ChoiceField(
          name: 'ch3',
          pageIndex: 0,
          rect: r,
          options: const ['x'],
          selected: ['custom'],
          editable: true);
      check(editable.validate().isEmpty, 'editable accepts custom');
    });

    test('signature required', () {
      final s = SignatureField(name: 's', pageIndex: 0, rect: r, isRequired: true);
      check(s.validate().isNotEmpty, 'unsigned invalid');
      s.signed = true;
      check(s.validate().isEmpty, 'signed valid');
    });
  });

  group('AcroForm store', () {
    AcroForm form() {
      final f = AcroForm();
      f.add(PdfTextField(name: 'name', pageIndex: 0, rect: r));
      f.add(CheckboxField(name: 'agree', pageIndex: 0, rect: r, isRequired: true));
      f.add(RadioGroupField(
        name: 'plan',
        options: const [
          RadioOption(exportValue: 'free', pageIndex: 0, rect: r),
          RadioOption(exportValue: 'pro', pageIndex: 1, rect: r),
        ],
      ));
      return f;
    }

    test('add rejects duplicate names', () {
      final f = form();
      throws(() => f.add(PdfTextField(name: 'name', pageIndex: 0, rect: r)), 'dup');
    });

    test('fieldsOnPage filters by widget page', () {
      final f = form();
      eq(f.fieldsOnPage(0).length, 3, 'all three touch page 0');
      eq(f.fieldsOnPage(1).map((x) => x.name).toList(), ['plan'], 'radio kid on 1');
      eq(f.fieldsOnPage(2).length, 0, 'none on page 2');
    });

    test('typed mutators update and bump version', () {
      final f = form();
      final v0 = f.version;
      f.setText('name', 'Ada');
      eq((f.getField('name') as PdfTextField).value, 'Ada');
      f.setChecked('agree', true);
      f.selectRadio('plan', 'pro');
      eq((f.getField('plan') as RadioGroupField).selected, 'pro');
      check(f.version > v0, 'version advanced');
    });

    test('mutator guards: type mismatch, bad option, read-only', () {
      final f = form();
      throws(() => f.setText('agree', 'x'), 'text on checkbox');
      throws(() => f.selectRadio('plan', 'nope'), 'invalid option');
      f.add(PdfTextField(name: 'locked', pageIndex: 0, rect: r, isReadOnly: true));
      throws(() => f.setText('locked', 'x'), 'read-only');
    });

    test('selectRadio(null) clears; validateAll aggregates', () {
      final f = form();
      f.selectRadio('plan', 'free');
      f.selectRadio('plan', null);
      eq((f.getField('plan') as RadioGroupField).selected, null, 'cleared');
      // "agree" is required and unchecked -> exactly one error.
      final errs = f.validateAll();
      check(errs.any((e) => e.name == 'agree'), 'required checkbox flagged');
    });
  });

  group('Serialization', () {
    void roundTrip(FormField f) {
      final back = AcroFormCodec.fromJson(AcroFormCodec.toJson(f));
      eq(back.kind, f.kind, 'kind');
      eq(back.name, f.name, 'name');
      eq(back.isRequired, f.isRequired, 'required flag');
    }

    test('all field kinds round-trip', () {
      roundTrip(PdfTextField(
          name: 't', pageIndex: 1, rect: r, value: 'hi', maxLength: 10));
      roundTrip(CheckboxField(
          name: 'c', pageIndex: 0, rect: r, checked: true, onValue: 'On'));
      roundTrip(RadioGroupField(
          name: 'rg',
          selected: 'b',
          options: const [
            RadioOption(exportValue: 'a', pageIndex: 0, rect: r),
            RadioOption(exportValue: 'b', pageIndex: 0, rect: r),
          ]));
      roundTrip(ChoiceField(
          name: 'ch',
          pageIndex: 2,
          rect: r,
          options: const ['x', 'y'],
          selected: ['y'],
          multiSelect: true));
      roundTrip(SignatureField(name: 's', pageIndex: 0, rect: r, signed: true));
    });

    test('values survive a text field round-trip', () {
      final back = AcroFormCodec.fromJson(AcroFormCodec.toJson(
          PdfTextField(name: 't', pageIndex: 3, rect: r, value: 'Ada', maxLength: 5)))
          as PdfTextField;
      eq(back.value, 'Ada');
      eq(back.maxLength, 5);
      eq(back.pageIndex, 3);
    });

    test('decode rejects malformed field', () {
      throws(
          () => AcroFormCodec.fromJson(
              {'kind': 'bogus', 'name': 'x', 'page': 0, 'rect': [0, 0, 1, 1]}),
          'unknown kind');
      throws(
          () => AcroFormCodec.fromJson(
              {'kind': 'text', 'name': 'x', 'page': 0, 'rect': [0, 0, 1]}),
          'bad rect');
    });
  });

  print('');
  print('=============== forms (feature 4) test summary ==============');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
