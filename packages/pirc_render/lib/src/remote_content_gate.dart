import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'render_l10n.dart';
import 'render_theme.dart';

/// Whether remote images and media in a subtree load only after the user taps.
///
/// Chat messages, file previews, tool output and documents served by the
/// paired Gateway are untrusted content: a remote reference there must not
/// reach the network by merely being displayed. The default, with no policy in
/// scope, is therefore to hold remote content back. The one subtree that opts
/// out is a document the user navigated to on another origin, which is a page
/// of its own and runs under its own origin.
class NativeRemoteContentPolicy extends InheritedWidget {
  const NativeRemoteContentPolicy({
    super.key,
    required this.loadOnActivation,
    required super.child,
  });

  final bool loadOnActivation;

  static bool _openForTests = false;

  /// Test seam for suites that exercise the image and media loaders
  /// themselves. Only honored while assertions are enabled, so it cannot
  /// loosen the hold-back in a release build.
  static set debugOpenForTests(bool value) {
    assert(() {
      _openForTests = value;
      return true;
    }());
  }

  /// True when remote content under [context] must wait for the user.
  static bool holdsRemoteContent(BuildContext context) {
    final policy = context
        .dependOnInheritedWidgetOfExactType<NativeRemoteContentPolicy>();
    if (policy != null) return policy.loadOnActivation;
    return !_openForTests;
  }

  @override
  bool updateShouldNotify(NativeRemoteContentPolicy old) =>
      old.loadOnActivation != loadOnActivation;
}

/// A reference that would need the network: anything that is not inline
/// (`data:`) or a local object URL (`blob:`). No part of the URL's shape, path
/// or host earns an exemption.
bool nativeRemoteContentSource(Uri uri) =>
    uri.scheme != 'data' && uri.scheme != 'blob';

enum NativeRemoteContentKind { image, media }

/// Shows [builder] only once the user activated the placeholder, when the
/// policy in scope holds remote content back.
///
/// The placeholder is a Flutter widget owned by the app. Document script,
/// markup, attributes, CSS and bridge arguments have no way to activate it;
/// only a pointer or accessibility action on this widget does. Nothing is
/// requested for the source before that: the builder (which starts the load)
/// is not even called.
class NativeRemoteContentGate extends StatefulWidget {
  const NativeRemoteContentGate({
    super.key,
    required this.source,
    required this.builder,
    this.alt,
    this.kind = NativeRemoteContentKind.image,
  });

  /// The reference as written in the content, resolved or not.
  final String source;
  final String? alt;
  final NativeRemoteContentKind kind;
  final WidgetBuilder builder;

  @override
  State<NativeRemoteContentGate> createState() =>
      _NativeRemoteContentGateState();
}

class _NativeRemoteContentGateState extends State<NativeRemoteContentGate> {
  bool _activated = false;

  @override
  void didUpdateWidget(covariant NativeRemoteContentGate old) {
    super.didUpdateWidget(old);
    // A different source is different content and needs its own activation.
    if (old.source != widget.source) _activated = false;
  }

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    if (_activated || !NativeRemoteContentPolicy.holdsRemoteContent(context)) {
      return widget.builder(context);
    }
    return NativeRemoteContentPlaceholder(
      source: widget.source,
      alt: widget.alt,
      kind: widget.kind,
      onActivate: () => setState(() => _activated = true),
    );
  }
}

/// Where a remote reference points, as shown to the user before it is fetched.
({String where, String detail}) nativeRemoteContentOrigin(String source) {
  final uri = Uri.tryParse(source.trim());
  if (uri != null && uri.hasAuthority && uri.host.isNotEmpty) {
    final port = uri.hasPort ? ':${uri.port}' : '';
    return (where: '${uri.host}$port', detail: source.trim());
  }
  return (where: tr("this server"), detail: source.trim());
}

/// The inert stand-in for a remote image or media element.
class NativeRemoteContentPlaceholder extends StatelessWidget {
  const NativeRemoteContentPlaceholder({
    super.key,
    required this.source,
    required this.onActivate,
    this.alt,
    this.kind = NativeRemoteContentKind.image,
  });

  final String source;
  final String? alt;
  final NativeRemoteContentKind kind;
  final VoidCallback onActivate;

  @override
  Widget build(BuildContext context) {
    RenderL10n.watch(context);
    final theme = Theme.of(context);
    final colors = theme.extension<RenderColors>();
    Color token(String name, Color fallback) =>
        colors?.values[name] ?? fallback;
    final primary = token('text.primary', theme.colorScheme.onSurface);
    final secondary = token(
      'text.secondary',
      theme.colorScheme.onSurfaceVariant,
    );
    final border = token('border.default', theme.dividerColor);
    final origin = nativeRemoteContentOrigin(source);
    final label = kind == NativeRemoteContentKind.image
        ? tr("Remote image from {0}", [origin.where])
        : tr("Remote media from {0}", [origin.where]);
    final description = (alt ?? '').trim();
    final detail = origin.detail.length > 120
        ? '${origin.detail.substring(0, 117)}...'
        : origin.detail;
    return Semantics(
      button: true,
      label: [if (description.isNotEmpty) description, label].join('. '),
      hint: tr("Tap to load"),
      onTap: onActivate,
      excludeSemantics: true,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420, minHeight: 48),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            key: const ValueKey('remote-content-placeholder'),
            borderRadius: BorderRadius.circular(8),
            onTap: onActivate,
            child: Ink(
              decoration: BoxDecoration(
                border: Border.all(color: border),
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      kind == NativeRemoteContentKind.image
                          ? LucideIcons.image
                          : LucideIcons.circlePlay,
                      size: 18,
                      color: secondary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (description.isNotEmpty)
                          Text(
                            description,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 14, color: primary),
                          ),
                        Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                            color: primary,
                          ),
                        ),
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: secondary),
                        ),
                        Text(
                          tr("Tap to load"),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: theme.colorScheme.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The in-line image builder used when a Markdown surface is given none: the
/// same hold-back applies, and nothing here can be configured by content.
Widget nativeHeldMarkdownImage(Uri uri, String? title, String? alt) {
  if (!nativeRemoteContentSource(uri)) {
    final data = uri.scheme == 'data' ? uri.data : null;
    if (data != null && data.mimeType.startsWith('image/')) {
      return Image.memory(
        data.contentAsBytes(),
        semanticLabel: alt,
        errorBuilder: (_, _, _) => Text(alt ?? ''),
      );
    }
    return Text(alt ?? '');
  }
  if (uri.scheme != '' && uri.scheme != 'http' && uri.scheme != 'https') {
    return Text(alt ?? '');
  }
  return NativeRemoteContentGate(
    source: uri.toString(),
    alt: alt,
    builder: (_) => Image.network(
      uri.toString(),
      semanticLabel: alt,
      errorBuilder: (_, _, _) => Text(alt ?? ''),
    ),
  );
}
