import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../connection/hints.dart';
import '../format.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';
import 'chat_list_screen.dart';

/// One model approval, read again on `approvals_changed` (a second device
/// may answer it while the sheet is open).
final approvalProvider = FutureProvider.autoDispose
    .family<ModelApproval, String>((ref, id) {
      watchHint(ref, 'approvals_changed');
      return DecisionsApi(requireApi(ref)).approval(id);
    });

/// One budget request, read again on `budget_requests_changed`.
final budgetRequestProvider = FutureProvider.autoDispose
    .family<BudgetRequest, String>((ref, id) {
      watchHint(ref, 'budget_requests_changed');
      return DecisionsApi(requireApi(ref)).budgetRequest(id);
    });

/// The model approval sheet (E25–E26).
Future<void> showApprovalSheet(BuildContext context, String approvalId) =>
    _show(context, _ApprovalSheet(id: approvalId));

/// The budget request sheet: the same layout with Approve / Approve
/// another amount / Deny. [otherAmount] opens it on the amount field (the
/// card's "Approve another amount").
Future<void> showBudgetRequestSheet(
  BuildContext context,
  String requestId, {
  bool otherAmount = false,
}) => _show(context, _BudgetSheet(id: requestId, otherAmount: otherAmount));

/// Sends [answer] (`approve`, `approve_amount` with [amount] in the
/// request's unit, or `deny`) for budget request [id], then reads the
/// request again. Returns false when it was already answered (409, on
/// another device): the request read again shows that answer. Other
/// failures throw. The sheet and the conversation's card both use it.
Future<bool> answerBudgetRequest(
  WidgetRef ref,
  ApiClient api,
  String id, {
  required String answer,
  int? amount,
}) async {
  try {
    await DecisionsApi(
      api,
    ).answerBudgetRequest(id, answer: answer, amount: amount);
    return true;
  } on ApiError catch (error) {
    if (error.status != 409) rethrow;
    return false;
  } finally {
    ref.invalidate(budgetRequestProvider(id));
  }
}

Future<void> _show(BuildContext context, Widget sheet) =>
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      // Above the tabs, so a change of location under it keeps it open.
      useRootNavigator: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: SafeArea(child: SingleChildScrollView(child: sheet)),
      ),
    );

PotSummary? _pot(WidgetRef ref, String id) {
  for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[]) {
    if (pot.id == id) return pot;
  }
  return null;
}

class _ApprovalSheet extends ConsumerStatefulWidget {
  const _ApprovalSheet({required this.id});
  final String id;

  @override
  ConsumerState<_ApprovalSheet> createState() => _ApprovalSheetState();
}

class _ApprovalSheetState extends ConsumerState<_ApprovalSheet> {
  final _reason = TextEditingController();
  bool _withReason = false;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _answer(String answer, {String? reason}) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await DecisionsApi(
        api,
      ).answerApproval(widget.id, answer: answer, reason: reason);
      ref.invalidate(pendingApprovalsProvider);
      ref.invalidate(approvalProvider(widget.id));
      if (mounted) Navigator.pop(context);
    } on ApiError catch (error) {
      if (!mounted) return;
      if (error.status == 409) {
        // Answered elsewhere: read it again and show what was decided.
        ref.invalidate(approvalProvider(widget.id));
        ref.invalidate(pendingApprovalsProvider);
        setState(() => _busy = false);
      } else {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(approvalProvider(widget.id));
    final approval = value.value;
    if (approval == null) {
      return _Status(
        failed: value.hasError,
        onRetry: () => ref.invalidate(approvalProvider(widget.id)),
      );
    }
    final pot = _pot(ref, approval.potId);
    final potName = pot?.name ?? '';
    final models = ref.watch(modelsProvider).value ?? const <ModelInfo>[];
    final modelName =
        currentModel(models, approval.provider, approval.model)?.name ??
        approval.model;
    final workspace = _workspaceLine(ref, approval.workspaceId);
    final pending = approval.state == 'pending';
    return _SheetBody(
      pot: pot,
      title: l10n.approvalSheetTitle(potName, modelName),
      rows: [
        _Fact(
          l10n.approvalRowWork,
          approval.workTitle,
          sub: [
            ?workspace,
            if (pending || approval.state == 'denied') l10n.approvalNotStarted,
          ].join(' · '),
        ),
        _Fact(
          l10n.approvalRowModel,
          [
            if (approval.provider != null) _providerName(approval.provider!),
            modelName,
            if (approval.thinking != null)
              thinkingLabel(l10n, approval.thinking),
          ].join(' · '),
        ),
        if (approval.reason.isNotEmpty)
          _Fact(l10n.approvalRowWhy, approval.reason),
        _Fact(
          l10n.approvalRowBudget,
          approval.remainingMicros == null
              ? l10n.approvalEstimateNoLimit(usd(approval.estimateMicros))
              : l10n.approvalEstimate(
                  usd(approval.estimateMicros),
                  potName,
                  usd(approval.remainingMicros!),
                ),
        ),
      ],
      note: pending ? l10n.approvalNote(modelName, potName) : null,
      error: _error,
      actions: !pending
          ? _Answered(
              text: switch (approval.state) {
                'denied' when (approval.denyReason ?? '').isNotEmpty =>
                  l10n.answeredDeniedWithReason(approval.denyReason!),
                'denied' => l10n.answeredDenied,
                'used' => l10n.answeredUsed,
                _ => l10n.answeredAllowedOnce,
              },
            )
          : _withReason
          ? _Expanded(
              field: TextField(
                key: const ValueKey('deny-reason'),
                controller: _reason,
                autofocus: true,
                minLines: 2,
                maxLines: 5,
                maxLength: 2000,
                inputFormatters: [LengthLimitingTextInputFormatter(2000)],
                decoration: _fieldDecoration(
                  context,
                  l10n.denyReasonHint(potName),
                ),
                onChanged: (_) => setState(() {}),
              ),
              back: l10n.back,
              onBack: _busy ? null : () => setState(() => _withReason = false),
              confirm: l10n.denyAndSend,
              onConfirm: _busy || _reason.text.trim().isEmpty
                  ? null
                  : () => _answer('deny', reason: _reason.text.trim()),
            )
          : _Choices(
              first: l10n.deny,
              onFirst: _busy ? null : () => _answer('deny'),
              second: l10n.denyWithReason,
              onSecond: _busy ? null : () => setState(() => _withReason = true),
              main: l10n.allowOnce,
              onMain: _busy ? null : () => _answer('allow_once'),
            ),
    );
  }
}

class _BudgetSheet extends ConsumerStatefulWidget {
  const _BudgetSheet({required this.id, this.otherAmount = false});
  final String id;
  final bool otherAmount;

  @override
  ConsumerState<_BudgetSheet> createState() => _BudgetSheetState();
}

class _BudgetSheetState extends ConsumerState<_BudgetSheet> {
  final _amount = TextEditingController();
  late bool _other = widget.otherAmount;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _amount.dispose();
    super.dispose();
  }

  /// The typed amount in the request's unit (micro-dollars or tokens).
  int? _typed(BudgetRequest request) {
    final text = _amount.text.trim().replaceAll(',', '');
    if (request.unit == 'money') {
      final dollars = double.tryParse(text);
      if (dollars == null || dollars <= 0) return null;
      return (dollars * 1000000).round();
    }
    final tokens = int.tryParse(text);
    return tokens == null || tokens <= 0 ? null : tokens;
  }

  Future<void> _answer(String answer, {int? amount}) async {
    final api = ref.read(apiProvider);
    if (api == null || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final sent = await answerBudgetRequest(
        ref,
        api,
        widget.id,
        answer: answer,
        amount: amount,
      );
      if (!mounted) return;
      if (sent) {
        Navigator.pop(context);
      } else {
        setState(() => _busy = false);
      }
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final value = ref.watch(budgetRequestProvider(widget.id));
    final request = value.value;
    if (request == null) {
      return _Status(
        failed: value.hasError,
        onRetry: () => ref.invalidate(budgetRequestProvider(widget.id)),
      );
    }
    final pot = _pot(ref, request.potId);
    final potName = pot?.name ?? '';
    final money = request.unit == 'money';
    String asked(int? micros, int? tokens) => money
        ? l10n.budgetMoreMoney(usd(micros ?? 0))
        : l10n.budgetMoreTokens(grouped(context, tokens ?? 0));
    final left = pot?.budgetLeft;
    final leftText = money
        ? (left?.moneyMicros == null
              ? null
              : l10n.budgetLeftMoney(usd(left!.moneyMicros!)))
        : (left?.tokens == null
              ? null
              : l10n.budgetLeftTokens(grouped(context, left!.tokens!)));
    final typed = _typed(request);
    return _SheetBody(
      pot: pot,
      title: l10n.budgetSheetTitle(potName),
      rows: [
        _Fact(l10n.budgetRowAsk, asked(request.amountMicros, request.tokens)),
        if (request.reason.isNotEmpty)
          _Fact(l10n.approvalRowWhy, request.reason),
        if (leftText != null) _Fact(l10n.approvalRowBudget, leftText),
      ],
      note: request.pending ? l10n.budgetNote(potName) : null,
      error: _error,
      actions: !request.pending
          ? _Answered(
              text: switch (request.state) {
                'denied' => l10n.answeredDenied,
                'approved_amount' => l10n.answeredApprovedAmount(
                  asked(request.approvedAmountMicros, request.approvedTokens),
                ),
                _ => l10n.answeredApproved,
              },
            )
          : _other
          ? _Expanded(
              field: TextField(
                key: const ValueKey('budget-amount'),
                controller: _amount,
                autofocus: true,
                keyboardType: TextInputType.numberWithOptions(decimal: money),
                decoration: _fieldDecoration(
                  context,
                  money
                      ? l10n.budgetAmountMoneyHint
                      : l10n.budgetAmountTokensHint,
                ).copyWith(prefixText: money ? r'$ ' : null),
                onChanged: (_) => setState(() {}),
              ),
              back: l10n.back,
              onBack: _busy ? null : () => setState(() => _other = false),
              confirm: l10n.approveThisAmount,
              onConfirm: _busy || typed == null
                  ? null
                  : () => _answer('approve_amount', amount: typed),
            )
          : _Choices(
              first: l10n.deny,
              onFirst: _busy ? null : () => _answer('deny'),
              second: l10n.approveOtherAmount,
              onSecond: _busy ? null : () => setState(() => _other = true),
              main: l10n.approve,
              onMain: _busy ? null : () => _answer('approve'),
            ),
    );
  }
}

/// "pirc mobile · Laptop": the workspace's name and host.
String? _workspaceLine(WidgetRef ref, String workspaceId) {
  if (workspaceId.isEmpty) return null;
  for (final workspace
      in ref.watch(workspacesProvider).value ?? const <WorkspaceInfo>[]) {
    if (workspace.id == workspaceId) {
      return [
        workspace.displayName,
        if (workspace.hostId.isNotEmpty) workspace.hostId,
      ].join(' · ');
    }
  }
  final colon = workspaceId.indexOf(':');
  return colon < 0
      ? workspaceId
      : '${workspaceId.substring(colon + 1)} · ${workspaceId.substring(0, colon)}';
}

String _providerName(String id) =>
    id.isEmpty ? id : '${id[0].toUpperCase()}${id.substring(1)}';

InputDecoration _fieldDecoration(BuildContext context, String hint) {
  final colors = PircColorTokens.of(context);
  return InputDecoration(
    hintText: hint,
    filled: true,
    fillColor: colors['fill.hover'],
    counterText: '',
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(PircRadius.lg),
      borderSide: BorderSide.none,
    ),
  );
}

@immutable
class _Fact {
  const _Fact(this.label, this.value, {this.sub});
  final String label;
  final String value;
  final String? sub;
}

/// The sheet: avatar and title, the facts in a grouped box, a note, then
/// [actions].
class _SheetBody extends StatelessWidget {
  const _SheetBody({
    required this.pot,
    required this.title,
    required this.rows,
    required this.actions,
    this.note,
    this.error,
  });

  final PotSummary? pot;
  final String title;
  final List<_Fact> rows;
  final String? note;
  final String? error;
  final Widget actions;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            spacing: 10,
            children: [
              if (pot != null) PotAvatar(pot: pot!, size: AvatarSize.sm),
              Expanded(child: Text(title, style: text.titleLarge)),
            ],
          ),
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors['fill.hover'],
              borderRadius: BorderRadius.circular(PircRadius.lg),
            ),
            child: Column(
              children: [
                for (final (index, row) in rows.indexed) ...[
                  if (index > 0)
                    Divider(
                      height: 1,
                      indent: 16,
                      color: colors['line.hairline'],
                    ),
                  ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 56),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(
                              row.label,
                              style: TextStyle(
                                fontSize: 14,
                                height: 20 / 14,
                                color: colors['text.muted'],
                              ),
                            ),
                          ),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(row.value, style: text.bodyMedium),
                                if (row.sub != null && row.sub!.isNotEmpty)
                                  Text(
                                    row.sub!,
                                    style: text.bodySmall?.copyWith(
                                      color: colors['text.muted'],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (note != null) ...[
            const SizedBox(height: 12),
            Text(
              note!,
              style: text.bodySmall?.copyWith(color: colors['text.secondary']),
            ),
          ],
          if (error != null) ...[
            const SizedBox(height: 8),
            Text(
              error!,
              style: text.bodySmall?.copyWith(color: colors['status.danger']),
            ),
          ],
          const SizedBox(height: 16),
          actions,
        ],
      ),
    );
  }
}

/// Two buttons side by side, then the main one across.
class _Choices extends StatelessWidget {
  const _Choices({
    required this.first,
    required this.onFirst,
    required this.second,
    required this.onSecond,
    required this.main,
    required this.onMain,
  });

  final String first;
  final VoidCallback? onFirst;
  final String second;
  final VoidCallback? onSecond;
  final String main;
  final VoidCallback? onMain;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 8,
    children: [
      Row(
        spacing: 8,
        children: [
          Expanded(
            flex: 2,
            child: OutlinedButton(
              style: ghostButtonStyle(context),
              onPressed: onFirst,
              child: Text(first),
            ),
          ),
          Expanded(
            flex: 3,
            child: FilledButton(
              style: plainButtonStyle(context),
              onPressed: onSecond,
              child: Text(second),
            ),
          ),
        ],
      ),
      FilledButton(
        style: inkButtonStyle(context),
        onPressed: onMain,
        child: Text(main),
      ),
    ],
  );
}

/// The open field (a reason, an amount) with Back and the confirm button.
class _Expanded extends StatelessWidget {
  const _Expanded({
    required this.field,
    required this.back,
    required this.onBack,
    required this.confirm,
    required this.onConfirm,
  });

  final Widget field;
  final String back;
  final VoidCallback? onBack;
  final String confirm;
  final VoidCallback? onConfirm;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    spacing: 16,
    children: [
      field,
      Row(
        spacing: 8,
        children: [
          Expanded(
            child: FilledButton(
              style: plainButtonStyle(context),
              onPressed: onBack,
              child: Text(back),
            ),
          ),
          Expanded(
            child: FilledButton(
              style: inkButtonStyle(context),
              onPressed: onConfirm,
              child: Text(confirm),
            ),
          ),
        ],
      ),
    ],
  );
}

/// What was decided (here, on another device or earlier) and Close.
class _Answered extends StatelessWidget {
  const _Answered({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Text(
          '${l10n.answered} · $text',
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: colors['text.secondary']),
        ),
        FilledButton(
          style: plainButtonStyle(context),
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.close),
        ),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status({required this.failed, required this.onRetry});
  final bool failed;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 200,
      child: Center(
        child: failed
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.listFailed),
                  const SizedBox(height: 8),
                  OutlinedButton(onPressed: onRetry, child: Text(l10n.retry)),
                ],
              )
            : const CircularProgressIndicator(),
      ),
    );
  }
}
