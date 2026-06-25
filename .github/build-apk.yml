name: Build Android APK

# Push to main/master, open a PR, or run manually from the Actions tab.
# The job uploads installable APK artifacts you download from the run summary.
on:
  push:
    branches: [main, master]
  pull_request:
  workflow_dispatch:

jobs:
  build-apk:
    runs-on: ubuntu-latest
    timeout-minutes: 40

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      # JDK 17 is what the Android Gradle Plugin shipped by stable Flutter expects.
      - name: Set up JDK 17
        uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: "17"

      # Installs the Flutter SDK (and its Dart). The Android SDK is already
      # present on ubuntu-latest runners. cache: true speeds up reruns.
      - name: Set up Flutter (stable)
        uses: subosito/flutter-action@v2
        with:
          channel: stable
          cache: true

      - name: Toolchain versions
        run: |
          flutter --version
          java -version

      # The android/ project is intentionally NOT committed (see BUILDING.md):
      # we generate it here so its Gradle/AGP/Kotlin versions match THIS runner's
      # Flutter SDK exactly. flutter create can overwrite tracked root files, so
      # we restore them afterwards. It never overwrites an existing lib/.
      - name: Generate the Android project
        run: |
          flutter create . \
            --platforms=android \
            --org com.ultimatepdf \
            --project-name ultimate_pdf
          git checkout -- pubspec.yaml analysis_options.yaml README.md .gitignore 2>/dev/null || true

      # Re-apply our only native customizations: the PDFBox annotation writer and
      # its registration in MainActivity, plus the PDFBox-Android dependency.
      - name: Inject native annotation writer (PDFBox)
        run: |
          set -e
          PKG_DIR="android/app/src/main/kotlin/com/ultimatepdf/ultimate_pdf"
          mkdir -p "$PKG_DIR"
          cp native/MainActivity.kt "$PKG_DIR/MainActivity.kt"
          cp native/AnnotationWriterPlugin.kt "$PKG_DIR/AnnotationWriterPlugin.kt"
          GRADLE="android/app/build.gradle.kts"
          if ! grep -q "pdfbox-android" "$GRADLE"; then
            cat >> "$GRADLE" <<'GR'

// Native PDF write path for annotations (injected by CI). Apache-2.0.
dependencies {
    implementation("com.tom-roush:pdfbox-android:2.0.27.0")
}
GR
          fi
          echo "Injected native plugin + PDFBox dependency."

      - name: Resolve dependencies
        run: flutter pub get

      # Non-blocking so an APK is still produced and any warning is readable.
      - name: Analyze (non-blocking)
        run: flutter analyze || true

      - name: Test (non-blocking)
        run: flutter test || true

      # Debug APK is debug-signed => directly installable (enable "install
      # unknown apps" on the device). This is the artifact to grab.
      - name: Build debug APK
        run: flutter build apk --debug

      # Release APK is UNSIGNED here; sign it before install (see BUILDING.md).
      - name: Build release APK (unsigned)
        run: flutter build apk --release || true

      - name: Upload APKs
        uses: actions/upload-artifact@v4
        with:
          name: ultimate-pdf-apk
          path: |
            build/app/outputs/flutter-apk/app-debug.apk
            build/app/outputs/flutter-apk/app-release.apk
          if-no-files-found: warn
          retention-days: 14
