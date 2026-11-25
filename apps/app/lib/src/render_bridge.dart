import 'package:flutter/material.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_ui/pirc_ui.dart';

/// Renderer color names that the design tokens call differently.
const _renderAliases = {
  'border.default': 'line.default',
  'code.head': 'text.muted',
  'web.bg': 'surface.page',
  'web.line': 'line.hairline',
  'web.muted': 'text.muted',
};

/// The renderer's colors for [brightness], from the design tokens.
RenderColors renderColors(Brightness brightness) {
  final colors = PircTheme.colors(brightness);
  return RenderColors({
    ...colors,
    for (final MapEntry(:key, :value) in _renderAliases.entries)
      key: colors[value]!,
  });
}

final _themes = <Brightness, ThemeData>{};

/// The app theme: design tokens plus the renderer's color extension.
ThemeData appTheme(Brightness brightness) =>
    _themes.putIfAbsent(brightness, () {
      final base = PircTheme.of(brightness);
      return base.copyWith(
        extensions: [...base.extensions.values, renderColors(brightness)],
      );
    });

/// Keeps the renderer's language in step with the app's locale.
class AppRenderLocalizations extends CatalogRenderLocalizations {
  const AppRenderLocalizations();

  @override
  void watch(BuildContext context) => Localizations.localeOf(context);
}
