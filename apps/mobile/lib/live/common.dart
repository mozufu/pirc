import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import '../theme.dart';
import 'gateway.dart';

PircColors palette(BuildContext context) =>
    Theme.of(context).extension<PircColors>()!;
List<BoxShadow> pircShadow(BuildContext context, {bool card = false}) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  if (dark && card) return [];
  return [
    if (!dark)
      BoxShadow(
        color: palette(
          context,
        )['text.primary'].withValues(alpha: card ? .04 : .05),
        blurRadius: card ? 2 : 8,
        offset: Offset(0, card ? 1 : 2),
      ),
    BoxShadow(
      color: (dark ? Colors.black : palette(context)['text.primary'])
          .withValues(
            alpha: dark
                ? .45
                : card
                ? .06
                : .09,
          ),
      blurRadius: dark
          ? 28
          : card
          ? 20
          : 32,
      offset: Offset(
        0,
        dark
            ? 8
            : card
            ? 6
            : 10,
      ),
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
      content: Text(message),
      behavior: SnackBarBehavior.floating,
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 120),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      duration: const Duration(seconds: 5),
    ),
  );
}

Future<bool> confirm(
  BuildContext context,
  String title,
  String body, {
  String action = '確認',
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(child: Text(body)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(action),
          ),
        ],
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
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: field,
        autofocus: true,
        minLines: lines,
        maxLines: lines == 1 ? 1 : 8,
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, field.text),
          child: const Text('確認'),
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
  Widget build(BuildContext context) => Material(
    color: palette(context)[layer ? 'surface.layer' : 'surface.subtle'],
    borderRadius: BorderRadius.circular(16),
    clipBehavior: Clip.antiAlias,
    child: Padding(padding: padding, child: child),
  );
}

class RichTextBody extends StatelessWidget {
  const RichTextBody(
    this.text, {
    super.key,
    required this.gateway,
    this.onFile,
    this.reader = false,
  });
  final String text;
  final Gateway gateway;
  final void Function(String)? onFile;
  final bool reader;
  @override
  Widget build(BuildContext context) => MarkdownBody(
    data: text,
    selectable: true,
    styleSheet: MarkdownStyleSheet.fromTheme(Theme.of(context)).copyWith(
      p: TextStyle(
        fontSize: reader ? 16.5 : 16,
        height: reader ? 29 / 16.5 : 28 / 16,
      ),
      code: const TextStyle(fontFamily: 'monospace', fontSize: 13),
    ),
    onTapLink: (label, href, title) {
      if (href == null) return;
      final uri = Uri.tryParse(href);
      if (uri != null && ['https', 'http'].contains(uri.scheme)) {
        guarded(
          context,
          () => gateway.call('external', {'url': href}).then((_) {}),
        );
      } else {
        onFile?.call(
          Uri.decodeComponent(href.replaceFirst(RegExp(r'^\./'), '')),
        );
      }
    },
    imageBuilder: (uri, title, alt) {
      if (uri.scheme == 'data') {
        try {
          return Image.memory(
            uri.data!.contentAsBytes(),
            errorBuilder: (_, e, s) => Text(alt ?? '圖片無法顯示'),
          );
        } catch (_) {
          return Text(alt ?? '圖片');
        }
      }
      // Gateway files need native authenticated fetching; never attach credentials to external images.
      return TextButton.icon(
        onPressed: () => onFile?.call(uri.toString()),
        icon: const Icon(LucideIcons.image),
        label: Text(alt ?? uri.path),
      );
    },
  );
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
                errorBuilder: (_, e, s) => const Text('圖片無法顯示'),
              );
            } catch (_) {
              return const Text('圖片無法顯示');
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
  Widget build(BuildContext context) => FutureBuilder<Json>(
    future: future,
    builder: (context, s) {
      if (s.hasError) {
        return SupportingState(
          title: '暫時無法載入',
          detail: LiveController.describe(s.error!),
          onRetry: reload,
        );
      }
      if (!s.hasData) return const SupportingLoading();
      return widget.builder(context, s.data!, reload);
    },
  );
}

/// Final submission actions use ink; navigation and setup use the accent.
class FinalButton extends StatelessWidget {
  const FinalButton({super.key, required this.onPressed, required this.child});
  final VoidCallback? onPressed;
  final Widget child;
  @override
  Widget build(BuildContext context) => FilledButton(
    onPressed: onPressed,
    style: FilledButton.styleFrom(
      backgroundColor: palette(context)['action.primary'],
      foregroundColor: palette(context)['action.onPrimary'],
    ),
    child: child,
  );
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
  Widget build(BuildContext context) => Center(
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
                label: const Text('重新載入'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

class SupportingLoading extends StatelessWidget {
  const SupportingLoading({super.key});
  @override
  Widget build(BuildContext context) => Center(
    child: Semantics(
      label: '正在載入',
      child: ExcludeSemantics(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: ListView(
            shrinkWrap: true,
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '正在載入…',
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
