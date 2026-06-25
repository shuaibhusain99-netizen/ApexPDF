package com.ultimatepdf.ultimate_pdf

// Feature 1 — Annotations: native PDF persistence (device-only).
//
// Consumes the JSON produced by the Dart AnnotationCodec and writes real PDF
// annotation dictionaries with PdfBox-Android. Built at the COS level so it does
// not depend on version-specific PDAnnotation* helper classes. CANNOT be
// compiled or run in the build sandbox — verify the PdfBox-Android API names
// against the version you pin (tested shape: com.tom-roush:pdfbox-android:2.0.x).
//
// Coordinate note: our annotation world space is points measured y-DOWN from the
// page top (matching the rendered page); PDF user space is y-UP from the bottom.
// flipY() performs that conversion using the page MediaBox.

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.cos.COSArray
import com.tom_roush.pdfbox.cos.COSDictionary
import com.tom_roush.pdfbox.cos.COSFloat
import com.tom_roush.pdfbox.cos.COSName
import com.tom_roush.pdfbox.pdmodel.PDDocument
import com.tom_roush.pdfbox.pdmodel.PDPage
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

object AnnotationWriterPlugin {
    private const val CHANNEL = "ultimate_pdf/annotations"
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(engine: FlutterEngine, context: Context) {
        PDFBoxResourceLoader.init(context.applicationContext)
        MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "burnAnnotations" -> handleBurn(call.arguments, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun handleBurn(args: Any?, result: MethodChannel.Result) {
        // Heavy work off the platform thread; result must be posted on main.
        Thread {
            try {
                @Suppress("UNCHECKED_CAST")
                val map = args as? Map<String, Any?>
                    ?: throw IllegalArgumentException("invalid arguments")
                val src = map["src"] as? String
                    ?: throw IllegalArgumentException("missing src")
                val out = map["out"] as? String
                    ?: throw IllegalArgumentException("missing out")
                @Suppress("UNCHECKED_CAST")
                val annots = (map["annotations"] as? List<Map<String, Any?>>)
                    ?: emptyList()
                val written = burn(src, out, annots)
                mainHandler.post { result.success(written) }
            } catch (e: Throwable) {
                mainHandler.post {
                    result.error("annotation_write_failed", e.message, null)
                }
            }
        }.start()
    }

    private fun burn(src: String, out: String, annots: List<Map<String, Any?>>): String {
        val document = PDDocument.load(File(src))
        try {
            val byPage = HashMap<Int, MutableList<Map<String, Any?>>>()
            for (a in annots) {
                val page = (a["page"] as? Number)?.toInt() ?: 0
                byPage.getOrPut(page) { mutableListOf() }.add(a)
            }
            for ((pageIndex, list) in byPage) {
                if (pageIndex < 0 || pageIndex >= document.numberOfPages) continue
                val page = document.getPage(pageIndex)
                val annotArray = ensureAnnotArray(page)
                val height = page.mediaBox.height
                val originY = page.mediaBox.lowerLeftY
                for (a in list) {
                    buildAnnotation(a, height, originY)?.let { annotArray.add(it) }
                }
            }
            document.save(File(out))
            return out
        } finally {
            document.close()
        }
    }

    private fun ensureAnnotArray(page: PDPage): COSArray {
        val pageDict = page.cosObject
        var array = pageDict.getDictionaryObject(COSName.ANNOTS) as? COSArray
        if (array == null) {
            array = COSArray()
            pageDict.setItem(COSName.ANNOTS, array)
        }
        return array
    }

    private fun flipY(y: Double, height: Float, originY: Float): Float =
        (originY + height - y).toFloat()

    private fun buildAnnotation(
        a: Map<String, Any?>,
        height: Float,
        originY: Float,
    ): COSDictionary? {
        val kind = a["kind"] as? String ?: return null
        val argb = (a["color"] as? Number)?.toLong() ?: 0xFF000000L

        val dict = COSDictionary()
        dict.setName(COSName.TYPE, "Annot")
        setColor(dict, "C", argb)
        setOpacity(dict, argb)

        when (kind) {
            "ink" -> {
                @Suppress("UNCHECKED_CAST")
                val pts = a["points"] as? List<Number> ?: return null
                dict.setName(COSName.SUBTYPE, "Ink")
                val path = COSArray()
                var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE
                var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
                var i = 0
                while (i + 1 < pts.size) {
                    val x = pts[i].toFloat()
                    val y = flipY(pts[i + 1].toDouble(), height, originY)
                    path.add(COSFloat(x)); path.add(COSFloat(y))
                    minX = minOf(minX, x); maxX = maxOf(maxX, x)
                    minY = minOf(minY, y); maxY = maxOf(maxY, y)
                    i += 2
                }
                val inkList = COSArray().apply { add(path) }
                dict.setItem(COSName.getPDFName("InkList"), inkList)
                setBorderWidth(dict, (a["stroke"] as? Number)?.toFloat() ?: 1f)
                setRect(dict, minX, minY, maxX, maxY)
            }

            "highlight" -> {
                @Suppress("UNCHECKED_CAST")
                val rects = a["rects"] as? List<List<Number>> ?: return null
                dict.setName(COSName.SUBTYPE, "Highlight")
                val quad = COSArray()
                var minX = Float.MAX_VALUE; var minY = Float.MAX_VALUE
                var maxX = -Float.MAX_VALUE; var maxY = -Float.MAX_VALUE
                for (r in rects) {
                    val left = r[0].toFloat()
                    val right = r[2].toFloat()
                    val top = flipY(r[1].toDouble(), height, originY)
                    val bottom = flipY(r[3].toDouble(), height, originY)
                    // QuadPoints: (UL)(UR)(LL)(LR)
                    quad.add(COSFloat(left)); quad.add(COSFloat(top))
                    quad.add(COSFloat(right)); quad.add(COSFloat(top))
                    quad.add(COSFloat(left)); quad.add(COSFloat(bottom))
                    quad.add(COSFloat(right)); quad.add(COSFloat(bottom))
                    minX = minOf(minX, left); maxX = maxOf(maxX, right)
                    minY = minOf(minY, bottom); maxY = maxOf(maxY, top)
                }
                dict.setItem(COSName.getPDFName("QuadPoints"), quad)
                setRect(dict, minX, minY, maxX, maxY)
            }

            "rectangle", "ellipse" -> {
                @Suppress("UNCHECKED_CAST")
                val r = a["rect"] as? List<Number> ?: return null
                dict.setName(COSName.SUBTYPE, if (kind == "ellipse") "Circle" else "Square")
                val left = r[0].toFloat(); val right = r[2].toFloat()
                val top = flipY(r[1].toDouble(), height, originY)
                val bottom = flipY(r[3].toDouble(), height, originY)
                setRect(dict, left, minOf(top, bottom), right, maxOf(top, bottom))
                setBorderWidth(dict, (a["stroke"] as? Number)?.toFloat() ?: 1f)
                if (a["filled"] as? Boolean == true) setColor(dict, "IC", argb)
            }

            "line" -> {
                @Suppress("UNCHECKED_CAST")
                val p = a["p"] as? List<Number> ?: return null
                dict.setName(COSName.SUBTYPE, "Line")
                val x1 = p[0].toFloat(); val y1 = flipY(p[1].toDouble(), height, originY)
                val x2 = p[2].toFloat(); val y2 = flipY(p[3].toDouble(), height, originY)
                val l = COSArray()
                l.add(COSFloat(x1)); l.add(COSFloat(y1))
                l.add(COSFloat(x2)); l.add(COSFloat(y2))
                dict.setItem(COSName.getPDFName("L"), l)
                setBorderWidth(dict, (a["stroke"] as? Number)?.toFloat() ?: 1f)
                setRect(dict, minOf(x1, x2), minOf(y1, y2), maxOf(x1, x2), maxOf(y1, y2))
            }

            "note" -> {
                val x = (a["x"] as? Number)?.toDouble() ?: return null
                val y = (a["y"] as? Number)?.toDouble() ?: return null
                val fy = flipY(y, height, originY)
                dict.setName(COSName.SUBTYPE, "Text")
                dict.setName(COSName.getPDFName("Name"), "Note")
                dict.setString(COSName.CONTENTS, a["text"] as? String ?: "")
                val size = 18f
                setRect(dict, x.toFloat(), fy - size, x.toFloat() + size, fy)
            }

            else -> return null
        }
        return dict
    }

    private fun setRect(d: COSDictionary, x1: Float, y1: Float, x2: Float, y2: Float) {
        val rect = COSArray()
        rect.add(COSFloat(x1)); rect.add(COSFloat(y1))
        rect.add(COSFloat(x2)); rect.add(COSFloat(y2))
        d.setItem(COSName.RECT, rect)
    }

    private fun setColor(d: COSDictionary, key: String, argb: Long) {
        val r = ((argb shr 16) and 0xFF).toFloat() / 255f
        val g = ((argb shr 8) and 0xFF).toFloat() / 255f
        val b = (argb and 0xFF).toFloat() / 255f
        val c = COSArray()
        c.add(COSFloat(r)); c.add(COSFloat(g)); c.add(COSFloat(b))
        d.setItem(COSName.getPDFName(key), c)
    }

    private fun setOpacity(d: COSDictionary, argb: Long) {
        val alpha = ((argb shr 24) and 0xFF).toFloat() / 255f
        if (alpha < 1f) d.setItem(COSName.getPDFName("CA"), COSFloat(alpha))
    }

    private fun setBorderWidth(d: COSDictionary, width: Float) {
        val bs = COSDictionary()
        bs.setItem(COSName.getPDFName("W"), COSFloat(width))
        d.setItem(COSName.getPDFName("BS"), bs)
    }
}
