/// Agent RPC messages (pi-ai compatible) as timeline messages; a port of
/// `apps/web/src/lib/pi-messages.ts` (and `core/timeline/PiMessages.kt`).
/// Tool results fold into the assistant turn that issued the call, so the
/// timeline reads as conversation, not a raw log.
library;

import 'dart:convert';

import 'package:collection/collection.dart';

import '../json.dart';
import 'tools.dart';
import 'types.dart';

export 'tools.dart';

String piMessageId(Object? raw) =>
    '${text(field(raw, 'role')) ?? 'message'}-'
    '${text(field(raw, 'timestamp')) ?? 'live'}';

List<InlineImage> _images(Object? content) => [
  for (final item in array(content) ?? const [])
    if (str(field(item, 'type')) == 'image' && str(field(item, 'data')) != null)
      InlineImage(
        str(field(item, 'mimeType')) ?? 'image/png',
        str(field(item, 'data'))!,
      ),
];

/// The text blocks of a message's content (or the content itself if a string).
String contentText(Object? content) {
  if (content is String) return content;
  final blocks = array(content);
  if (blocks == null) return '';
  return blocks
      .where((it) => str(field(it, 'type')) == 'text')
      .map((it) => text(field(it, 'text')) ?? '')
      .join();
}

(String, bool) _thinking(Object? content) {
  final blocks = (array(content) ?? const [])
      .where((it) => str(field(it, 'type')) == 'thinking')
      .toList();
  final joined = blocks
      .map((it) => text(field(it, 'thinking')) ?? text(field(it, 'text')) ?? '')
      .where((it) => it.isNotEmpty)
      .join('\n\n');
  return (joined, blocks.any((it) => truthy(field(it, 'redacted'))));
}

Object? _parseArguments(Object? value) {
  if (value is! String) return value;
  try {
    return jsonDecode(value);
  } on FormatException {
    return value;
  }
}

ToolCall _toolFromCall(Object? part, String status) => ToolCall(
  id:
      text(field(part, 'id')) ??
      'tool-${text(field(part, 'name')) ?? text(field(part, 'toolName')) ?? 'undefined'}',
  name: text(field(part, 'name')) ?? text(field(part, 'toolName')) ?? 'tool',
  status: status,
  input: _parseArguments(
    field(part, 'arguments') ?? field(field(part, 'toolCall'), 'arguments'),
  ),
);

/// Where browser recordings live in a session's workspace.
final _recordingPath = RegExp(r'^\.pirc/recordings/[^/]+\.webm$');

String? _nonEmpty(String? value) =>
    value == null || value.isEmpty ? null : value;

/// Tool result payload (`toolResult` message or `tool_execution_*` result).
ToolUpdate toolResultFields(Object? result, String id) {
  if (result == null) return ToolUpdate(id);
  final details = field(result, 'details');
  final found = _images(field(result, 'content'));
  final path = str(field(details, 'path'));
  final recording =
      path != null &&
          field(details, 'recording') == false &&
          _recordingPath.hasMatch(path)
      ? path
      : null;
  return ToolUpdate(
    id,
    output: _nonEmpty(contentText(field(result, 'content'))),
    diff: _nonEmpty(str(field(details, 'diff'))),
    images: found.isEmpty ? null : found,
    recording: recording,
  );
}

Message _assistantMessage(Map<String, Object?> raw, String id, Now now) {
  final (reasoning, redacted) = _thinking(raw['content']);
  final stop = str(raw['stopReason']);
  final failed = stop == 'error' || stop == 'aborted';
  return Message(
    id: id,
    role: 'assistant',
    content: contentText(raw['content']),
    createdAt: at(raw['timestamp'], now),
    completedAt: number(raw['completedAt']),
    thinking: _nonEmpty(reasoning),
    thinkingRedacted: redacted,
    stopReason: failed ? stop : null,
    errorMessage: truthy(raw['errorMessage'])
        ? text(raw['errorMessage'])
        : null,
    model: truthy(raw['model']) ? text(raw['model']) : null,
    tools: [
      for (final part in array(raw['content']) ?? const [])
        if (str(field(part, 'type')) == 'toolCall')
          _toolFromCall(part, failed ? 'failed' : 'running'),
    ],
  );
}

final _spaces = RegExp(r'\s+');

String _short(Object? value) {
  final s = str(value);
  if (s == null) return '';
  final trimmed = s.replaceAll(_spaces, ' ').trim();
  return trimmed.length > 100 ? trimmed.substring(0, 100) : trimmed;
}

String _joinNonEmpty(List<String> parts) =>
    parts.where((it) => it.isNotEmpty).join(' · ');

/// Convert one agent message; null for messages that should not appear
/// (hidden custom messages). Tool results become an orphan system entry here;
/// [piHistory] folds them into their owning assistant turn.
Message? piMessage(Object? json, {String? id, Now now = systemNow}) {
  final raw = object(json);
  if (raw == null) return null;
  final messageId = id ?? piMessageId(raw);
  final createdAt = at(raw['timestamp'], now);
  switch (str(raw['role'])) {
    case 'assistant':
      return _assistantMessage(raw, messageId, now);
    case 'user':
      final branches = array(raw['branches']);
      return Message(
        id: messageId,
        role: 'user',
        content: contentText(raw['content']),
        createdAt: createdAt,
        images: _images(raw['content']),
        entryId: str(raw['entryId']),
        branches: [
          for (final branch in branches ?? const [])
            if (str(field(branch, 'entryId')) != null &&
                str(field(branch, 'text')) != null &&
                field(branch, 'selected') is bool)
              MessageBranch(
                str(field(branch, 'entryId'))!,
                str(field(branch, 'text'))!,
                field(branch, 'selected')! as bool,
              ),
        ],
      );
    case 'toolResult':
      final callId = text(raw['toolCallId']) ?? messageId;
      final result = toolResultFields(raw, callId);
      return Message(
        id: messageId,
        role: 'system',
        systemKind: 'custom',
        label: '${text(raw['toolName']) ?? 'Tool'} result',
        content: '',
        createdAt: createdAt,
        tools: [
          ToolCall(
            id: callId,
            name: text(raw['toolName']) ?? 'tool',
            status: truthy(raw['isError']) ? 'failed' : 'succeeded',
            output: result.output,
            diff: result.diff,
            images: result.images ?? const [],
            recording: result.recording,
          ),
        ],
      );
    case 'bashExecution':
      final cancelled = truthy(raw['cancelled']);
      final exitCode = raw['exitCode'];
      final exit = cancelled
          ? 'cancelled'
          : exitCode == null
          ? null
          : 'exit ${text(exitCode)}';
      final truncated = truthy(raw['truncated']);
      return Message(
        id: messageId,
        role: 'system',
        systemKind: 'bash',
        label: text(raw['command']) ?? '',
        content: text(raw['output']) ?? '',
        createdAt: createdAt,
        level: cancelled || (number(exitCode) ?? 0) != 0 ? 'warning' : 'info',
        meta: exit != null || truncated
            ? [?exit, if (truncated) 'truncated'].join(' · ')
            : null,
      );
    case 'compactionSummary':
      final tokens = number(raw['tokensBefore']);
      return Message(
        id: messageId,
        role: 'system',
        systemKind: 'compaction',
        label: 'Context compacted',
        content: text(raw['summary']) ?? '',
        createdAt: createdAt,
        meta: tokens == null ? null : '${groupThousands(tokens)} tokens before',
      );
    case 'branchSummary':
      return Message(
        id: messageId,
        role: 'system',
        systemKind: 'branch',
        label: 'Branch summary',
        content: text(raw['summary']) ?? '',
        createdAt: createdAt,
      );
    case 'custom':
      return _custom(raw, messageId, createdAt);
    default:
      final body = contentText(raw['content']);
      return Message(
        id: messageId,
        role: 'system',
        systemKind: 'custom',
        label: str(raw['role']) ?? 'Message',
        content: body.isNotEmpty ? body : str(raw['summary']) ?? '',
        createdAt: createdAt,
      );
  }
}

Message? _custom(Map<String, Object?> raw, String id, int createdAt) {
  if (raw['display'] == false) return null;
  final type = text(raw['customType']);
  // Backend-reserved provenance: the pot comes from `details`, which only the
  // gateway writes for this type. Never infer it from the text.
  if (type == 'pot-instruction') {
    final details = raw['details'];
    final potId = text(field(details, 'potId'));
    final potName = str(field(details, 'potName'));
    if (potId != null && potName != null && potName.isNotEmpty) {
      final body = contentText(raw['content']);
      // The gateway prefixes the text it gives the model; the tag says it.
      final preamble =
          'Instruction from $potName, a pot coordinating this work for the '
          'user:\n\n';
      return Message(
        id: id,
        role: 'system',
        systemKind: 'pot-instruction',
        label: potName,
        content: body.startsWith(preamble)
            ? body.substring(preamble.length)
            : body,
        createdAt: createdAt,
        pot: PotInstruction(
          potId: potId,
          potName: potName,
          workId: text(field(details, 'workId')),
          instructionId: text(field(details, 'instructionId')),
        ),
      );
    }
  }
  final team = type == 'agent-team';
  final background =
      type == 'background-task-finished' || type == 'background-task-output';
  final skill = type == 'skill';
  // Pushed by the gateway: a delegated task, news of one, or a scheduled run.
  final delegated = type == 'assistant-delegation';
  final delegationUpdate = type == 'assistant-delegation-update';
  final scheduled = type == 'scheduled-run';
  final details = raw['details'];
  final event = field(details, 'event');
  final String summary;
  if (team) {
    summary = _joinNonEmpty([
      _short(field(event, 'from')),
      _short(field(event, 'kind')),
    ]);
  } else if (background) {
    summary = _short(contentText(raw['content']).split('\n').first);
  } else if (delegated || scheduled) {
    summary = _short(field(details, 'title'));
  } else if (delegationUpdate) {
    summary = _joinNonEmpty([
      _short(field(details, 'delegationId')),
      _short(field(details, 'status')),
    ]);
  } else if (skill) {
    summary = _short(field(details, 'name'));
  } else {
    summary = '';
  }
  return Message(
    id: id,
    role: 'system',
    systemKind: team
        ? 'team'
        : background
        ? 'background'
        : 'custom',
    label: team
        ? 'Agent team'
        : background
        ? 'Background task'
        : delegated
        ? 'Task from your assistant'
        : delegationUpdate
        ? 'Delegation update'
        : scheduled
        ? 'Scheduled task'
        : skill
        ? 'Skill'
        : type ?? 'Extension',
    meta: _nonEmpty(summary),
    content: contentText(raw['content']),
    createdAt: createdAt,
    images: _images(raw['content']),
  );
}

/// Convert a full agent history, folding tool results into their assistant
/// turn and `ptc` operations (results with `parentToolCallId`, then the still
/// [running] ones from the snapshot's `operations`) into their `ptc` call.
List<Message> piHistory(
  List<Object?> history, {
  Now now = systemNow,
  List<Object?> running = const [],
}) {
  final messages = <Message>[];
  final owners = <String, int>{};
  final seen = <String>{};
  bool nest(String parentId, ToolUpdate update) {
    final ownerIndex = owners[parentId];
    if (ownerIndex == null) return false;
    final owner = messages[ownerIndex];
    final tools = withOperation(owner.tools, parentId, update);
    if (tools == null) return false;
    messages[ownerIndex] = owner.copyWith(tools: tools);
    return true;
  }

  for (final (index, raw) in history.indexed) {
    var id = piMessageId(raw);
    if (seen.contains(id)) id = '$id-$index';
    seen.add(id);

    final role = str(field(raw, 'role'));
    final failed = truthy(field(raw, 'isError'));
    final parentId = str(field(raw, 'parentToolCallId'));
    if (role == 'toolResult' && parentId != null) {
      final operationId = text(field(raw, 'toolCallId')) ?? id;
      final update = toolResultFields(raw, operationId).copyWith(
        name: text(field(raw, 'toolName')) ?? 'tool',
        status: failed ? 'failed' : 'succeeded',
        input: field(raw, 'args'),
      );
      if (nest(parentId, update)) continue;
    }

    final callId = text(field(raw, 'toolCallId'));
    if (role == 'toolResult' && callId != null && owners.containsKey(callId)) {
      final ownerIndex = owners[callId]!;
      final owner = messages[ownerIndex];
      final result = toolResultFields(
        raw,
        callId,
      ).copyWith(status: failed ? 'failed' : 'succeeded');
      messages[ownerIndex] = owner.copyWith(
        tools: [
          for (final tool in owner.tools)
            tool.id == callId ? mergeTool(tool, result) : tool,
        ],
      );
      continue;
    }

    final message = piMessage(raw, id: id, now: now);
    if (message == null) continue;
    messages.add(message);
    if (message.role == 'assistant') {
      for (final tool in message.tools) {
        owners[tool.id] = messages.length - 1;
      }
    }
  }
  for (final operation in running) {
    final operationId = str(field(operation, 'toolCallId'));
    final parentId = str(field(operation, 'parentToolCallId'));
    if (operationId == null || parentId == null) continue;
    nest(
      parentId,
      ToolUpdate(
        operationId,
        name: text(field(operation, 'toolName')) ?? 'tool',
        status: 'running',
        input: field(operation, 'args'),
      ),
    );
  }
  return messages;
}

/// Gateway-assembled partial assistant message (`{ base, content: {index: block} }`).
Message? piPartialMessage(Object? json, {Now now = systemNow}) {
  final raw = object(json);
  if (raw == null) return null;
  final entries = (object(raw['content']) ?? const {}).entries.toList();
  mergeSort(
    entries,
    compare: (a, b) => (double.tryParse(a.key) ?? double.nan).compareTo(
      double.tryParse(b.key) ?? double.nan,
    ),
  );
  final blocks = entries.map((it) => it.value).toList();
  final reasoning = blocks
      .where((it) => str(field(it, 'type')) == 'thinking')
      .map((it) => text(field(it, 'text')) ?? '')
      .join('\n\n');
  final tools = [
    for (final block in blocks)
      if (str(field(block, 'type')) == 'toolCall')
        _toolFromCall(
          field(block, 'toolCall') ??
              {
                if (field(block, 'id') != null) 'id': field(block, 'id'),
                if (field(block, 'toolName') != null)
                  'name': field(block, 'toolName'),
                if (field(block, 'arguments') != null)
                  'arguments': field(block, 'arguments'),
              },
          'running',
        ),
  ];
  final base = raw['base'];
  return Message(
    id: piMessageId(base ?? const {'role': 'assistant'}),
    role: 'assistant',
    content: blocks
        .where((it) => str(field(it, 'type')) == 'text')
        .map((it) => text(field(it, 'text')) ?? '')
        .join(),
    createdAt: at(field(base, 'timestamp'), now),
    isPartial: true,
    thinking: _nonEmpty(reasoning),
    tools: tools,
  );
}

/// Extension `notify` request → timeline notice.
Message piNotification(Object? raw, {int index = 0, Now now = systemNow}) {
  final type = str(field(raw, 'notifyType'));
  final level = type == 'error' || type == 'warning' ? type! : 'info';
  final received = field(raw, 'receivedAt');
  final atValue = number(received) != null ? received : field(raw, 'timestamp');
  return Message(
    id: 'notice-${text(field(raw, 'id')) ?? '${text(atValue) ?? 'live'}-$index'}',
    role: 'system',
    systemKind: 'notice',
    level: level,
    content: text(field(raw, 'message')) ?? '',
    createdAt: at(atValue, now),
  );
}

/// Insert notices into a chronological timeline by time. A streamed message
/// counts from when it finished, so a notice raised while the reply was still
/// streaming sorts above it, as it does live.
List<Message> interleave(List<Message> messages, List<Message> notices) {
  if (notices.isEmpty) return messages;
  final indexed = notices.indexed.toList()
    ..sort((a, b) {
      final byTime = a.$2.createdAt.compareTo(b.$2.createdAt);
      return byTime != 0 ? byTime : a.$1.compareTo(b.$1);
    });
  final pending = [for (final (_, notice) in indexed) notice];
  final result = <Message>[];
  var next = 0;
  for (final message in messages) {
    final time = message.completedAt ?? message.createdAt;
    while (next < pending.length && time > pending[next].createdAt) {
      result.add(pending[next++]);
    }
    result.add(message);
  }
  while (next < pending.length) {
    result.add(pending[next++]);
  }
  return result;
}
