/// Applying `/api/events` to a [SessionState]; a port of the web's
/// `reduceEvent` (`state.ts`) through `core/timeline/Events.kt`.
library;

import '../json.dart';
import 'events.dart';
import 'pi_messages.dart';
import 'types.dart';

/// Apply one event. Nonterminal events from another epoch require a new snapshot.
SessionState reduceEvent(
  SessionState state,
  EventEnvelope envelope, {
  Now now = systemNow,
}) {
  final event = envelope.event;
  if (event is! Reset &&
      event is! SessionDeleted &&
      envelope.runnerEpoch != state.runnerEpoch) {
    return state.copyWith(needsSnapshot: true);
  }
  final base = state.copyWith(cursor: envelope.cursor);
  final messages = state.messages;
  switch (event) {
    case Reset():
      return base.copyWith(needsSnapshot: true);
    case SessionDeleted() || Noop() || CheckpointsChanged() || PanelChanged():
      return base;
    case WidgetUpdated(:final key, :final lines):
      final widgets = Map.of(state.widgets);
      if (lines != null && lines.isNotEmpty) {
        widgets[key] = lines;
      } else {
        widgets.remove(key);
      }
      return base.copyWith(widgets: widgets);
    case StatusUpdated(:final key, :final text):
      final statuses = Map.of(state.statuses);
      if (text != null && text.isNotEmpty) {
        statuses[key] = text;
      } else {
        statuses.remove(key);
      }
      return base.copyWith(statuses: statuses);
    case ApprovalModeChanged(:final mode):
      return base.copyWith(approvalMode: mode);
    case MessageStarted(:final message):
      // Replace a stale partial with the same id; never clobber a finished message.
      final kept = messages
          .where((it) => !(it.id == message.id && it.isPartial))
          .toList();
      return base.copyWith(
        messages: [
          ...kept,
          message.copyWith(id: _uniqueId(kept, message.id, envelope)),
        ],
      );
    case MessageDelta():
      return _delta(base, event, envelope, now);
    case MessageCompleted(message: final incoming):
      return _completed(base, incoming);
    case ToolUpdated():
      return _tool(base, event);
    case QueueUpdated(:final queue):
      return base.copyWith(queue: queue);
    case SessionRenamed(:final name):
      return base.copyWith(session: state.session.copyWith(name: name));
    case DelegationsChanged(:final delegations):
      return base.copyWith(delegations: delegations);
  }
}

SessionState _delta(
  SessionState base,
  MessageDelta event,
  EventEnvelope envelope,
  Now now,
) {
  var list = base.messages;
  var index = event.messageId != null
      ? list.indexWhere((it) => it.id == event.messageId)
      : list.lastIndexWhere((it) => it.role == 'assistant' && it.isPartial);
  if (index == -1) {
    if (event.messageId != null) return base;
    // Joined mid-stream without a message_start: open a live partial.
    list = [
      ...list,
      Message(
        id: _uniqueId(list, 'assistant-live', envelope),
        role: 'assistant',
        content: '',
        createdAt: now(),
        isPartial: true,
      ),
    ];
    index = list.length - 1;
  }
  return base.copyWith(
    messages: [
      for (final (position, message) in list.indexed)
        if (position != index)
          message
        else if (event.thinking)
          message.copyWith(
            thinking: (message.thinking ?? '') + event.delta,
            isPartial: true,
          )
        else
          message.copyWith(
            content: message.content + event.delta,
            isPartial: true,
          ),
    ],
  );
}

SessionState _completed(SessionState base, Message incoming) {
  final messages = base.messages;
  var index = messages.indexWhere((it) => it.id == incoming.id && it.isPartial);
  // Partials may lack timestamps; the newest partial assistant is the one ending.
  if (index == -1 && incoming.role == 'assistant') {
    index = messages.lastIndexWhere(
      (it) => it.role == 'assistant' && it.isPartial,
    );
  }
  if (index == -1) {
    if (messages.any((it) => it.id == incoming.id && !it.isPartial)) {
      // Delivered twice (replay after reconnect): keep the newest copy.
      return base.copyWith(
        messages: [
          for (final it in messages)
            it.id == incoming.id ? _withTools(incoming, it) : it,
        ],
      );
    }
    return base.copyWith(messages: _appendCompleted(messages, incoming));
  }
  final previous = messages[index];
  return base.copyWith(
    messages: [
      for (final (position, message) in messages.indexed)
        position == index
            ? _withTools(incoming, previous).copyWith(id: previous.id)
            : message,
    ],
  );
}

SessionState _tool(SessionState base, ToolUpdated event) {
  final messages = base.messages;
  final tool = event.tool;
  // A ptc operation goes under its ptc call.
  final parentId = tool.parentId;
  if (parentId != null) {
    final owner = messages.lastIndexWhere(
      (message) => message.tools.any((it) => it.id == parentId),
    );
    if (owner != -1) {
      return base.copyWith(
        messages: [
          for (final (position, message) in messages.indexed)
            position == owner
                ? message.copyWith(
                    tools: withOperation(message.tools, parentId, tool)!,
                  )
                : message,
        ],
      );
    }
  }
  var index = event.messageId != null
      ? messages.indexWhere((it) => it.id == event.messageId)
      : messages.lastIndexWhere(
          (message) => message.tools.any((it) => it.id == tool.id),
        );
  if (index == -1 && event.messageId == null) {
    index = messages.lastIndexWhere((it) => it.role == 'assistant');
  }
  if (index == -1) return base;
  return base.copyWith(
    messages: [
      for (final (position, message) in messages.indexed)
        position == index
            ? message.copyWith(tools: _upsertTool(message.tools, tool))
            : message,
    ],
  );
}

/// A notice raised while a turn streams goes above it: the partial is
/// replaced in place when it completes.
List<Message> _appendCompleted(List<Message> messages, Message incoming) {
  final last = messages.isEmpty ? null : messages.last;
  if (incoming.systemKind == 'notice' &&
      last != null &&
      last.role == 'assistant' &&
      last.isPartial) {
    return [...messages.sublist(0, messages.length - 1), incoming, last];
  }
  return [...messages, incoming];
}

List<ToolCall> _upsertTool(List<ToolCall> tools, ToolUpdate tool) =>
    tools.any((it) => it.id == tool.id)
    ? [for (final it in tools) it.id == tool.id ? mergeTool(it, tool) : it]
    : [...tools, mergeTool(null, tool)];

/// Carry live tool results onto the final message, which only knows the calls.
Message _withTools(Message incoming, Message previous) {
  if (previous.tools.isEmpty) return incoming;
  final known = {for (final tool in previous.tools) tool.id: tool};
  final tools = [
    for (final tool in incoming.tools)
      switch (known.remove(tool.id)) {
        final existing? => mergeTool(
          existing,
          asUpdate(tool).copyWith(status: existing.status),
        ),
        null => tool,
      },
  ];
  return incoming.copyWith(tools: [...tools, ...known.values]);
}

String _uniqueId(List<Message> messages, String id, EventEnvelope envelope) =>
    messages.any((it) => it.id == id) ? '$id-${envelope.cursor}' : id;
