// byte_range.dart
//
// Feature 6 — PDF signature /ByteRange.
//
// A PDF signature reserves a /Contents <....> placeholder; the /ByteRange must
// cover the ENTIRE file except those reserved bytes, as two segments. Getting
// this wrong silently produces signatures that "verify" over the wrong bytes, so
// the computation and a coverage check are isolated here and unit-tested. The
// native signer digests exactly the spans returned by [signedSpans] and writes
// the CMS container into the hole.

/// A PDF /ByteRange = [offset1 length1 offset2 length2]. The signed region is
/// [offset1, offset1+length1) ∪ [offset2, offset2+length2); the gap between them
/// is the reserved /Contents value (the "hole").
final class ByteRange {
  final int offset1;
  final int length1;
  final int offset2;
  final int length2;

  const ByteRange(this.offset1, this.length1, this.offset2, this.length2);

  List<int> toPdfArray() => [offset1, length1, offset2, length2];

  int get holeStart => offset1 + length1;
  int get holeEnd => offset2;
  int get holeLength => offset2 - (offset1 + length1);

  /// The (start, length) byte spans the signer must hash, in order.
  List<(int, int)> signedSpans() => [(offset1, length1), (offset2, length2)];

  /// True iff this range is well-formed and covers all of [fileLength] except a
  /// single positive-length hole: starts at 0, non-negative lengths, ordered
  /// segments with a real gap, and the second segment ends exactly at EOF.
  bool validFor(int fileLength) {
    if (offset1 != 0) return false;
    if (length1 < 0 || length2 < 0) return false;
    if (holeLength <= 0) return false; // segments must not touch/overlap
    return offset2 + length2 == fileLength;
  }

  @override
  bool operator ==(Object other) =>
      other is ByteRange &&
      other.offset1 == offset1 &&
      other.length1 == length1 &&
      other.offset2 == offset2 &&
      other.length2 == length2;

  @override
  int get hashCode => Object.hash(offset1, length1, offset2, length2);

  @override
  String toString() => 'ByteRange[$offset1 $length1 $offset2 $length2]';
}

abstract final class ByteRangeCalculator {
  /// Computes the /ByteRange for a file of [fileLength] bytes whose /Contents
  /// value occupies [holeStart, holeStart+holeLength) (the bytes the signer
  /// fills, between the `<` and `>`).
  static ByteRange forPlaceholder({
    required int fileLength,
    required int holeStart,
    required int holeLength,
  }) {
    if (holeStart <= 0) {
      throw ArgumentError.value(holeStart, 'holeStart', 'must be > 0');
    }
    if (holeLength <= 0) {
      throw ArgumentError.value(holeLength, 'holeLength', 'must be > 0');
    }
    final holeEnd = holeStart + holeLength;
    if (holeEnd > fileLength) {
      throw ArgumentError('hole [$holeStart,$holeEnd) exceeds file length '
          '$fileLength');
    }
    return ByteRange(0, holeStart, holeEnd, fileLength - holeEnd);
  }
}
