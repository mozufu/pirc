import '../l10n/app_i18n.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:pirc_render/src/native_markdown.dart';
import 'package:pirc_render/src/file_links.dart';
import '../theme.dart';
import 'gateway.dart';
import 'web_controls.dart';
import 'markdown_image.dart';
import 'document_navigation.dart';
import 'document_navigation_state.dart';
import 'html_media.dart';
import 'package:pirc_render/src/native_html.dart' show NativeHtmlLink;

PircColors palette(BuildContext context) =>
    Theme.of(context).extension<PircColors>()!;
List<BoxShadow> pircShadow(BuildContext context, {bool card = false}) {
  final colors = palette(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  // app.css --shadow-soft (cards) / --shadow-pop (floating surfaces).
  return [
    BoxShadow(
      color: colors[card || dark ? 'line.default' : 'line.hairline'],
      spreadRadius: 1,
    ),
    BoxShadow(
      color: (dark ? Colors.black : colors['text.primary']).withValues(
        alpha: dark ? (card ? .30 : .45) : (card ? .06 : .12),
      ),
      blurRadius: card ? 20 : 40,
      offset: Offset(0, card ? 4 : 12),
    ),
  ];
}

Future<void> guarded(
  BuildContext context,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    if (context.mounted) {
      showNotice(context, LiveController.describe(e));
    }
  }
}

void showNotice(BuildContext context, String message) {
  final messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: _AppNotice(message),
      behavior: SnackBarBehavior.floating,
      backgroundColor: Colors.transparent,
      elevation: 0,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      padding: EdgeInsets.zero,
      duration: const Duration(seconds: 5),
    ),
  );
}

/// Native-only feedback shares the pinned Web floating-surface palette. Keep
/// long errors readable when the keyboard or rotation reduces available space.
class _AppNotice extends StatelessWidget {
  const _AppNotice(this.message);
  final String message;

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    final media = MediaQuery.of(context);
    final available =
        media.size.height -
        media.viewInsets.bottom -
        media.viewPadding.vertical;
    final textHeight = math.max(0.0, math.min(280.0, (available - 56) / 2));
    final colors = palette(context);
    return Container(
      key: const ValueKey('app-notice'),
      decoration: BoxDecoration(
        color: colors['web.bg-layer'],
        borderRadius: BorderRadius.circular(12),
        boxShadow: pircShadow(context, card: true),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: textHeight),
              child: SingleChildScrollView(
                key: const ValueKey('app-notice-scroll'),
                child: Text(message, style: webText(context, size: 14)),
              ),
            ),
          ),
          const SizedBox(width: 8),
          WebIconButton(
            LucideIcons.x,
            tr("Dismiss notification"),
            size: 32,
            onPressed: () =>
                ScaffoldMessenger.of(context).hideCurrentSnackBar(),
          ),
        ],
      ),
    );
  }
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '確認',
  String cancelLabel = '取消',
}) async =>
    await showDialog<bool>(
      context: context,
      useRootNavigator: false,
      builder: (context) => WebDialog(
        title: title,
        actions: [
          WebButton(
            cancelLabel,
            onPressed: () => Navigator.pop(context, false),
          ),
          WebButton(
            action,
            primary: true,
            onPressed: () => Navigator.pop(context, true),
          ),
        ],
        children: [Text(body)],
      ),
    ) ??
    false;
Future<String?> input(
  BuildContext context,
  String title, {
  String value = '',
  int lines = 1,
}) async {
  final field = TextEditingController(text: value);
  final result = await showDialog<String>(
    context: context,
    useRootNavigator: false,
    builder: (context) => WebDialog(
      title: title,
      actions: [
        WebButton(tr("取消"), onPressed: () => Navigator.pop(context)),
        WebButton(
          tr("確認"),
          primary: true,
          onPressed: () => Navigator.pop(context, field.text),
        ),
      ],
      children: [
        Semantics(
          label: title,
          child: TextField(
            controller: field,
            autofocus: true,
            minLines: lines,
            maxLines: lines == 1 ? 1 : 8,
            style: webText(context, size: 16),
            decoration: InputDecoration(
              filled: true,
              fillColor: palette(context)['web.bg-subtle'],
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 10,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: palette(context)['accent.default'],
                ),
              ),
            ),
          ),
        ),
      ],
    ),
  );
  // Dialog route disposes its text field after the reverse transition.
  Future<void>.delayed(const Duration(milliseconds: 400), field.dispose);
  return result;
}

class Surface extends StatelessWidget {
  const Surface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.layer = false,
  });
  final Widget child;
  final EdgeInsets padding;
  final bool layer;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Material(
      color: palette(context)[layer ? 'surface.layer' : 'surface.subtle'],
      borderRadius: BorderRadius.circular(16),
      clipBehavior: Clip.antiAlias,
      child: Padding(padding: padding, child: child),
    );
  }
}

class RichTextBody extends StatelessWidget {
  const RichTextBody(
    this.text, {
    super.key,
    required this.gateway,
    this.onFile,
    this.reader = false,
    this.compact = false,
    this.streaming = false,
    this.fontSize,
    this.textColor,
    this.linkBase = '',
  });
  final String linkBase;
  final String text;
  final Gateway gateway;
  final void Function(String)? onFile;
  final bool reader, compact, streaming;
  final double? fontSize;
  final Color? textColor;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    void openLink(String href) {
      final target = parseFileTarget(href, base: linkBase);
      if (target != null) {
        onFile?.call(target.href);
        return;
      }
      final uri = Uri.tryParse(href);
      if (uri != null && ['https', 'http', 'mailto'].contains(uri.scheme)) {
        guarded(
          context,
          () => gateway.call('external', {'url': href}).then((_) {}),
        );
      }
    }

    final scope = NativeDocumentScope.maybeOf(context);
    void navigateHtml(NativeHtmlLink link) {
      guarded(context, () async {
        if (!await saveNativeDocumentLink(
              context,
              gateway,
              link,
              scope: scope,
            ) &&
            context.mounted) {
          openLink(link.href);
        }
      });
    }

    return NativeDocumentSubmissionHost(
      gateway: gateway,
      builder: (onSubmit) => NativeMarkdown(
        onFormSubmit: onSubmit,
        source: text,
        streaming: streaming,
        compact: compact,
        fontSize: reader ? 16.5 : fontSize ?? (compact ? 14 : null),
        textColor: textColor,
        lineHeight: reader
            ? 29 / 16.5
            : compact
            ? 1.6
            : null,
        onLink: openLink,
        onHtmlNavigate: navigateHtml,
        mediaBuilder: (spec, styles) => NativeHtmlMedia(
          gateway: gateway,
          spec: spec,
          styles: styles,
          scope: scope,
          accountIdentity: scope?.accountIdentity,
          baseUrl: scope?.window?.currentDocument?.url == scope?.documentUrl
              ? scope?.window?.currentDocument?.effectiveBase ??
                    scope?.documentUrl
              : scope?.documentUrl,
        ),
        imageBuilder: (uri, title, alt) => NativeMarkdownImage(
          gateway: gateway,
          source: uri,
          title: title,
          alt: alt,
        ),
      ),
    );
  }
}

Widget inlineImages(List<Json> images) => Wrap(
  spacing: 8,
  runSpacing: 8,
  children: [
    for (final image in images)
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 300),
        child: Builder(
          builder: (context) {
            try {
              return Image.memory(
                base64Decode('${image['base64']}'),
                errorBuilder: (_, e, s) => Text(tr("圖片無法顯示")),
              );
            } catch (_) {
              return Text(tr("圖片無法顯示"));
            }
          },
        ),
      ),
  ],
);

class RemotePage extends StatefulWidget {
  const RemotePage({super.key, required this.load, required this.builder});
  final Future<Json> Function() load;
  final Widget Function(BuildContext, Json, VoidCallback) builder;
  @override
  State<RemotePage> createState() => _RemotePageState();
}

class _RemotePageState extends State<RemotePage> {
  late Future<Json> future = widget.load();
  void reload() => setState(() => future = widget.load());
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return FutureBuilder<Json>(
      future: future,
      builder: (context, s) {
        if (s.hasError) {
          return SupportingState(
            title: tr("暫時無法載入"),
            detail: LiveController.describe(s.error!),
            onRetry: reload,
          );
        }
        if (!s.hasData) return const SupportingLoading();
        return widget.builder(context, s.data!, reload);
      },
    );
  }
}

/// Final submission actions use ink; navigation and setup use the accent.
class FinalButton extends StatelessWidget {
  const FinalButton({super.key, required this.onPressed, required this.child});
  final VoidCallback? onPressed;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return FilledButton(
      onPressed: onPressed,
      style: FilledButton.styleFrom(
        backgroundColor: palette(context)['action.primary'],
        foregroundColor: palette(context)['action.onPrimary'],
      ),
      child: child,
    );
  }
}

/// Shared treatment for supporting screens absent from the visual prototypes.
InputDecoration supportingField(
  BuildContext context, {
  String? label,
  String? hint,
}) => InputDecoration(
  labelText: label,
  hintText: hint,
  filled: true,
  fillColor: palette(context)['surface.subtle'],
  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
  border: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide.none,
  ),
  enabledBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide.none,
  ),
  focusedBorder: OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: palette(context)['accent.default']),
  ),
);

class SupportingState extends StatelessWidget {
  const SupportingState({
    super.key,
    required this.title,
    required this.detail,
    this.onRetry,
  });
  final String title, detail;
  final VoidCallback? onRetry;
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 17,
                  height: 24 / 17,
                  fontWeight: FontWeight.w600,
                  color: palette(context)['text.primary'],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                detail,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  height: 18 / 13,
                  color: palette(context)['text.secondary'],
                ),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 16),
                TextButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(LucideIcons.refreshCw, size: 16),
                  label: Text(tr("重新載入")),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SupportingLoading extends StatelessWidget {
  const SupportingLoading({super.key});
  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return Center(
      child: Semantics(
        label: tr("正在載入"),
        child: ExcludeSemantics(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: ListView(
              shrinkWrap: true,
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  tr("正在載入…"),
                  style: TextStyle(
                    fontSize: 13,
                    color: palette(context)['text.muted'],
                  ),
                ),
                for (var i = 0; i < 3; i++)
                  Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        color: palette(context)['surface.subtle'],
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
