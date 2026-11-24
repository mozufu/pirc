import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'gateway.dart';
import 'common.dart';

Future<void> showQuestion(
  BuildContext context,
  LiveController c,
  Json question,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => QuestionSheet(controller: c, question: question),
);

class QuestionSheet extends StatefulWidget {
  const QuestionSheet({
    super.key,
    required this.controller,
    required this.question,
    this.embedded = false,
    this.onLayout,
    this.initialChoice,
  });
  final LiveController controller;
  final Json question;
  final bool embedded;
  final String? initialChoice;
  final VoidCallback? onLayout;
  @override
  State<QuestionSheet> createState() => _QuestionSheetState();
}

class _QuestionSheetState extends State<QuestionSheet> {
  late final String session = widget.controller.sessionId!;
  Json? current;
  final text = TextEditingController();
  final selected = <String>{};
  bool? confirmed;
  bool busy = true, unknown = false;
  String? error;
  Timer? expiry;
  Json lease = {};
  @override
  void initState() {
    super.initState();
    if (widget.initialChoice != null) {
      selected.add(widget.initialChoice!);
      confirmed = widget.initialChoice == 'yes'
          ? true
          : widget.initialChoice == 'no'
          ? false
          : null;
    }
    refresh();
  }

  @override
  void didUpdateWidget(covariant QuestionSheet oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (jsonEncode(oldWidget.question) != jsonEncode(widget.question) &&
        !busy) {
      refresh();
    }
  }

  @override
  void dispose() {
    expiry?.cancel();
    text.dispose();
    super.dispose();
  }

  Future<void> refresh() async {
    setState(() => busy = true);
    try {
      final state = obj(
        await widget.controller.gateway.call('refresh', {'sessionId': session}),
      );
      final next = rows(state['interactions'])
          .where(
            (q) => widget.question['id'] == null
                ? q['status'] == 'pending'
                : q['id'] == widget.question['id'],
          )
          .firstOrNull;
      if (!mounted) return;
      if (current == null && next != null) {
        text.text = '${next['initialValue'] ?? ''}';
        if (next['kind'] == 'select') {
          selected.retainAll(rows(next['options']).map((o) => '${o['value']}'));
        }
      }
      if (current != null &&
          (current!['epoch'] != next?['epoch'] ||
              current!['title'] != next?['title'] ||
              jsonEncode(current!['options']) !=
                  jsonEncode(next?['options']))) {
        selected.clear();
        confirmed = null;
      }
      current = next;
      expiry?.cancel();
      if (next?['expiresAt'] is num) {
        final remaining =
            (next!['expiresAt'] as num).toInt() -
            DateTime.now().millisecondsSinceEpoch;
        if (remaining > 0) {
          expiry = Timer(Duration(milliseconds: remaining), () {
            if (mounted) setState(() => error = '這個問題已過期');
          });
        }
      }
      error = null;
      if (next == null || next['status'] != 'pending') {
        error = '這個問題已處理或不再有效';
        unknown = false;
      } else if (next['epoch'] != state['runnerEpoch'] ||
          (next['expiresAt'] is num &&
              next['expiresAt'] <= DateTime.now().millisecondsSinceEpoch)) {
        error = '這個問題已過期';
      }
      if (error == null) {
        lease = obj(
          await widget.controller.gateway.call('control', {
            'sessionId': session,
            'acquire': true,
          }),
        );
        if (!mounted) return;
      }
    } catch (e) {
      if (mounted) error = LiveController.describe(e);
    } finally {
      if (mounted) {
        widget.onLayout?.call();
        setState(() => busy = false);
      }
    }
  }

  Future<void> submit({bool cancel = false}) async {
    if (busy ||
        unknown ||
        current == null ||
        error != null ||
        lease['held'] != true) {
      return;
    }
    final q = current!;
    setState(() => busy = true);
    try {
      final answer = cancel
          ? <String, dynamic>{'cancelled': true}
          : switch (q['kind']) {
              'confirm' => {'confirmed': confirmed},
              'select' => {'values': selected.toList()},
              _ => {'value': text.text},
            };
      await widget.controller.gateway.call('answer', {
        'sessionId': session,
        'interactionId': q['id'],
        'epoch': q['epoch'],
        'answer': answer,
      });
      if (mounted) {
        if (widget.embedded) {
          await refresh();
        } else {
          Navigator.pop(context);
        }
      }
    } catch (e) {
      if (!mounted) return;
      unknown =
          e is! PlatformException ||
          !e.code.startsWith('HTTP_4') ||
          obj(e.details)['code'] == 'outcome_unknown';
      error = unknown ? '不確定是否已送達，請檢查狀態；不會重送。' : LiveController.describe(e);
      setState(() => busy = false);
    }
  }

  Widget _option(
    String label,
    bool chosen,
    VoidCallback select, {
    String? description,
    bool multiple = false,
  }) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Material(
      color: palette(context)[chosen ? 'accent.soft' : 'fill.hover'],
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        onTap: select,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          constraints: const BoxConstraints(minHeight: 48),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: chosen
                ? Border.all(color: palette(context)['accent.default'])
                : null,
          ),
          child: Row(
            children: [
              Icon(
                multiple
                    ? (chosen ? LucideIcons.squareCheck : LucideIcons.square)
                    : (chosen ? LucideIcons.circleDot : LucideIcons.circle),
                size: 20,
                color: palette(
                  context,
                )[chosen ? 'accent.default' : 'text.faint'],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: const TextStyle(fontSize: 15)),
                    if (description != null)
                      Text(
                        description,
                        style: TextStyle(
                          fontSize: 13,
                          color: palette(context)['text.secondary'],
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
  );

  @override
  Widget build(BuildContext context) {
    final q = current ?? widget.question;
    final valid = switch (q['kind']) {
      'confirm' => confirmed != null,
      'select' => selected.isNotEmpty,
      _ => text.text.trim().isNotEmpty,
    };
    return Padding(
      padding: EdgeInsets.only(
        bottom: widget.embedded ? 0 : MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: widget.embedded
              ? double.infinity
              : MediaQuery.sizeOf(context).height * .85,
        ),
        child: SingleChildScrollView(
          padding: EdgeInsets.all(widget.embedded ? 16 : 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: palette(context)['status.warningSoft'],
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(
                      LucideIcons.circleHelp,
                      size: 18,
                      color: palette(context)['text.warning'],
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      '${q['title']}',
                      style: const TextStyle(
                        fontSize: 17,
                        height: 24 / 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (q['description'] != null) Text('${q['description']}'),
              if (busy)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Row(
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(width: 16),
                      Expanded(child: Text('正在確認最新狀態…')),
                    ],
                  ),
                ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(error!),
                ),
              if (!busy && error == null && lease['held'] != true)
                Surface(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '由 ${lease['holderName'] ?? lease['holderClientId'] ?? '其他裝置'} 控制中',
                      ),
                      TextButton(
                        onPressed: () => guarded(context, () async {
                          if (await confirm(
                            context,
                            '取得控制權',
                            '確認接管後，才能送出答案。',
                          )) {
                            await widget.controller.takeControl(force: true);
                            await refresh();
                          }
                        }),
                        child: const Text('取得控制權'),
                      ),
                    ],
                  ),
                ),
              if (!busy && !unknown && error == null) ...[
                if (q['kind'] == 'confirm')
                  for (final value in [true, false])
                    _option(
                      value ? '確認' : '拒絕',
                      confirmed == value,
                      () => setState(() => confirmed = value),
                    ),
                if (q['kind'] == 'select')
                  for (final option in rows(q['options']))
                    _option(
                      '${option['label']}',
                      selected.contains('${option['value']}'),
                      () => setState(() {
                        final value = '${option['value']}';
                        final wasSelected = selected.contains(value);
                        if (q['multiple'] != true) selected.clear();
                        if (!wasSelected) {
                          selected.add(value);
                        } else {
                          selected.remove(value);
                        }
                      }),
                      description: option['description'] as String?,
                      multiple: q['multiple'] == true,
                    ),
                if (['input', 'editor'].contains(q['kind']))
                  TextField(
                    controller: text,
                    minLines: q['kind'] == 'editor' ? 5 : 1,
                    maxLines: 10,
                    onChanged: (_) => setState(() {}),
                    style: q['kind'] == 'editor'
                        ? const TextStyle(fontFamily: 'monospace')
                        : null,
                    decoration: supportingField(
                      context,
                      hint: '${q['placeholder'] ?? '輸入答案'}',
                    ),
                  ),
                const SizedBox(height: 16),
                if (q['expiresAt'] is num)
                  Text(
                    '到期 ${DateTime.fromMillisecondsSinceEpoch((q['expiresAt'] as num).toInt()).toLocal().toString().substring(0, 16)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: palette(context)['text.warning'],
                    ),
                  ),
                Wrap(
                  spacing: 8,
                  children: [
                    FinalButton(
                      onPressed: valid && lease['held'] == true ? submit : null,
                      child: const Text('送出答案'),
                    ),
                    TextButton(
                      onPressed: lease['held'] != true
                          ? null
                          : () async {
                              if (await confirm(
                                    context,
                                    '取消這個問題',
                                    '取消會回覆 agent 此問題已取消。',
                                  ) &&
                                  mounted) {
                                await submit(cancel: true);
                              }
                            },
                      child: const Text('取消問題'),
                    ),
                  ],
                ),
              ],
              if (!busy)
                TextButton(onPressed: refresh, child: const Text('檢查最新狀態')),
            ],
          ),
        ),
      ),
    );
  }
}
