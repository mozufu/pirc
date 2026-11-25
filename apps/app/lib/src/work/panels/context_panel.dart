import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import 'panel_common.dart';

/// 10e. Context (default F): what the model saw, read only, from
/// `…/panel/context`. A session with no message yet has no context.
class ContextPanel extends ConsumerWidget {
  const ContextPanel({super.key, required this.sessionId});
  final String sessionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final key = panelKey(
      sessionId,
      'panel/context',
      sections: const ['context'],
    );
    final value = ref.watch(panelReadProvider(key));
    // 404 no_context: nothing sent yet, an empty state rather than a failure.
    final empty =
        value.error is ApiError &&
        (value.error! as ApiError).code == 'no_context';
    if (empty) {
      return PanelNote(text: l10n.contextEmpty, icon: LucideIcons.gauge);
    }
    return PanelBody<Object?>(
      value: value,
      onRetry: () => ref.invalidate(panelReadProvider(key)),
      emptyText: l10n.contextEmpty,
      isEmpty: (d) => (d as Map?)?['snapshot'] == null,
      builder: (d) {
        final snapshot = (d! as Map)['snapshot'] as Map;
        final model = snapshot['model'] as Map? ?? const {};
        final usage = snapshot['usage'] as Map? ?? const {};
        final buckets = usage['buckets'] as Map? ?? const {};
        final sections = (snapshot['sections'] as List? ?? const [])
            .cast<Map>();
        final tools = (snapshot['tools'] as List? ?? const []).cast<Map>();
        return ListView(
          children: [
            ListTile(
              title: Text('${model['provider'] ?? ''} · ${model['id'] ?? ''}'),
              subtitle: Text(
                l10n.contextUsage(
                  (usage['estimatedInput'] as num?)?.toInt() ?? 0,
                  (model['contextWindow'] as num?)?.toInt() ?? 0,
                ),
              ),
            ),
            for (final MapEntry(:key, :value) in buckets.entries)
              ListTile(
                dense: true,
                title: Text('$key'),
                trailing: Text('$value'),
              ),
            const Divider(),
            for (final section in sections)
              ExpansionTile(
                title: Text('${section['title']}'),
                subtitle: Text(
                  l10n.contextTokens(
                    (section['estimatedTokens'] as num?)?.toInt() ?? 0,
                  ),
                ),
                children: [
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(
                      '${section['text']}',
                      style: PircType.monoCode.style(
                        color: colors['code.text'],
                      ),
                    ),
                  ),
                ],
              ),
            ListTile(
              dense: true,
              leading: const Icon(LucideIcons.wrench, size: 18),
              title: Text(l10n.contextTools(tools.length)),
            ),
          ],
        );
      },
    );
  }
}
