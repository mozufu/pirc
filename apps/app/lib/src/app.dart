import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_render/pirc_render.dart';

import '../l10n/app_localizations.dart';
import 'connection/connection_screens.dart';
import 'connection/hints.dart';
import 'preferences.dart';
import 'render_bridge.dart';
import 'router.dart';

class PircApp extends ConsumerWidget {
  const PircApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Keeps the hint socket open while the app runs.
    ref.watch(hintsProvider);
    final textScale = ref.watch(textScaleProvider);
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      routerConfig: ref.watch(routerProvider),
      theme: appTheme(Brightness.light),
      darkTheme: appTheme(Brightness.dark),
      themeMode: ref.watch(themeModeProvider),
      locale: localeFor(ref.watch(languageProvider)),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        // The renderer's own strings follow the resolved locale.
        RenderL10n.language = languageOf(Localizations.localeOf(context));
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: textScale == 1.0
                ? media.textScaler
                : TextScaler.linear(media.textScaler.scale(1) * textScale),
          ),
          child: ConnectionFrame(child: child!),
        );
      },
    );
  }
}

/// Connects the renderer before the first frame.
void installRenderer() {
  RenderL10n.delegate = const AppRenderLocalizations();
  registerNativeRendererLicenses();
}
