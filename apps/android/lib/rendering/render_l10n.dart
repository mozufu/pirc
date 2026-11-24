import 'package:flutter/widgets.dart';

/// Translates the renderer's own interface text (control labels, errors).
///
/// The renderer has no catalog of its own: the host app supplies one through
/// [RenderL10n.delegate]. Parameters are substituted after lookup, so user and
/// model text is never translated.
abstract class RenderLocalizations {
  const RenderLocalizations();

  /// Returns [source] in the current language, with `{0}`, `{1}`, … replaced
  /// by [values].
  String translate(String source, List<Object?> values);

  /// Makes [context] rebuild when the language changes.
  void watch(BuildContext context) {}
}

/// English text with parameter substitution; used until a host installs a
/// catalog.
class EnglishRenderLocalizations extends RenderLocalizations {
  const EnglishRenderLocalizations();

  @override
  String translate(String source, List<Object?> values) =>
      substituteRenderParameters(source, values);
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
  /// The catalog in use. Hosts set this once at startup.
  static RenderLocalizations delegate = const EnglishRenderLocalizations();

  static void watch(BuildContext context) => delegate.watch(context);
}

/// Translates renderer interface text through [RenderL10n.delegate].
String tr(String source, [List<Object?> values = const []]) =>
    RenderL10n.delegate.translate(source, values);
