/// A `GET /api/sessions/:id/snapshot` reply as [SessionState]; a port of the
/// web's `snapshotFromRaw`/`fromSnapshot` through `core/timeline/Events.kt`.
library;

import '../json.dart';
import '../models/session.dart';
import 'events.dart' show approvalModes, queueItems, thinkingLevels;
import 'pi_messages.dart';
import 'types.dart';

/// A chat's active delegations; malformed items are dropped, as on the web.
List<ChatDelegation> chatDelegations(Object? raw) => [
  for (final item in array(raw) ?? const [])
    if (str(field(item, 'id')) case final id?)
      if (str(field(item, 'targetSessionId')) case final target?)
        if (str(field(item, 'status')) case final status?
            when status == 'running' || status == 'waiting_input')
          ChatDelegation(
            id: id,
            title: str(field(item, 'title')) ?? '',
            workspace: str(field(item, 'workspace')) ?? '',
            status: status,
            dispatch: str(field(item, 'dispatch')) == 'auto'
                ? 'auto'
                : 'approved',
            targetSessionId: target,
          ),
];

RelayedFrom? _relayedFrom(Object? raw) {
  final sessionId = str(field(raw, 'sessionId'));
  if (sessionId == null) return null;
  return RelayedFrom(
    sessionId: sessionId,
    sessionName: str(field(raw, 'sessionName')) ?? '',
    workspace: str(field(raw, 'workspace')) ?? '',
    delegationId: str(field(raw, 'delegationId')) ?? '',
  );
}

Interaction _interaction(Object? raw) {
  final request = field(raw, 'request');
  final kind = str(field(raw, 'kind'));
  final id = text(field(raw, 'id')) ?? '';
  final runnerEpoch = text(field(raw, 'runnerEpoch')) ?? 'undefined';
  final toolCallId = str(field(request, 'toolCallId'));
  final title = text(field(request, 'title')) ?? 'The agent needs your input';
  final description = text(field(request, 'message'));
  final expiresAt = number(field(raw, 'expiresAt'));
  final status = text(field(raw, 'status')) ?? 'pending';
  final relayed = _relayedFrom(field(request, 'relayed'));
  Interaction build({
    String kind = 'input',
    List<InteractionOption> options = const [],
    bool multiple = false,
    String? placeholder,
    String? initialValue,
    String? confirmLabel,
    String? cancelLabel,
    Map<String, Object?>? modelChoice,
    UserRequestChoice? userRequestChoice,
  }) => Interaction(
    id: id,
    runnerEpoch: runnerEpoch,
    toolCallId: toolCallId,
    kind: kind,
    title: title,
    description: description,
    expiresAt: expiresAt,
    status: status,
    relayed: relayed,
    options: options,
    multiple: multiple,
    placeholder: placeholder,
    initialValue: initialValue,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    modelChoice: modelChoice,
    userRequestChoice: userRequestChoice,
  );

  switch (kind) {
    case 'select':
      final descriptions = array(field(request, 'optionDescriptions'));
      return build(
        kind: 'select',
        multiple: truthy(field(request, 'multiple')),
        options: [
          for (final (index, option)
              in (array(field(request, 'options')) ?? const []).indexed)
            InteractionOption(
              text(option) ?? '',
              text(option) ?? '',
              descriptions != null &&
                      index < descriptions.length &&
                      truthy(descriptions[index])
                  ? text(descriptions[index])
                  : null,
            ),
        ],
      );
    case 'confirm':
      final choice = field(request, 'userRequestChoice');
      final choiceLabel = str(field(choice, 'label'));
      return build(
        kind: 'confirm',
        confirmLabel: text(field(request, 'confirmLabel')),
        cancelLabel: text(field(request, 'cancelLabel')),
        modelChoice: object(field(request, 'modelChoice')),
        userRequestChoice: choiceLabel == null
            ? null
            : UserRequestChoice(choiceLabel, field(choice, 'checked') == true),
      );
    case 'editor':
      return build(
        kind: 'editor',
        initialValue: text(field(request, 'prefill')) ?? '',
      );
    default:
      return build(placeholder: text(field(request, 'placeholder')));
  }
}

/// A `GET /api/sessions/:id/snapshot` reply (decoded JSON) as client state.
SessionState snapshotState(Object? raw, {Now now = systemNow}) {
  final sessionJson = field(raw, 'session');
  if (sessionJson == null) {
    throw const FormatException('snapshot without a session');
  }
  final session = Session.fromJson(sessionJson);
  final partial = piPartialMessage(field(raw, 'partialMessage'), now: now);
  final notices = [
    for (final (index, item)
        in (array(field(raw, 'notifications')) ?? const [])
            .where((it) => str(field(it, 'method')) == 'notify')
            .indexed)
      piNotification(item, index: index, now: now),
  ];
  final messages = interleave(
    piHistory(
      array(field(raw, 'history')) ?? const [],
      now: now,
      running: array(field(raw, 'operations')) ?? const [],
    ),
    notices,
  );
  final run = field(raw, 'run');
  final watermark = field(raw, 'watermark');
  final agent = field(raw, 'agent');
  final model = field(agent, 'model');
  final sandbox = field(raw, 'sandbox');
  final queue = field(raw, 'queue');
  return SessionState(
    session: session,
    runnerStatus: text(field(sessionJson, 'runnerState')) ?? 'stopped',
    run: run == null
        ? null
        : RunState(
            id: text(field(run, 'id')),
            status: text(field(run, 'status')) ?? 'undefined',
            startedAt: truthy(field(run, 'startedAt'))
                ? at(field(run, 'startedAt'), now)
                : null,
            endedAt: truthy(field(run, 'endedAt'))
                ? at(field(run, 'endedAt'), now)
                : null,
            failureReason: text(field(run, 'failureReason')),
          ),
    // A snapshot taken mid-stream carries the live partial separately.
    messages: partial != null
        ? [...messages.where((it) => it.id != partial.id), partial]
        : messages,
    interactions: [
      for (final item in array(field(raw, 'interactions')) ?? const [])
        _interaction(item),
    ],
    delegations: chatDelegations(field(raw, 'delegations')),
    queue: queueItems(field(queue, 'steering'), field(queue, 'followUp')),
    cursor:
        '${text(field(watermark, 'epoch')) ?? '0'}:'
        '${text(field(watermark, 'sequence')) ?? '0'}',
    runnerEpoch:
        text(field(watermark, 'epoch')) ??
        text(field(sessionJson, 'runnerEpoch')) ??
        '0',
    selectedModelId: truthy(field(model, 'id'))
        ? text(field(model, 'id'))
        : null,
    selectedModelProvider: truthy(field(model, 'provider'))
        ? text(field(model, 'provider'))
        : null,
    thinkingLevel: _oneOf(str(field(agent, 'thinkingLevel')), thinkingLevels),
    approvalMode: _oneOf(str(field(agent, 'approvalMode')), approvalModes),
    defaultApprovalMode: _oneOf(
      str(field(agent, 'defaultApprovalMode')),
      approvalModes,
    ),
    widgets: {
      for (final MapEntry(:key, :value)
          in (object(field(raw, 'widgets')) ?? const {}).entries)
        key: [
          for (final line in array(value) ?? const []) text(line) ?? 'null',
        ],
    },
    statuses: {
      for (final MapEntry(:key, :value)
          in (object(field(raw, 'statuses')) ?? const {}).entries)
        key: text(value) ?? 'null',
    },
    sandbox: truthy(sandbox) && field(sandbox, 'active') is bool
        ? SandboxStatus(
            field(sandbox, 'active')! as bool,
            str(field(sandbox, 'reason')),
          )
        : null,
  );
}

String? _oneOf(String? value, Set<String> allowed) =>
    value != null && allowed.contains(value) ? value : null;
