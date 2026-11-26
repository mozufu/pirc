import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/work_data.dart';
import 'thread_data.dart';

/// The pause sheet (E13): what waits while the pot is paused and what goes
/// on; its button pauses the pot with its current revision.
Future<void> showPotPauseSheet(BuildContext context, String potId) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // Above the tabs, so a change of location under it keeps it open.
      useRootNavigator: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(child: _PauseSheet(potId: potId)),
      ),
    );

/// Resumes [potId] with its current revision; a refusal shows its message.
Future<void> resumePot(
  BuildContext context,
  WidgetRef ref,
  String potId,
) async {
  final api = ref.read(apiProvider);
  if (api == null) return;
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final pot = await ref.read(potProvider(potId).future);
    await PotsApi(api).resume(potId, revision: pot.revision);
  } on PircException catch (error) {
    messenger?.showSnackBar(SnackBar(content: Text(error.message)));
  } finally {
    ref.invalidate(potProvider(potId));
    ref.invalidate(potsProvider);
  }
}

class _PauseSheet extends ConsumerStatefulWidget {
  const _PauseSheet({required this.potId});
  final String potId;

  @override
  ConsumerState<_PauseSheet> createState() => _PauseSheetState();
}

class _PauseSheetState extends ConsumerState<_PauseSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _pause() async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final pot = await ref.read(potProvider(widget.potId).future);
      await PotsApi(api).pause(widget.potId, revision: pot.revision);
      if (mounted) Navigator.pop(context);
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    } finally {
      ref.invalidate(potProvider(widget.potId));
      ref.invalidate(potsProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final pot = ref.watch(potProvider(widget.potId)).value;
    final name = pot?.name ?? '';
    return Column(
      key: const ValueKey('pause-sheet'),
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
          child: Text(
            l10n.potPauseTitle(name),
            style: TextStyle(
              fontSize: 20,
              height: 28 / 20,
              fontWeight: FontWeight.w600,
              color: colors['text.primary'],
            ),
          ),
        ),
        _PreviewHeader(l10n.potPauseWhile),
        _PreviewItem(
          stop: true,
          text: l10n.potPauseNoDelivery,
          detail: l10n.potPauseNoDeliveryDetail,
        ),
        _PreviewItem(stop: true, text: l10n.potPauseWait),
        _PreviewItem(stop: true, text: l10n.potPauseNoWork),
        _PreviewHeader(l10n.potPauseGoesOn),
        _PreviewItem(
          text: l10n.potPauseWorks,
          detail: l10n.potPauseWorksDetail,
        ),
        _PreviewItem(text: l10n.potPauseThreads),
        _PreviewItem(
          text: l10n.potPauseNothingMoves,
          detail: l10n.potPauseNothingMovesDetail,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Text(
              _error!,
              key: const ValueKey('pause-error'),
              style: TextStyle(
                fontSize: 13,
                height: 18 / 13,
                color: colors['status.danger'],
              ),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Row(
            spacing: 8,
            children: [
              Expanded(
                child: FilledButton(
                  style: plainButtonStyle(context),
                  onPressed: _busy ? null : () => Navigator.pop(context),
                  child: Text(l10n.cancel),
                ),
              ),
              Expanded(
                child: FilledButton(
                  key: const ValueKey('pause-confirm'),
                  style: inkButtonStyle(context),
                  onPressed: _busy || pot == null ? null : _pause,
                  child: Text(l10n.potActionPause),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// `d-prev-h`: 12.5/600 muted, 14 above.
class _PreviewHeader extends StatelessWidget {
  const _PreviewHeader(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 12.5,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        color: PircColorTokens.of(context)['text.muted'],
      ),
    ),
  );
}

/// `d-pi`: a 22 icon square (stop: `status.dangerSoft`; keep:
/// `fill.hoverStrong`), the line (14/20) and its detail (12.5/18 muted).
class _PreviewItem extends StatelessWidget {
  const _PreviewItem({required this.text, this.detail, this.stop = false});

  final String text;
  final String? detail;
  final bool stop;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        spacing: 10,
        children: [
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: stop
                  ? colors['status.dangerSoft']
                  : colors['fill.hoverStrong'],
              borderRadius: BorderRadius.circular(6),
            ),
            child: Icon(
              stop ? LucideIcons.pause : LucideIcons.check,
              size: 13,
              color: stop ? colors['status.danger'] : colors['text.secondary'],
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 14,
                    height: 20 / 14,
                    color: colors['text.primary'],
                  ),
                ),
                if (detail != null)
                  Text(
                    detail!,
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 18 / 12.5,
                      color: colors['text.muted'],
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
