// main.dart

import 'package:flutter/widgets.dart';

import 'app.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // pdfrx (1.3.x) initializes its PDFium backend lazily on first document use,
  // so no explicit init call is required here.
  runApp(const UltimatePdfApp());
}
