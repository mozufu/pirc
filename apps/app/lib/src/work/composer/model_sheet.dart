import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../../l10n/app_localizations.dart';
import '../../connection/data.dart';

/// The models the Gateway serves.
final modelsProvider = FutureProvider<List<ModelInfo>>(
  (ref) => ModelsApi(requireApi(ref)).list(),
);

/// Thinking levels in order.
const thinkingOrder = [
  'off',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

String thinkingLabel(AppLocalizations l10n, String? level) => switch (level) {
  'off' => l10n.thinkingOff,
  'minimal' => l10n.thinkingMinimal,
  'low' => l10n.thinkingLow,
  'medium' => l10n.thinkingMedium,
  'high' => l10n.thinkingHigh,
  'xhigh' => l10n.thinkingXhigh,
  'max' => l10n.thinkingMax,
  _ => l10n.thinkingDefault,
};

/// The current model of [models] by provider and ID.
ModelInfo? currentModel(List<ModelInfo> models, String? provider, String? id) {
  for (final model in models) {
    if (model.id == id && (provider == null || model.provider == provider)) {
      return model;
    }
  }
  return null;
}

/// C option 3: two rows, "Model" and "Thinking", each opening its list. A
/// model without thinking disables the Thinking row.
Future<void> showModelSheet(
  BuildContext context, {
  required String? provider,
  required String? modelId,
  required String? thinking,
  required ValueChanged<ModelInfo> onModel,
  required ValueChanged<String> onThinking,
}) => showModalBottomSheet<void>(
  context: context,
  showDragHandle: true,
  isScrollControlled: true,
  builder: (context) => _ModelSheet(
    provider: provider,
    modelId: modelId,
    thinking: thinking,
    onModel: onModel,
    onThinking: onThinking,
  ),
);

class _ModelSheet extends ConsumerStatefulWidget {
  const _ModelSheet({
    required this.provider,
    required this.modelId,
    required this.thinking,
    required this.onModel,
    required this.onThinking,
  });

  final String? provider;
  final String? modelId;
  final String? thinking;
  final ValueChanged<ModelInfo> onModel;
  final ValueChanged<String> onThinking;

  @override
  ConsumerState<_ModelSheet> createState() => _ModelSheetState();
}

class _ModelSheetState extends ConsumerState<_ModelSheet> {
  String? _open;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final models = ref.watch(modelsProvider);
    final list = models.value ?? const <ModelInfo>[];
    final current = currentModel(list, widget.provider, widget.modelId);
    final thinkingEnabled = current?.reasoning ?? false;
    Widget check(bool on) => on
        ? Icon(LucideIcons.check, color: colors['accent.default'])
        : const SizedBox(width: 24);
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.8,
        ),
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              title: Text(l10n.modelRow),
              subtitle: Text(
                current?.name ?? widget.modelId ?? l10n.modelDefault,
              ),
              trailing: Icon(
                _open == 'model'
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
              ),
              onTap: () =>
                  setState(() => _open = _open == 'model' ? null : 'model'),
            ),
            if (_open == 'model')
              if (models.isLoading && list.isEmpty)
                const Center(child: CircularProgressIndicator())
              else
                for (final model in list)
                  ListTile(
                    contentPadding: const EdgeInsets.only(left: 32, right: 16),
                    title: Text(model.name),
                    subtitle: Text(model.provider),
                    trailing: check(identical(model, current)),
                    onTap: () {
                      Navigator.pop(context);
                      widget.onModel(model);
                    },
                  ),
            ListTile(
              enabled: thinkingEnabled,
              title: Text(l10n.thinkingRow),
              subtitle: Text(
                thinkingEnabled
                    ? thinkingLabel(l10n, widget.thinking)
                    : l10n.thinkingUnsupported,
              ),
              trailing: Icon(
                _open == 'thinking'
                    ? LucideIcons.chevronUp
                    : LucideIcons.chevronDown,
              ),
              onTap: () => setState(
                () => _open = _open == 'thinking' ? null : 'thinking',
              ),
            ),
            if (_open == 'thinking' && thinkingEnabled)
              for (final level in thinkingOrder)
                ListTile(
                  contentPadding: const EdgeInsets.only(left: 32, right: 16),
                  title: Text(thinkingLabel(l10n, level)),
                  trailing: check(level == widget.thinking),
                  onTap: () {
                    Navigator.pop(context);
                    widget.onThinking(level);
                  },
                ),
          ],
        ),
      ),
    );
  }
}
