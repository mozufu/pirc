/// `/api/events` messages as timeline events; a port of the web's
/// `normalizeEvent` (`api.ts`) through `core/timeline/Events.kt`.
library;

import '../json.dart';
import 'pi_messages.dart';
import 'snapshot_state.dart' show chatDelegations;
import 'types.dart';

sealed class TimelineEvent {
  const TimelineEvent();
}

class MessageStarted extends TimelineEvent {
  const MessageStarted(this.message);
  final Message message;
}

/// [messageId] null: applies to the newest partial assistant message.
class MessageDelta extends TimelineEvent {
  const MessageDelta(this.delta, {required this.thinking, this.messageId});
  final String delta;
  final bool thinking;
  final String? messageId;
}

class MessageCompleted extends TimelineEvent {
  const MessageCompleted(this.message);
  final Message message;
}

class ToolUpdated extends TimelineEvent {
  const ToolUpdated(this.tool, {this.messageId});
  final ToolUpdate tool;
  final String? messageId;
}

class QueueUpdated extends TimelineEvent {
  const QueueUpdated(this.queue);
  final List<QueueItem> queue;
}

class WidgetUpdated extends TimelineEvent {
  const WidgetUpdated(this.key, this.lines);
  final String key;
  final List<String>? lines;
}

class StatusUpdated extends TimelineEvent {
  const StatusUpdated(this.key, this.text);
  final String key;
  final String? text;
}

class ApprovalModeChanged extends TimelineEvent {
  const ApprovalModeChanged(this.mode);
  final String mode;
}

class SessionRenamed extends TimelineEvent {
  const SessionRenamed(this.name);
  final String name;
}

/// The chat's full list of running/waiting delegations.
class DelegationsChanged extends TimelineEvent {
  const DelegationsChanged(this.delegations);
  final List<ChatDelegation> delegations;
}

/// The session was deleted; terminal, and never triggers a snapshot refetch.
class SessionDeleted extends TimelineEvent {
  const SessionDeleted();
}

/// Side-panel data changed (memory, background, team, git); refetch lazily.
class PanelChanged extends TimelineEvent {
  const PanelChanged(this.sections);
  final List<String> sections;
}

/// A session's observational checkpoints changed; refresh that panel lazily.
class CheckpointsChanged extends TimelineEvent {
  const CheckpointsChanged();
}

/// Only a new snapshot can tell what changed.
class Reset extends TimelineEvent {
  const Reset(this.reason);
  final String reason;
}

class Noop extends TimelineEvent {
  const Noop();
}

/// One normalized `/api/events` message.
class EventEnvelope {
  const EventEnvelope({
    required this.sessionId,
    required this.runnerEpoch,
    required this.sequence,
    required this.cursor,
    required this.event,
  });

  final String sessionId;
  final String runnerEpoch;
  final int sequence;
  final String cursor;
  final TimelineEvent event;

  EventEnvelope copyWith({String? runnerEpoch}) => EventEnvelope(
    sessionId: sessionId,
    runnerEpoch: runnerEpoch ?? this.runnerEpoch,
    sequence: sequence,
    cursor: cursor,
    event: event,
  );
}

/// Events that change run/runner state only a snapshot reports accurately.
const _snapshotEvents = {
  'interaction_created',
  'interaction_answered',
  'runner_ready',
  'runner_error',
  'runner_exit',
  'node_offline',
  'node_reconnected',
};

/// Agent lifecycle events that change run status.
const _runEvents = {'agent_start', 'agent_end', 'agent_settled'};

const thinkingLevels = {'off', 'minimal', 'low', 'medium', 'high', 'xhigh'};
const approvalModes = {'read-only', 'auto', 'full-access'};

List<QueueItem> queueItems(Object? steering, Object? followUp) => [
  for (final (index, item) in (array(steering) ?? const []).indexed)
    QueueItem('steer-$index', 'steer', text(item) ?? '', index),
  for (final (index, item) in (array(followUp) ?? const []).indexed)
    QueueItem('follow-$index', 'follow_up', text(item) ?? '', index),
];

TimelineEvent _piEvent(Object? pi, Object? timestamp, Now now) {
  switch (str(field(pi, 'type'))) {
    case 'message_start':
      final message = field(pi, 'message');
      if (str(field(message, 'role')) != 'assistant') return const Noop();
      final parsed = piMessage(message, now: now);
      return parsed == null
          ? const Noop()
          : MessageStarted(parsed.copyWith(isPartial: true));
    case 'message_update':
      final delta = field(pi, 'assistantMessageEvent');
      final type = str(field(delta, 'type'));
      switch (type) {
        case 'text_delta' || 'thinking_delta':
          return MessageDelta(
            text(field(delta, 'delta')) ?? '',
            thinking: type == 'thinking_delta',
          );
        case 'toolcall_start':
          final id = field(delta, 'id');
          if (!truthy(id)) return const Noop();
          return ToolUpdated(
            ToolUpdate(
              text(id)!,
              name: text(field(delta, 'toolName')) ?? 'tool',
              status: 'running',
            ),
          );
        case 'toolcall_end':
          final call = field(delta, 'toolCall');
          final id = field(call, 'id');
          if (!truthy(id)) return const Noop();
          return ToolUpdated(
            ToolUpdate(
              text(id)!,
              name: text(field(call, 'name')) ?? 'tool',
              input: field(call, 'arguments'),
              status: 'running',
            ),
          );
        default:
          return const Noop();
      }
    case 'message_end':
      final raw = field(pi, 'message');
      if (str(field(raw, 'role')) == 'toolResult') {
        final id = text(field(raw, 'toolCallId')) ?? 'undefined';
        return ToolUpdated(
          toolResultFields(raw, id).copyWith(
            name: text(field(raw, 'toolName')),
            status: truthy(field(raw, 'isError')) ? 'failed' : 'succeeded',
          ),
        );
      }
      final message = piMessage(raw, now: now);
      return message == null ? const Noop() : MessageCompleted(message);
    case 'tool_execution_start':
      return ToolUpdated(
        ToolUpdate(
          text(field(pi, 'toolCallId')) ?? 'undefined',
          name: text(field(pi, 'toolName')),
          input: field(pi, 'args'),
          status: 'running',
          startedAt: at(timestamp, now),
          parentId: str(field(pi, 'parentToolCallId')),
        ),
      );
    case 'tool_execution_update':
      return ToolUpdated(
        toolResultFields(
          field(pi, 'partialResult'),
          text(field(pi, 'toolCallId')) ?? 'undefined',
        ).copyWith(parentId: str(field(pi, 'parentToolCallId'))),
      );
    case 'tool_execution_end':
      return ToolUpdated(
        toolResultFields(
          field(pi, 'result'),
          text(field(pi, 'toolCallId')) ?? 'undefined',
        ).copyWith(
          name: text(field(pi, 'toolName')),
          status: truthy(field(pi, 'isError')) ? 'failed' : 'succeeded',
          endedAt: at(timestamp, now),
          parentId: str(field(pi, 'parentToolCallId')),
        ),
      );
    case 'queue_update':
      return QueueUpdated(
        queueItems(field(pi, 'steering'), field(pi, 'followUp')),
      );
    case 'panel_changed':
      return PanelChanged([
        for (final item in array(field(pi, 'sections')) ?? const [])
          text(item) ?? 'null',
      ]);
    case 'approval_mode_changed':
      final mode = text(field(pi, 'mode'));
      return mode != null && approvalModes.contains(mode)
          ? ApprovalModeChanged(mode)
          : const Noop();
    case final type:
      return _runEvents.contains(type)
          ? const Reset('cursor_expired')
          : const Noop();
  }
}

/// One `/api/events` message (decoded JSON) as an [EventEnvelope].
EventEnvelope normalizeEvent(Object? raw, {Now now = systemNow}) {
  final type = str(field(raw, 'type'));
  final data = field(raw, 'data');
  final TimelineEvent event;
  if (type == 'reset') {
    event = Reset(text(field(raw, 'reason')) ?? 'cursor_expired');
  } else if (type == 'pi_event') {
    event = _piEvent(data ?? const {}, field(raw, 'timestamp'), now);
  } else if (type == 'notification') {
    event = switch (str(field(data, 'method'))) {
      'notify' => MessageCompleted(
        piNotification({
          ...?object(data),
          'receivedAt': field(raw, 'timestamp'),
        }, now: now),
      ),
      'setWidget' => WidgetUpdated(
        text(field(data, 'widgetKey')) ?? '',
        array(
          field(data, 'widgetLines'),
        )?.map((it) => text(it) ?? 'null').toList(),
      ),
      'setStatus' => StatusUpdated(
        text(field(data, 'statusKey')) ?? '',
        str(field(data, 'statusText')),
      ),
      _ => const Noop(),
    };
  } else if (type == 'session_renamed' && str(field(data, 'name')) != null) {
    event = SessionRenamed(str(field(data, 'name'))!);
  } else if (type == 'session_deleted') {
    event = const SessionDeleted();
  } else if (type == 'checkpoints_changed') {
    event = const CheckpointsChanged();
  } else if (type == 'delegations_changed' &&
      array(field(data, 'delegations')) != null) {
    event = DelegationsChanged(chatDelegations(field(data, 'delegations')));
  } else if (type == 'runner_stderr') {
    event = const Noop();
  } else if (_snapshotEvents.contains(type)) {
    event = const Reset('cursor_expired');
  } else {
    event = const Reset('epoch_changed');
  }
  final epoch = text(field(raw, 'epoch')) ?? '0';
  return EventEnvelope(
    sessionId: text(field(raw, 'sessionId')) ?? '',
    runnerEpoch: epoch,
    sequence: number(field(raw, 'sequence')) ?? 0,
    cursor: '$epoch:${text(field(raw, 'sequence')) ?? '0'}',
    event: event,
  );
}
