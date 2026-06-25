// text_script.dart
//
// Feature 7 — Multilingual text (script + bidi classification).
//
// Classifies Unicode code points by script and by bidirectional class. This is
// the pure-Dart input to the native shaping/fallback stage: it tells the native
// HarfBuzz shaper which script (and direction) each run is, and which font to
// pick via PDFium fallback. Covers the scripts in the app's supported locales;
// the actual glyph shaping and CID-font embedding are native.

/// Scripts recognized for segmentation. `common` = script-neutral (spaces,
/// punctuation, digits); `unknown` = everything else.
enum TextScript {
  latin,
  cyrillic,
  greek,
  arabic,
  hebrew,
  han,
  hiragana,
  katakana,
  hangul,
  devanagari,
  bengali,
  tamil,
  thai,
  common,
  unknown,
}

/// Bidirectional class, reduced to what base-direction resolution needs.
enum BidiClass { ltr, rtl, neutral }

/// True for scripts written right-to-left.
bool isStrongRtlScript(TextScript s) =>
    s == TextScript.arabic || s == TextScript.hebrew;

/// Resolves the script of a single Unicode code point.
TextScript scriptOf(int cp) {
  // Script-neutral first (ASCII space/punct/digits + general punctuation).
  if (cp == 0x20 || cp == 0x09 || cp == 0x0A || cp == 0x0D) return TextScript.common;
  if (cp >= 0x21 && cp <= 0x2F) return TextScript.common;
  if (cp >= 0x30 && cp <= 0x39) return TextScript.common; // digits
  if (cp >= 0x3A && cp <= 0x40) return TextScript.common;
  if (cp >= 0x5B && cp <= 0x60) return TextScript.common;
  if (cp >= 0x7B && cp <= 0x7E) return TextScript.common;
  if (cp >= 0x2000 && cp <= 0x206F) return TextScript.common; // general punctuation

  // Latin (Basic + Latin-1 letters + Extended-A/B).
  if ((cp >= 0x41 && cp <= 0x5A) || (cp >= 0x61 && cp <= 0x7A)) {
    return TextScript.latin;
  }
  if (cp >= 0x00C0 && cp <= 0x024F) return TextScript.latin;

  if (cp >= 0x0370 && cp <= 0x03FF) return TextScript.greek;
  if (cp >= 0x0400 && cp <= 0x04FF) return TextScript.cyrillic;
  if (cp >= 0x0590 && cp <= 0x05FF) return TextScript.hebrew;
  if ((cp >= 0x0600 && cp <= 0x06FF) ||
      (cp >= 0x0750 && cp <= 0x077F) ||
      (cp >= 0x08A0 && cp <= 0x08FF) ||
      (cp >= 0xFB50 && cp <= 0xFDFF) ||
      (cp >= 0xFE70 && cp <= 0xFEFF)) {
    return TextScript.arabic;
  }
  if (cp >= 0x0900 && cp <= 0x097F) return TextScript.devanagari;
  if (cp >= 0x0980 && cp <= 0x09FF) return TextScript.bengali;
  if (cp >= 0x0B80 && cp <= 0x0BFF) return TextScript.tamil;
  if (cp >= 0x0E00 && cp <= 0x0E7F) return TextScript.thai;

  if (cp >= 0x3040 && cp <= 0x309F) return TextScript.hiragana;
  if (cp >= 0x30A0 && cp <= 0x30FF) return TextScript.katakana;
  if ((cp >= 0xAC00 && cp <= 0xD7A3) ||
      (cp >= 0x1100 && cp <= 0x11FF) ||
      (cp >= 0x3130 && cp <= 0x318F)) {
    return TextScript.hangul;
  }
  if ((cp >= 0x4E00 && cp <= 0x9FFF) ||
      (cp >= 0x3400 && cp <= 0x4DBF) ||
      (cp >= 0xF900 && cp <= 0xFAFF) ||
      (cp >= 0x20000 && cp <= 0x2A6DF)) {
    return TextScript.han;
  }

  return TextScript.unknown;
}

/// Bidirectional class of a code point (derived from its script).
BidiClass bidiClassOf(int cp) {
  final s = scriptOf(cp);
  if (isStrongRtlScript(s)) return BidiClass.rtl;
  if (s == TextScript.common || s == TextScript.unknown) return BidiClass.neutral;
  return BidiClass.ltr;
}
