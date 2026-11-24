import 'package:flutter/material.dart';

/// Semantic colors the renderer reads, keyed by design-token name
/// (`accent.default`, `text.primary`, `code.*`, `terminal.*`, …).
///
/// Hosts add one instance to `ThemeData.extensions`; see
/// `docs/design/tokens.json` for the names.
class RenderColors extends ThemeExtension<RenderColors> {
  const RenderColors(this.values);
  final Map<String, Color> values;
  Color operator [](String key) => values[key]!;
  @override
  RenderColors copyWith({Map<String, Color>? values}) =>
      RenderColors(values ?? this.values);
  @override
  RenderColors lerp(covariant RenderColors? other, double t) => other == null
      ? this
      : RenderColors({
          for (final key in values.keys)
            key: Color.lerp(values[key], other.values[key], t)!,
        });
}
