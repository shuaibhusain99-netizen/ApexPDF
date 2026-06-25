package com.ultimatepdf.ultimate_pdf

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Register the native annotation writer (Feature 1 PDF persistence).
        AnnotationWriterPlugin.register(flutterEngine, applicationContext)
    }
}
