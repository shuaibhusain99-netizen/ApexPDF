// signing_serialization.dart
//
// Feature 6 — Signing (manifest out, verification report in).
//
// requestToJson produces the manifest handed across the platform channel to the
// native signer. SignatureVerificationReport models what the native verifier
// returns, with a single place that decides overall validity so UI and tests
// agree on the meaning of each component.

import '../engine/viewport_core.dart' show Aabb;
import 'signing_model.dart';

abstract final class SigningCodec {
  static Map<String, Object?> requestToJson(SigningRequest r) => {
        'field': r.placement.fieldName,
        'page': r.placement.pageIndex,
        'rect': [
          r.placement.rect.minX,
          r.placement.rect.minY,
          r.placement.rect.maxX,
          r.placement.rect.maxY,
        ],
        'alias': r.signer.keystoreAlias,
        if (r.signer.name != null) 'name': r.signer.name,
        if (r.signer.reason != null) 'reason': r.signer.reason,
        if (r.signer.location != null) 'location': r.signer.location,
        if (r.signer.contactInfo != null) 'contact': r.signer.contactInfo,
        'appearance': {
          'visible': r.appearance.visible,
          'showName': r.appearance.showName,
          'showReason': r.appearance.showReason,
          'showDate': r.appearance.showDate,
          'showLocation': r.appearance.showLocation,
          if (r.appearance.logoImageRef != null) 'logo': r.appearance.logoImageRef,
        },
        'level': r.level.name,
        'hash': r.hashAlgorithm.name,
        if (r.tsaUrl != null) 'tsa': r.tsaUrl,
        'revocation': r.embedRevocationInfo,
      };

  static SigningRequest requestFromJson(Map<String, Object?> j) {
    String reqStr(String k) {
      final v = j[k];
      if (v is String) return v;
      throw FormatException('"$k" must be a String');
    }

    int reqInt(String k) {
      final v = j[k];
      if (v is int) return v;
      throw FormatException('"$k" must be an int');
    }

    final rect = j['rect'];
    if (rect is! List || rect.length != 4) {
      throw const FormatException('"rect" must be 4 numbers');
    }
    double d(Object? v) =>
        v is num ? v.toDouble() : throw const FormatException('rect needs numbers');

    final ap = (j['appearance'] as Map?)?.cast<String, Object?>() ?? const {};
    bool ab(String k, bool dflt) => ap[k] is bool ? ap[k] as bool : dflt;

    final level = PadesLevel.values.firstWhere(
      (l) => l.name == j['level'],
      orElse: () => throw FormatException('unknown level ${j['level']}'),
    );
    final hash = SignatureHashAlgorithm.values.firstWhere(
      (h) => h.name == j['hash'],
      orElse: () => throw FormatException('unknown hash ${j['hash']}'),
    );

    return SigningRequest(
      placement: SignatureFieldPlacement(
        fieldName: reqStr('field'),
        pageIndex: reqInt('page'),
        rect: Aabb(d(rect[0]), d(rect[1]), d(rect[2]), d(rect[3])),
      ),
      signer: SignerInfo(
        keystoreAlias: reqStr('alias'),
        name: j['name'] as String?,
        reason: j['reason'] as String?,
        location: j['location'] as String?,
        contactInfo: j['contact'] as String?,
      ),
      appearance: SignatureAppearance(
        visible: ab('visible', true),
        showName: ab('showName', true),
        showReason: ab('showReason', true),
        showDate: ab('showDate', true),
        showLocation: ab('showLocation', false),
        logoImageRef: ap['logo'] as String?,
      ),
      level: level,
      hashAlgorithm: hash,
      tsaUrl: j['tsa'] as String?,
      embedRevocationInfo: j['revocation'] is bool ? j['revocation'] as bool : false,
    );
  }
}

/// Certificate revocation status as reported by the verifier.
enum RevocationStatus { good, revoked, unknown, notChecked }

/// Overall meaning of a verified signature.
enum SignatureValidity { valid, validWithWarnings, invalid }

/// What the native verifier returns for one signature.
final class SignatureVerificationReport {
  final bool cryptographicallyValid;
  final bool coversWholeDocument;

  /// null = the signature carries no trusted timestamp.
  final bool? timestampValid;
  final RevocationStatus revocation;
  final String? signerName;
  final DateTime? signedAt;

  const SignatureVerificationReport({
    required this.cryptographicallyValid,
    required this.coversWholeDocument,
    this.timestampValid,
    this.revocation = RevocationStatus.notChecked,
    this.signerName,
    this.signedAt,
  });

  /// The single source of truth for how the components combine. Hard failures
  /// (bad signature, partial coverage, revoked cert, invalid timestamp) are
  /// invalid; soft issues (unknown/unchecked revocation, no trusted time) are
  /// warnings.
  SignatureValidity get overall {
    if (!cryptographicallyValid ||
        !coversWholeDocument ||
        revocation == RevocationStatus.revoked ||
        timestampValid == false) {
      return SignatureValidity.invalid;
    }
    final warn = timestampValid == null ||
        revocation == RevocationStatus.unknown ||
        revocation == RevocationStatus.notChecked;
    return warn ? SignatureValidity.validWithWarnings : SignatureValidity.valid;
  }

  static SignatureVerificationReport fromJson(Map<String, Object?> j) {
    bool b(String k) => j[k] == true;
    final ts = j['timestampValid'];
    final rev = RevocationStatus.values.firstWhere(
      (r) => r.name == j['revocation'],
      orElse: () => RevocationStatus.notChecked,
    );
    final signedAtStr = j['signedAt'];
    return SignatureVerificationReport(
      cryptographicallyValid: b('cryptographicallyValid'),
      coversWholeDocument: b('coversWholeDocument'),
      timestampValid: ts is bool ? ts : null,
      revocation: rev,
      signerName: j['signerName'] as String?,
      signedAt: signedAtStr is String ? DateTime.tryParse(signedAtStr) : null,
    );
  }
}
