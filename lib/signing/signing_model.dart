// signing_model.dart
//
// Feature 6 — Digital signing / PAdES (request + parameter validation).
//
// HONEST SCOPE: the cryptography (CMS/PKCS#7 container via BouncyCastle, Android
// Keystore key access, TSA timestamping, DSS/OCSP/CRL embedding) and writing the
// signature into the PDF (PdfBox-Android) are native and cannot run here. What
// IS pure Dart and tested: modeling the signing request, the appearance, and —
// importantly — validating that the chosen PAdES level has the parameters it
// requires BEFORE the native signer runs (a common source of invalid sigs).

import '../engine/viewport_core.dart' show Aabb;

/// PAdES baseline conformance levels, in increasing strength. Order matters for
/// the `>=` comparisons used by validation.
enum PadesLevel {
  /// B-B: basic CMS signature, no trusted time.
  bB,

  /// B-T: adds a trusted timestamp (TSA) over the signature.
  bT,

  /// B-LT: adds long-term validation material (DSS with OCSP/CRL).
  bLT,

  /// B-LTA: adds a document timestamp for archival (LT + archive TS).
  bLTA,
}

extension PadesLevelRules on PadesLevel {
  bool get requiresTimestamp => index >= PadesLevel.bT.index;
  bool get requiresRevocation => index >= PadesLevel.bLT.index;
  bool get requiresArchiveTimestamp => index >= PadesLevel.bLTA.index;
}

/// Message-digest algorithms permitted for the signature.
enum SignatureHashAlgorithm { sha256, sha384, sha512 }

extension SignatureHashAlgorithmMeta on SignatureHashAlgorithm {
  /// Object identifier used in the CMS SignerInfo.
  String get oid => switch (this) {
        SignatureHashAlgorithm.sha256 => '2.16.840.1.101.3.4.2.1',
        SignatureHashAlgorithm.sha384 => '2.16.840.1.101.3.4.2.2',
        SignatureHashAlgorithm.sha512 => '2.16.840.1.101.3.4.2.3',
      };

  int get digestLengthBytes => switch (this) {
        SignatureHashAlgorithm.sha256 => 32,
        SignatureHashAlgorithm.sha384 => 48,
        SignatureHashAlgorithm.sha512 => 64,
      };

  String get label => switch (this) {
        SignatureHashAlgorithm.sha256 => 'SHA-256',
        SignatureHashAlgorithm.sha384 => 'SHA-384',
        SignatureHashAlgorithm.sha512 => 'SHA-512',
      };
}

/// Who is signing and the human-readable signature metadata.
final class SignerInfo {
  /// Alias of the private key in the Android Keystore (or PKCS#12 entry).
  final String keystoreAlias;
  final String? name;
  final String? reason;
  final String? location;
  final String? contactInfo;

  SignerInfo({
    required this.keystoreAlias,
    this.name,
    this.reason,
    this.location,
    this.contactInfo,
  });
}

/// Visible appearance of the signature (ignored when [visible] is false, which
/// produces an invisible signature with no widget).
final class SignatureAppearance {
  final bool visible;
  final bool showName;
  final bool showReason;
  final bool showDate;
  final bool showLocation;
  final String? logoImageRef;

  const SignatureAppearance({
    this.visible = true,
    this.showName = true,
    this.showReason = true,
    this.showDate = true,
    this.showLocation = false,
    this.logoImageRef,
  });

  static const SignatureAppearance invisible =
      SignatureAppearance(visible: false);
}

/// Where the (visible) signature widget sits.
final class SignatureFieldPlacement {
  final String fieldName;
  final int pageIndex;
  final Aabb rect; // PDF points

  SignatureFieldPlacement({
    required this.fieldName,
    required this.pageIndex,
    required this.rect,
  }) {
    if (fieldName.isEmpty) throw ArgumentError('signature field name required');
    if (pageIndex < 0) throw ArgumentError('pageIndex must be >= 0');
  }
}

/// A complete request to sign a document.
final class SigningRequest {
  final SignatureFieldPlacement placement;
  final SignerInfo signer;
  final SignatureAppearance appearance;
  final PadesLevel level;
  final SignatureHashAlgorithm hashAlgorithm;

  /// RFC-3161 Time-Stamping Authority URL (required for B-T and above).
  final String? tsaUrl;

  /// Whether to embed OCSP/CRL revocation material (required for B-LT+).
  final bool embedRevocationInfo;

  SigningRequest({
    required this.placement,
    required this.signer,
    this.appearance = const SignatureAppearance(),
    this.level = PadesLevel.bLT,
    this.hashAlgorithm = SignatureHashAlgorithm.sha256,
    this.tsaUrl,
    this.embedRevocationInfo = false,
  });

  /// Returns validation errors ([] when the request is internally consistent and
  /// satisfies the requirements of its PAdES level).
  List<String> validate() {
    final e = <String>[];

    if (signer.keystoreAlias.isEmpty) {
      e.add('signer keystore alias is required');
    }

    if (appearance.visible && !(placement.rect.area > 0)) {
      e.add('a visible signature needs a non-empty rectangle');
    }

    if (level.requiresTimestamp) {
      final url = tsaUrl;
      if (url == null || url.isEmpty) {
        e.add('PAdES ${_levelName(level)} requires a TSA url for timestamping');
      } else if (!_isHttpUrl(url)) {
        e.add('TSA url must be an http(s) URL');
      }
    }

    if (level.requiresRevocation && !embedRevocationInfo) {
      e.add('PAdES ${_levelName(level)} requires embedded revocation info (DSS)');
    }

    return e;
  }

  bool get isValid => validate().isEmpty;

  static String _levelName(PadesLevel l) => switch (l) {
        PadesLevel.bB => 'B-B',
        PadesLevel.bT => 'B-T',
        PadesLevel.bLT => 'B-LT',
        PadesLevel.bLTA => 'B-LTA',
      };

  static bool _isHttpUrl(String s) {
    final u = Uri.tryParse(s);
    return u != null &&
        (u.scheme == 'http' || u.scheme == 'https') &&
        u.host.isNotEmpty;
  }
}
