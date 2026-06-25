// app.dart
//
// Application shell: theme + multilingual / RTL scaffolding.
//
// This provides correct UI direction and localized Material/Cupertino widgets
// for LTR and RTL locales. NOTE: this governs the APP UI only. Rendering PDFs
// that embed complex scripts without subsetted fonts requires a PDFium font
// fallback step (see README "Completion map") and is separate from this.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'viewer/viewer_screen.dart';
import 'theme/app_theme.dart';

class UltimatePdfApp extends StatelessWidget {
  const UltimatePdfApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Ultimate PDF',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: ThemeMode.system,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'), // English
        Locale('ar'), // Arabic (RTL)
        Locale('fa'), // Persian (RTL)
        Locale('ur'), // Urdu (RTL)
        Locale('he'), // Hebrew (RTL)
        Locale('zh'), // Chinese
        Locale('ja'), // Japanese
        Locale('ko'), // Korean
        Locale('hi'), // Hindi
        Locale('bn'), // Bengali
        Locale('ta'), // Tamil
        Locale('th'), // Thai
        Locale('ru'),
        Locale('es'),
        Locale('fr'),
        Locale('de'),
      ],
      // Directionality (LTR/RTL) is derived automatically from the active locale
      // by the Localizations/Directionality machinery.
      home: const ViewerScreen(),
    );
  }
}
