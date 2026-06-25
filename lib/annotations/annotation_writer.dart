// annotation_writer.dart
//
// Feature 1 — Annotations (PDF persistence, Dart side of the platform channel).
//
// Serializes annotations with the (tested) AnnotationCodec and hands them to the
// native writer, which embeds them as real PDF annotation dictionaries using
// PdfBox-Android. The Dart side here is analyzer-verifiable; the native handler
// (AnnotationWriterPlugin.kt) runs only on a device.

import 'package:flutter/services.dart';

import 'annotation_model.dart';
import 'annotation_store.dart';
import 'annotation_serialization.dart';

/// Thrown when the native writer reports a failure.
class AnnotationWriteException implements Exception {
  final String message;
  final Object? cause;
  AnnotationWriteException(this.message, [this.cause]);
  @override
  String toString() => 'AnnotationWriteException: $message';
}

abstract final class PdfAnnotationWriter {
  static const MethodChannel _channel =
      MethodChannel('ultimate_pdf/annotations');

  /// Burns [annotations] into the PDF at [srcPath], writing the result to
  /// [outPath]. Returns [outPath] on success. Each annotation's pageIndex routes
  /// it to the correct page natively.
  static Future<String> burn({
    required String srcPath,
    required String outPath,
    required Iterable<Annotation> annotations,
  }) async {
    if (srcPath.isEmpty || outPath.isEmpty) {
      throw AnnotationWriteException('source and output paths are required');
    }
    final payload = <String, Object?>{
      'src': srcPath,
      'out': outPath,
      'annotations': AnnotationCodec.encodeAll(annotations),
    };
    try {
      final result =
          await _channel.invokeMethod<String>('burnAnnotations', payload);
      if (result == null) {
        throw AnnotationWriteException('native writer returned no path');
      }
      return result;
    } on PlatformException catch (e) {
      throw AnnotationWriteException(
          e.message ?? 'native write failed', e);
    } on MissingPluginException catch (e) {
      throw AnnotationWriteException(
          'annotation writer plugin is not registered on this platform', e);
    }
  }

  /// Convenience: burns the union of several per-page stores in one call.
  static Future<String> burnStores({
    required String srcPath,
    required String outPath,
    required Iterable<AnnotationStore> stores,
  }) {
    final all = <Annotation>[
      for (final s in stores) ...s.all,
    ];
    return burn(srcPath: srcPath, outPath: outPath, annotations: all);
  }
}
