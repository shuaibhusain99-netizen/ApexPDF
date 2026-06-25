#!/usr/bin/env bash
# build_apk.sh — produce an installable Ultimate PDF debug APK locally.
#
# Prerequisites (one-time):
#   * Flutter SDK (stable) on PATH
#   * Android SDK (platform + build-tools + NDK; `flutter doctor` will guide)
#   * A full JDK 17 with javac (NOT a JRE).  Verify:  javac -version
# Sanity check the whole toolchain with:  flutter doctor -v
#
# Usage:  ./build_apk.sh
set -euo pipefail

ORG="com.ultimatepdf"
NAME="ultimate_pdf"
PKG_DIR="android/app/src/main/kotlin/com/ultimatepdf/ultimate_pdf"
GRADLE="android/app/build.gradle.kts"

echo "==> Generating the Android project (matches your Flutter toolchain)"
if [ ! -d android ]; then
  flutter create . --platforms=android --org "$ORG" --project-name "$NAME"
  # flutter create can overwrite tracked root files; restore them if under git.
  git checkout -- pubspec.yaml analysis_options.yaml README.md .gitignore 2>/dev/null || true
fi

echo "==> Injecting native annotation writer (PDFBox) from native/"
mkdir -p "$PKG_DIR"
cp native/MainActivity.kt "$PKG_DIR/MainActivity.kt"
cp native/AnnotationWriterPlugin.kt "$PKG_DIR/AnnotationWriterPlugin.kt"
if ! grep -q "pdfbox-android" "$GRADLE"; then
  cat >> "$GRADLE" <<'GR'

// Native PDF write path for annotations (injected by build_apk.sh). Apache-2.0.
dependencies {
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
}
GR
fi

echo "==> Resolving dependencies"
flutter pub get

echo "==> Analyzing (non-blocking)"
flutter analyze || true

echo "==> Building debug APK (debug-signed, installable)"
flutter build apk --debug

APK="build/app/outputs/flutter-apk/app-debug.apk"
echo
echo "==> Done."
echo "    APK: ${APK}"
echo "    Install on a connected device with:"
echo "      adb install -r ${APK}"
