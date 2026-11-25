import 'package:meta/meta.dart';

import '../json.dart';

/// Where a command is in the gateway: `received`, `dispatched`, `accepted`,
/// `rejected` or `outcome_unknown`.
enum CommandStatus {
  received('received'),
  dispatched('dispatched'),
  accepted('accepted'),
  rejected('rejected'),
  outcomeUnknown('outcome_unknown'),

  /// A status this client does not know.
  unknown('');

  const CommandStatus(this.wire);
  final String wire;

  static CommandStatus parse(Object? value) => values.firstWhere(
    (it) => it != unknown && it.wire == value,
    orElse: () => unknown,
  );
}

/// The payload types that need no `expectedBinding`.
const unboundCommandTypes = {'stop', 'stop_transition'};

/// A command receipt (`{command}` from the commands routes).
@immutable
class Command {
  const Command({
    required this.id,
    required this.sessionId,
    this.payloadHash,
    this.payload,
    required this.status,
    this.result,
    this.error,
  });

  factory Command.fromJson(Object? json) => Command(
    id: text(field(json, 'id')) ?? '',
    sessionId: text(field(json, 'sessionId')) ?? '',
    payloadHash: str(field(json, 'payloadHash')),
    payload: object(field(json, 'payload')),
    status: CommandStatus.parse(field(json, 'status')),
    result: field(json, 'result'),
    error: field(json, 'error'),
  );

  final String id;
  final String sessionId;
  final String? payloadHash;
  final Map<String, Object?>? payload;
  final CommandStatus status;
  final Object? result;
  final Object? error;
}

/// A command payload `{type, ...}`. Helpers build the documented types.
@immutable
class CommandPayload {
  const CommandPayload(this.type, [this.fields = const {}]);

  factory CommandPayload.prompt(String message, {List<String>? uploadIds}) =>
      CommandPayload('prompt', {'message': message, 'uploadIds': ?uploadIds});
  factory CommandPayload.steer(String message, {List<String>? uploadIds}) =>
      CommandPayload('steer', {'message': message, 'uploadIds': ?uploadIds});
  factory CommandPayload.followUp(String message, {List<String>? uploadIds}) =>
      CommandPayload('follow_up', {
        'message': message,
        'uploadIds': ?uploadIds,
      });
  factory CommandPayload.editMessage(String entryId, String message) =>
      CommandPayload('edit_message', {'entryId': entryId, 'message': message});
  factory CommandPayload.switchBranch(String entryId) =>
      CommandPayload('switch_branch', {'entryId': entryId});
  factory CommandPayload.stop() => const CommandPayload('stop');
  factory CommandPayload.stopTransition(String operationId, String planHash) =>
      CommandPayload('stop_transition', {
        'operationId': operationId,
        'planHash': planHash,
      });
  factory CommandPayload.clearQueue() => const CommandPayload('clear_queue');
  factory CommandPayload.sendNow(String queue, int index, String message) =>
      CommandPayload('send_now', {
        'queue': queue,
        'index': index,
        'message': message,
      });
  factory CommandPayload.setModel(String provider, String modelId) =>
      CommandPayload('set_model', {'provider': provider, 'modelId': modelId});
  factory CommandPayload.setThinking(String level) =>
      CommandPayload('set_thinking', {'level': level});
  factory CommandPayload.setApprovalMode(String mode) =>
      CommandPayload('set_approval_mode', {'mode': mode});

  final String type;
  final Map<String, Object?> fields;

  /// Whether the gateway requires `expectedBinding` with this payload.
  bool get needsBinding => !unboundCommandTypes.contains(type);

  Map<String, Object?> toJson() => {...fields, 'type': type};
}
