/// The chat timeline, ported from the web client (`apps/web/src/lib/types.ts`).
/// Timestamps are epoch milliseconds. The shared fixtures in `fixtures/timeline`
/// pin this port to the web implementation; change them together.
library;

import '../known_text.dart';
import '../models/session.dart';

/// An image inline in a message or tool result; [base64] is the raw data.
class InlineImage {
  const InlineImage(this.mimeType, this.base64);
  final String mimeType;
  final String base64;
}

class ToolCall {
  const ToolCall({
    required this.id,
    required this.name,
    this.title,
    this.status = 'running',
    this.input,
    this.output,
    this.diff,
    this.images = const [],
    this.startedAt,
    this.endedAt,
    this.recording,
    this.operations = const [],
  });

  final String id;
  final String name;
  final String? title;

  /// `running`, `succeeded` or `failed`.
  final String status;

  /// Decoded JSON arguments.
  final Object? input;
  final String? output;

  /// Unified diff reported by edit-style tools.
  final String? diff;
  final List<InlineImage> images;
  final int? startedAt;
  final int? endedAt;

  /// A saved browser recording, relative to the session's workspace.
  final String? recording;

  /// The operations a `ptc` call ran, in start order.
  final List<ToolCall> operations;

  /// `null` arguments keep the current value.
  ToolCall copyWith({
    String? id,
    String? name,
    String? title,
    String? status,
    Object? input,
    String? output,
    String? diff,
    List<InlineImage>? images,
    int? startedAt,
    int? endedAt,
    String? recording,
    List<ToolCall>? operations,
  }) => ToolCall(
    id: id ?? this.id,
    name: name ?? this.name,
    title: title ?? this.title,
    status: status ?? this.status,
    input: input ?? this.input,
    output: output ?? this.output,
    diff: diff ?? this.diff,
    images: images ?? this.images,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    recording: recording ?? this.recording,
    operations: operations ?? this.operations,
  );
}

/// Fields of a tool that an event changes; `null` keeps the current value.
class ToolUpdate {
  const ToolUpdate(
    this.id, {
    this.name,
    this.title,
    this.status,
    this.input,
    this.output,
    this.diff,
    this.images,
    this.startedAt,
    this.endedAt,
    this.recording,
    this.parentId,
  });

  final String id;
  final String? name;
  final String? title;
  final String? status;
  final Object? input;
  final String? output;
  final String? diff;
  final List<InlineImage>? images;
  final int? startedAt;
  final int? endedAt;
  final String? recording;

  /// A `ptc` operation: the `ptc` call it ran in, to nest it there.
  final String? parentId;

  /// `null` arguments keep the current value.
  ToolUpdate copyWith({
    String? name,
    String? status,
    Object? input,
    int? startedAt,
    int? endedAt,
    String? parentId,
  }) => ToolUpdate(
    id,
    name: name ?? this.name,
    title: title,
    status: status ?? this.status,
    input: input ?? this.input,
    output: output,
    diff: diff,
    images: images,
    startedAt: startedAt ?? this.startedAt,
    endedAt: endedAt ?? this.endedAt,
    recording: recording,
    parentId: parentId ?? this.parentId,
  );

  /// The same update without [parentId].
  ToolUpdate withoutParent() => ToolUpdate(
    id,
    name: name,
    title: title,
    status: status,
    input: input,
    output: output,
    diff: diff,
    images: images,
    startedAt: startedAt,
    endedAt: endedAt,
    recording: recording,
  );
}

class MessageBranch {
  const MessageBranch(this.entryId, this.text, this.selected);
  final String entryId;
  final String text;
  final bool selected;
}

class Message {
  const Message({
    required this.id,
    required this.role,
    required this.content,
    required this.createdAt,
    this.completedAt,
    this.isPartial = false,
    this.thinking,
    this.thinkingRedacted = false,
    this.stopReason,
    this.errorMessage,
    this.model,
    this.tools = const [],
    this.images = const [],
    this.systemKind,
    this.level,
    this.label,
    this.meta,
    this.entryId,
    this.branches = const [],
    this.pot,
  });

  final String id;

  /// `user`, `assistant` or `system`.
  final String role;
  final String content;
  final int createdAt;

  /// When a streamed assistant message finished; orders notices raised meanwhile.
  final int? completedAt;
  final bool isPartial;
  final String? thinking;
  final bool thinkingRedacted;

  /// `error` or `aborted` when the turn did not finish normally.
  final String? stopReason;
  final String? errorMessage;
  final String? model;
  final List<ToolCall> tools;
  final List<InlineImage> images;

  /// For system entries: notice, compaction, branch, bash, custom, team,
  /// background, pot-instruction.
  final String? systemKind;

  /// For notices and bash runs: info, warning, error.
  final String? level;
  final String? label;
  final String? meta;
  final String? entryId;
  final List<MessageBranch> branches;

  /// For `pot-instruction` entries: which pot sent the instruction, from the
  /// message's `details` (never from its text).
  final PotInstruction? pot;

  /// `null` arguments keep the current value.
  Message copyWith({
    String? id,
    String? content,
    bool? isPartial,
    String? thinking,
    List<ToolCall>? tools,
  }) => Message(
    id: id ?? this.id,
    role: role,
    content: content ?? this.content,
    createdAt: createdAt,
    completedAt: completedAt,
    isPartial: isPartial ?? this.isPartial,
    thinking: thinking ?? this.thinking,
    thinkingRedacted: thinkingRedacted,
    stopReason: stopReason,
    errorMessage: errorMessage,
    model: model,
    tools: tools ?? this.tools,
    images: images,
    systemKind: systemKind,
    level: level,
    label: label,
    meta: meta,
    entryId: entryId,
    branches: branches,
    pot: pot,
  );
}

/// The sender of a `pot-instruction` message (`details` of the message).
class PotInstruction {
  const PotInstruction({
    required this.potId,
    required this.potName,
    this.workId,
    this.instructionId,
  });

  final String potId;
  final String potName;
  final String? workId;
  final String? instructionId;
}

class RunState {
  const RunState({
    this.id,
    required this.status,
    this.startedAt,
    this.endedAt,
    this.failureReason,
  });
  final String? id;
  final String status;
  final int? startedAt;
  final int? endedAt;
  final String? failureReason;
}

/// [index] counts the messages of its queue; `send_now` addresses one by it.
class QueueItem {
  const QueueItem(this.id, this.kind, this.content, this.index);
  final String id;

  /// `steer` or `follow_up`.
  final String kind;
  final String content;
  final int index;
}

class InteractionOption {
  const InteractionOption(
    this.value,
    this.label, [
    this.description,
    this.other = false,
  ]);
  final String value;
  final String label;
  final String? description;

  /// The agent's "Other" option ([askOtherLabel]), shown in the app's words;
  /// [value] stays the answer.
  final bool other;
}

/// Optional checkbox on a confirmation, used for delegated user requests.
class UserRequestChoice {
  const UserRequestChoice(this.label, this.checked);
  final String label;
  final bool checked;
}

/// Where a relayed (`relay.`) confirm comes from.
class RelayedFrom {
  const RelayedFrom({
    required this.sessionId,
    required this.sessionName,
    required this.workspace,
    required this.delegationId,
  });
  final String sessionId;
  final String sessionName;
  final String workspace;
  final String delegationId;
}

/// A running or waiting delegation a chat started.
class ChatDelegation {
  const ChatDelegation({
    required this.id,
    required this.title,
    required this.workspace,
    required this.status,
    required this.dispatch,
    required this.targetSessionId,
  });
  final String id;
  final String title;

  /// Label `repo on node`.
  final String workspace;

  /// `running` or `waiting_input`.
  final String status;

  /// `auto` or `approved`.
  final String dispatch;
  final String targetSessionId;
}

/// Relayed interactions need no control lease.
const relayInteractionPrefix = 'relay.';
bool isRelayedInteraction(String id) => id.startsWith(relayInteractionPrefix);

class Interaction {
  const Interaction({
    required this.id,
    required this.runnerEpoch,
    this.toolCallId,
    required this.kind,
    required this.title,
    this.description,
    this.expiresAt,
    this.status = 'pending',
    this.statusKnown = true,
    this.answeredBy,
    this.resolvedAt,
    this.options = const [],
    this.multiple = false,
    this.placeholder,
    this.initialValue,
    this.confirmLabel,
    this.cancelLabel,
    this.modelChoice,
    this.language,
    this.userRequestChoice,
    this.relayed,
  });

  final String id;
  final String runnerEpoch;

  /// The `ptc` operation that asks; null for anything else.
  final String? toolCallId;

  /// `select`, `confirm`, `input` or `editor`.
  final String kind;
  final String title;
  final String? description;
  final int? expiresAt;

  /// `pending`, `answered`, `cancelled`, `expired` or `stale`.
  final String status;

  /// False on an older snapshot that did not say; such a pending question
  /// gets only a neutral fallback when it disappears.
  final bool statusKnown;

  /// The `clientId` that answered; only for `answered`.
  final String? answeredBy;

  /// When the question ended (answered, cancelled, stale or expiry).
  final int? resolvedAt;
  final List<InteractionOption> options;
  final bool multiple;
  final String? placeholder;
  final String? initialValue;
  final String? confirmLabel;
  final String? cancelLabel;
  final Map<String, Object?>? modelChoice;
  final String? language;
  final UserRequestChoice? userRequestChoice;
  final RelayedFrom? relayed;

  /// The end an `interaction_answered` event reports.
  Interaction copyWith({
    String? status,
    bool? statusKnown,
    String? answeredBy,
    int? resolvedAt,
  }) => Interaction(
    id: id,
    runnerEpoch: runnerEpoch,
    toolCallId: toolCallId,
    kind: kind,
    title: title,
    description: description,
    expiresAt: expiresAt,
    status: status ?? this.status,
    statusKnown: statusKnown ?? this.statusKnown,
    answeredBy: answeredBy ?? this.answeredBy,
    resolvedAt: resolvedAt ?? this.resolvedAt,
    options: options,
    multiple: multiple,
    placeholder: placeholder,
    initialValue: initialValue,
    confirmLabel: confirmLabel,
    cancelLabel: cancelLabel,
    modelChoice: modelChoice,
    language: language,
    userRequestChoice: userRequestChoice,
    relayed: relayed,
  );
}

/// Whether an agent runs inside its node's OS sandbox, and why not.
class SandboxStatus {
  const SandboxStatus(this.active, [this.reason]);
  final bool active;
  final String? reason;
}

/// One session as a client sees it: snapshot plus every event applied since.
class SessionState {
  const SessionState({
    required this.session,
    required this.runnerStatus,
    required this.run,
    required this.messages,
    required this.interactions,
    required this.queue,
    required this.cursor,
    required this.runnerEpoch,
    this.selectedModelId,
    this.selectedModelProvider,
    this.thinkingLevel,
    this.approvalMode,
    this.defaultApprovalMode,
    this.widgets = const {},
    this.statuses = const {},
    this.sandbox,
    this.delegations = const [],
    this.needsSnapshot = false,
  });

  final Session session;
  final String runnerStatus;
  final RunState? run;
  final List<Message> messages;
  final List<Interaction> interactions;
  final List<QueueItem> queue;

  /// `<epoch>:<sequence>` of the last applied event (or the snapshot watermark).
  final String cursor;
  final String runnerEpoch;
  final String? selectedModelId;
  final String? selectedModelProvider;
  final String? thinkingLevel;
  final String? approvalMode;
  final String? defaultApprovalMode;
  final Map<String, List<String>> widgets;
  final Map<String, String> statuses;
  final SandboxStatus? sandbox;
  final List<ChatDelegation> delegations;

  /// The events can no longer be applied (epoch changed, reset): fetch a new snapshot.
  final bool needsSnapshot;

  /// `null` arguments keep the current value.
  SessionState copyWith({
    Session? session,
    List<Message>? messages,
    List<Interaction>? interactions,
    List<QueueItem>? queue,
    String? cursor,
    String? approvalMode,
    Map<String, List<String>>? widgets,
    Map<String, String>? statuses,
    List<ChatDelegation>? delegations,
    bool? needsSnapshot,
  }) => SessionState(
    session: session ?? this.session,
    runnerStatus: runnerStatus,
    run: run,
    messages: messages ?? this.messages,
    interactions: interactions ?? this.interactions,
    queue: queue ?? this.queue,
    cursor: cursor ?? this.cursor,
    runnerEpoch: runnerEpoch,
    selectedModelId: selectedModelId,
    selectedModelProvider: selectedModelProvider,
    thinkingLevel: thinkingLevel,
    approvalMode: approvalMode ?? this.approvalMode,
    defaultApprovalMode: defaultApprovalMode,
    widgets: widgets ?? this.widgets,
    statuses: statuses ?? this.statuses,
    sandbox: sandbox,
    delegations: delegations ?? this.delegations,
    needsSnapshot: needsSnapshot ?? this.needsSnapshot,
  );
}
