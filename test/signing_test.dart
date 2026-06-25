// signing_test.dart — Feature 6 core tests (pure Dart, zero-dep harness).

import 'package:ultimate_pdf/engine/viewport_core.dart';
import 'package:ultimate_pdf/signing/signing_model.dart';
import 'package:ultimate_pdf/signing/byte_range.dart';
import 'package:ultimate_pdf/signing/signing_serialization.dart';

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
        .firstWhere((l) => l.contains('signing_test.dart'), orElse: () => '');
    if (f.isNotEmpty) print('    $f');
  }
}

void check(bool c, [String m = 'check failed']) {
  if (!c) throw StateError(m);
}

void eq(Object? a, Object? b, [String l = '']) {
  if (a is List && b is List) {
    if (a.length != b.length) throw StateError('$l len ${a.length} vs ${b.length}');
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) throw StateError('$l at $i: ${a[i]} vs ${b[i]}');
    }
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

SignatureFieldPlacement place({Aabb rect = const Aabb(50, 50, 250, 110)}) =>
    SignatureFieldPlacement(fieldName: 'sig1', pageIndex: 0, rect: rect);

SignerInfo signer({String alias = 'my-key'}) =>
    SignerInfo(keystoreAlias: alias, name: 'Ada', reason: 'Approved');

void main() {
  group('Request validation', () {
    test('B-B invisible signature is valid without rect/tsa', () {
      final r = SigningRequest(
        placement: place(rect: const Aabb(0, 0, 0, 0)),
        signer: signer(),
        appearance: SignatureAppearance.invisible,
        level: PadesLevel.bB,
      );
      check(r.isValid, 'should be valid: ${r.validate()}');
    });

    test('visible signature needs a non-empty rectangle', () {
      final r = SigningRequest(
        placement: place(rect: const Aabb(0, 0, 0, 0)),
        signer: signer(),
        level: PadesLevel.bB,
      );
      check(r.validate().any((m) => m.contains('non-empty rectangle')), 'rect');
    });

    test('B-T requires a valid TSA url', () {
      final noTsa = SigningRequest(
          placement: place(), signer: signer(), level: PadesLevel.bT);
      check(noTsa.validate().any((m) => m.contains('TSA url')), 'missing tsa');

      final badTsa = SigningRequest(
          placement: place(),
          signer: signer(),
          level: PadesLevel.bT,
          tsaUrl: 'ftp://nope');
      check(badTsa.validate().any((m) => m.contains('http(s)')), 'bad scheme');

      final ok = SigningRequest(
          placement: place(),
          signer: signer(),
          level: PadesLevel.bT,
          tsaUrl: 'https://tsa.example.com');
      check(ok.isValid, 'valid tsa: ${ok.validate()}');
    });

    test('B-LT requires embedded revocation info', () {
      final noRev = SigningRequest(
          placement: place(),
          signer: signer(),
          level: PadesLevel.bLT,
          tsaUrl: 'https://tsa.example.com');
      check(noRev.validate().any((m) => m.contains('revocation')), 'needs DSS');

      final ok = SigningRequest(
          placement: place(),
          signer: signer(),
          level: PadesLevel.bLT,
          tsaUrl: 'https://tsa.example.com',
          embedRevocationInfo: true);
      check(ok.isValid, 'valid B-LT: ${ok.validate()}');
    });

    test('empty keystore alias is rejected', () {
      final r = SigningRequest(
          placement: place(), signer: signer(alias: ''), level: PadesLevel.bB);
      check(r.validate().any((m) => m.contains('alias')), 'alias required');
    });
  });

  group('Level rules & hash metadata', () {
    test('level requirement flags', () {
      check(!PadesLevel.bB.requiresTimestamp, 'B-B no ts');
      check(PadesLevel.bT.requiresTimestamp, 'B-T ts');
      check(!PadesLevel.bT.requiresRevocation, 'B-T no rev');
      check(PadesLevel.bLT.requiresRevocation, 'B-LT rev');
      check(PadesLevel.bLTA.requiresArchiveTimestamp, 'B-LTA archive');
    });

    test('hash OIDs and digest sizes', () {
      eq(SignatureHashAlgorithm.sha256.oid, '2.16.840.1.101.3.4.2.1', 'sha256 oid');
      eq(SignatureHashAlgorithm.sha256.digestLengthBytes, 32, 'sha256 len');
      eq(SignatureHashAlgorithm.sha512.digestLengthBytes, 64, 'sha512 len');
    });
  });

  group('ByteRange', () {
    test('computes array, spans, and validates coverage', () {
      final br = ByteRangeCalculator.forPlaceholder(
          fileLength: 1000, holeStart: 100, holeLength: 200);
      eq(br.toPdfArray(), [0, 100, 300, 700], 'array');
      eq(br.holeLength, 200, 'hole length');
      check(br.validFor(1000), 'covers whole file except hole');
      final spans = br.signedSpans();
      eq(spans[0].$1, 0, 's0 start');
      eq(spans[0].$2, 100, 's0 len');
      eq(spans[1].$1, 300, 's1 start');
      eq(spans[1].$2, 700, 's1 len');
    });

    test('rejects impossible placeholders', () {
      throws(
          () => ByteRangeCalculator.forPlaceholder(
              fileLength: 1000, holeStart: 0, holeLength: 10),
          'holeStart 0');
      throws(
          () => ByteRangeCalculator.forPlaceholder(
              fileLength: 1000, holeStart: 900, holeLength: 200),
          'hole past EOF');
    });

    test('validFor catches wrong coverage and touching segments', () {
      check(!const ByteRange(0, 100, 300, 800).validFor(1000), 'overshoots EOF');
      check(!const ByteRange(0, 100, 100, 900).validFor(1000), 'no hole');
      check(!const ByteRange(5, 100, 300, 700).validFor(1000), 'not at 0');
    });
  });

  group('Serialization', () {
    test('signing request round-trips', () {
      final r = SigningRequest(
        placement: place(),
        signer: signer(),
        appearance: const SignatureAppearance(visible: true, logoImageRef: 'logo'),
        level: PadesLevel.bLT,
        hashAlgorithm: SignatureHashAlgorithm.sha384,
        tsaUrl: 'https://tsa.example.com',
        embedRevocationInfo: true,
      );
      final back = SigningCodec.requestFromJson(SigningCodec.requestToJson(r));
      eq(back.level, PadesLevel.bLT, 'level');
      eq(back.hashAlgorithm, SignatureHashAlgorithm.sha384, 'hash');
      eq(back.tsaUrl, 'https://tsa.example.com', 'tsa');
      check(back.embedRevocationInfo, 'revocation flag');
      eq(back.placement.fieldName, 'sig1', 'field');
      eq(back.signer.name, 'Ada', 'name');
      eq(back.appearance.logoImageRef, 'logo', 'logo');
    });

    test('decode rejects malformed request', () {
      throws(
          () => SigningCodec.requestFromJson({
                'field': 'f',
                'page': 0,
                'rect': [0, 0, 1],
                'alias': 'k',
                'level': 'bB',
                'hash': 'sha256'
              }),
          'bad rect');
      throws(
          () => SigningCodec.requestFromJson({
                'field': 'f',
                'page': 0,
                'rect': [0, 0, 1, 1],
                'alias': 'k',
                'level': 'bogus',
                'hash': 'sha256'
              }),
          'unknown level');
    });
  });

  group('Verification report', () {
    SignatureVerificationReport rep({
      bool crypto = true,
      bool covers = true,
      bool? ts = true,
      RevocationStatus rev = RevocationStatus.good,
    }) =>
        SignatureVerificationReport(
          cryptographicallyValid: crypto,
          coversWholeDocument: covers,
          timestampValid: ts,
          revocation: rev,
        );

    test('overall validity combines components correctly', () {
      eq(rep().overall, SignatureValidity.valid, 'all good');
      eq(rep(crypto: false).overall, SignatureValidity.invalid, 'bad crypto');
      eq(rep(covers: false).overall, SignatureValidity.invalid, 'partial coverage');
      eq(rep(rev: RevocationStatus.revoked).overall, SignatureValidity.invalid,
          'revoked');
      eq(rep(ts: false).overall, SignatureValidity.invalid, 'bad timestamp');
      eq(rep(rev: RevocationStatus.unknown).overall,
          SignatureValidity.validWithWarnings, 'unknown revocation');
      eq(rep(ts: null).overall, SignatureValidity.validWithWarnings,
          'no trusted time');
    });

    test('parses from native json', () {
      final r = SignatureVerificationReport.fromJson({
        'cryptographicallyValid': true,
        'coversWholeDocument': true,
        'timestampValid': true,
        'revocation': 'good',
        'signerName': 'Ada Lovelace',
        'signedAt': '2026-01-15T10:30:00Z',
      });
      eq(r.overall, SignatureValidity.valid, 'overall');
      eq(r.signerName, 'Ada Lovelace', 'signer');
      check(r.signedAt != null && r.signedAt!.year == 2026, 'date parsed');
    });
  });

  print('');
  print('=============== signing (feature 6) test summary ===========');
  print('  passed: $_pass');
  print('  failed: $_fail');
  print('============================================================');
  if (_fail > 0) throw StateError('$_fail test(s) failed');
}
