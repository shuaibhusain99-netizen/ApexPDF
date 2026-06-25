# Building Ultimate PDF → an installable APK

This repository ships the **Dart application** (`lib/`, `pubspec.yaml`, `test/`)
and a small set of **native customizations** (`native/`). The Android Gradle
project under `android/` is **generated at build time** so its Gradle / AGP /
Kotlin toolchain always matches the Flutter SDK on the building machine — this
avoids version-mismatch failures. `android/` is therefore git-ignored.

The only native code we own:

| File | Purpose |
|------|---------|
| `native/MainActivity.kt` | Registers the annotation writer on the Flutter engine. |
| `native/AnnotationWriterPlugin.kt` | Writes real PDF annotation dictionaries with PDFBox-Android (COS-level). |

Both are copied into the generated project, and the
`com.tom-roush:pdfbox-android:2.0.27.0` dependency is appended, during every
build (by CI and by `build_apk.sh`).

---

## Option A — GitHub Actions (recommended, no local setup)

1. Push this repo to GitHub (make sure `native/`, `lib/`, `pubspec.yaml`, and
   `.github/workflows/build-apk.yml` are committed; `android/` is intentionally
   **not** committed).
   - If you previously committed `android/`, untrack it once:
     `git rm -r --cached android && git commit -m "stop tracking generated android/"`.
2. Open the **Actions** tab → run **Build Android APK** (it also runs on every
   push to `main`/`master`). The runner uses **JDK 17 + stable Flutter** and has
   ample RAM.
3. When the run finishes, download the **`ultimate-pdf-apk`** artifact from the
   run summary. It contains:
   - `app-debug.apk` — **debug-signed, installable immediately**.
   - `app-release.apk` — **unsigned** (see *Signed release* below).
4. On the phone, enable *Install unknown apps* for your file manager, then open
   `app-debug.apk`.

## Option B — Local build

Prerequisites (verify with `flutter doctor -v`):

- Flutter SDK (stable) on `PATH`
- Android SDK: a platform, build-tools, and the NDK (`flutter doctor` installs them)
- **A full JDK 17 with `javac`** — a JRE is not enough. Check: `javac -version`.
  (Point `JAVA_HOME` at the JDK if the wrong Java is picked up.)

Then:

```bash
./build_apk.sh
# installable APK at build/app/outputs/flutter-apk/app-debug.apk
adb install -r build/app/outputs/flutter-apk/app-debug.apk
```

---

## Signed release APK (for distribution)

The release APK from CI is unsigned. To produce a signed one:

1. Create a keystore (once):
   ```bash
   keytool -genkey -v -keystore upload.jks -keyalg RSA -keysize 2048 \
     -validity 10000 -alias upload
   ```
2. Add a signing config to the generated `android/app/build.gradle.kts` (or wire
   it through CI repository secrets and `key.properties`), then:
   ```bash
   flutter build apk --release
   ```
   See the Flutter docs: *Build and release an Android app*.

---

## Notes / known constraints

- **Why `android/` is generated, not committed:** a bleeding-edge (Flutter
  *master*) Android project pins AGP 9 / Gradle 9, which a *stable*-Flutter CI
  runner can't build, and vice-versa. Generating the project on the build
  machine sidesteps the mismatch entirely.
- **16 KB page size (Android 15+):** the native `.so` files come from `pdfrx`
  (PDFium) and `pdfbox-android`. Confirm 16 KB-aligned builds for those packages
  if you target devices with 16 KB pages.
- **What is verified vs device-only:** the pure-Dart engine and feature cores are
  unit-tested (190 tests). PDF rendering (pdfrx/PDFium) and native annotation
  writing (PDFBox) are correct-by-construction but exercised only on a device.
