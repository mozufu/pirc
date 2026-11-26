import 'package:flutter/material.dart';

import '../theme.dart';

/// The E sheets' buttons (`c-btn`): 44 high, pill shaped, 15/500.
ButtonStyle _base(BuildContext context, Color background, Color foreground) =>
    FilledButton.styleFrom(
      backgroundColor: background,
      foregroundColor: foreground,
      disabledBackgroundColor: background.withValues(alpha: background.a * 0.5),
      disabledForegroundColor: foreground.withValues(alpha: 0.5),
      minimumSize: const Size(0, 44),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      shape: const StadiumBorder(),
      textStyle: _label(context),
    );

/// The theme's label type (its font) at 15/500.
TextStyle? _label(BuildContext context) => Theme.of(
  context,
).textTheme.labelLarge?.copyWith(fontSize: 15, fontWeight: FontWeight.w500);

/// `c-btn.dark`: the ink fill, for the one main action of a sheet.
ButtonStyle inkButtonStyle(BuildContext context) {
  final colors = PircColorTokens.of(context);
  return _base(context, colors['action.primary'], colors['action.onPrimary']);
}

/// `c-btn`: the hover fill with ink text.
ButtonStyle plainButtonStyle(BuildContext context) {
  final colors = PircColorTokens.of(context);
  return _base(context, colors['fill.hover'], colors['text.primary']);
}

/// `c-btn.ghost`: no fill, a 1 line inside, ink text.
ButtonStyle ghostButtonStyle(BuildContext context) {
  final colors = PircColorTokens.of(context);
  return OutlinedButton.styleFrom(
    foregroundColor: colors['text.primary'],
    side: BorderSide(color: colors['line.strong']),
    minimumSize: const Size(0, 44),
    padding: const EdgeInsets.symmetric(horizontal: 18),
    shape: const StadiumBorder(),
    textStyle: _label(context),
  );
}
