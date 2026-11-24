import 'package:flutter/widgets.dart';

import 'l10n/catalogs.g.dart';

/// Translates the renderer's own interface text (control labels, errors).
///
/// The renderer ships an English and a Traditional Chinese catalog for its own
/// strings (`lib/src/l10n/*.json`). A host either sets [RenderL10n.language]
/// or installs its own delegate through [RenderL10n.delegate]. Parameters are
/// substituted after lookup, so user and model text is never translated.
abstract class RenderLocalizations {
  const RenderLocalizations();

  /// Returns [source] in the current language, with `{0}`, `{1}`, … replaced
  /// by [values].
  String translate(String source, List<Object?> values);

  /// Makes [context] rebuild when the language changes.
  void watch(BuildContext context) {}
}

/// The renderer's own catalogs, in [RenderL10n.language].
class CatalogRenderLocalizations extends RenderLocalizations {
  const CatalogRenderLocalizations();

  @override
  String translate(String source, List<Object?> values) {
    final translated = RenderL10n.language == 'zh-TW'
        ? renderTraditionalChineseMessages[source]
        : null;
    return substituteRenderParameters(
      translated ?? renderEnglishMessages[source] ?? source,
      values,
    );
  }
}

/// Replaces `{n}` placeholders; unknown indexes stay as written.
String substituteRenderParameters(String template, List<Object?> values) =>
    template.replaceAllMapped(RegExp(r'\{(\d+)\}'), (match) {
      final index = int.tryParse(match[1]!);
      return index != null && index < values.length
          ? '${values[index] ?? ''}'
          : match[0]!;
    });

abstract final class RenderL10n {
  /// `en` or `zh-TW`; read by [CatalogRenderLocalizations].
  static String language = 'en';

  /// The catalog in use. Hosts may replace it once at startup.
  static RenderLocalizations delegate = const CatalogRenderLocalizations();

  static void watch(BuildContext context) => delegate.watch(context);
}

/// Translates renderer interface text through [RenderL10n.delegate].
String tr(String source, [List<Object?> values = const []]) =>
    RenderL10n.delegate.translate(source, values);
