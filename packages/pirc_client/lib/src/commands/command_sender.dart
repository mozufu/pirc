import 'dart:async';

import '../api_client.dart';
import '../errors.dart';
import '../json.dart';
import '../models/binding.dart';
import '../models/command.dart';
import '../models/control_lease.dart';
import '../transport/policy.dart';
import '../transport/transport.dart';
import 'ids.dart';

/// What became of a command.
sealed class CommandOutcome {
  const CommandOutcome(this.commandId);
  final String commandId;
}

/// 202: the node accepted the command.
class CommandAccepted extends CommandOutcome {
  CommandAccepted(this.command) : super(command.id);
  final Command command;
}

/// 200 `duplicate: true`: this command ID was already received; [command] is
/// the stored receipt.
class CommandDuplicate extends CommandOutcome {
  CommandDuplicate(this.command) : super(command.id);
  final Command command;
}

/// The command was refused and will not run.
class CommandRejected extends CommandOutcome {
  const CommandRejected(super.commandId, {this.command, this.error});
  final Command? command;
  final ApiError? error;
}

/// Nobody knows whether the command ran: a timeout, a connection dropped
/// after the request was sent, or 503 `outcome_unknown`. Resolve it only with
/// [CommandSender.resolve]; it is never sent again through another route (N8).
class CommandUncertain extends CommandOutcome {
  const CommandUncertain(this.sessionId, super.commandId, {this.cause});
  final String sessionId;
  final Object? cause;
}

/// The receipt route does not know the command: it was never received, so it
/// did not run. Sending it again with the same ID is safe.
class CommandNotReceived extends CommandOutcome {
  const CommandNotReceived(super.commandId);
}

/// Sends `POST /api/sessions/{id}/commands` with client-generated IDs.
class CommandSender {
  CommandSender(
    this.api, {
    this.timeout = const Duration(seconds: 20),
    String Function()? newId,
  }) : _newId = newId ?? randomId;

  final ApiClient api;
  final Duration timeout;
  final String Function() _newId;
  final _uncertain = <String>{};

  /// Command IDs whose outcome is not known yet.
  Set<String> get uncertain => Set.unmodifiable(_uncertain);

  static String _commands(String sessionId) =>
      '/api/sessions/${Uri.encodeComponent(sessionId)}/commands';

  /// Sends [payload] under the held [lease]. [binding] (`session.binding` from
  /// the snapshot) is required except for `stop` and `stop_transition`.
  /// Error replies from the gateway are thrown as typed [ApiError]s
  /// (e.g. [StaleEnvironment], [LostControl]); the command did not run.
  Future<CommandOutcome> send({
    required String sessionId,
    required CommandPayload payload,
    required ControlLease lease,
    ExpectedBinding? binding,
    String? commandId,
  }) async {
    if (payload.needsBinding && binding == null) {
      throw ArgumentError.value(
        binding,
        'binding',
        '`${payload.type}` needs the session binding; reload the session',
      );
    }
    final id = commandId ?? _newId();
    if (_uncertain.contains(id)) {
      throw StateError('Command $id has an unknown outcome; read its receipt');
    }
    final body = {
      'commandId': id,
      'clientId': lease.clientId,
      'generation': lease.generation,
      if (payload.needsBinding) 'expectedBinding': binding!.toJson(),
      'payload': payload.toJson(),
    };
    final ApiResponse response;
    try {
      response = await api.send(
        ApiRequest.post(_commands(sessionId), json: body),
        timeout: timeout,
      );
    } on TransportException catch (error) {
      _uncertain.add(id);
      return CommandUncertain(sessionId, id, cause: error);
    }
    return _classify(sessionId, id, response);
  }

  CommandOutcome _classify(String sessionId, String id, ApiResponse response) {
    final json = response.json();
    final raw = field(json, 'command');
    if (raw is Map) {
      final command = Command.fromJson(raw);
      if (response.status == 200 && field(json, 'duplicate') == true) {
        return _settle(CommandDuplicate(command));
      }
      if (response.ok && command.status == CommandStatus.accepted) {
        return _settle(CommandAccepted(command));
      }
      if (command.status == CommandStatus.rejected) {
        return _settle(CommandRejected(id, command: command));
      }
      // 503 with outcome_unknown, or still received/dispatched.
      _uncertain.add(id);
      return CommandUncertain(sessionId, id, cause: command.status);
    }
    final error = errorFor(response);
    if (error == null ||
        (response.status >= 500 && error.code == 'http_${response.status}')) {
      // A 2xx without a receipt, or a proxy's 5xx: the gateway may have acted.
      _uncertain.add(id);
      return CommandUncertain(sessionId, id, cause: error);
    }
    _uncertain.remove(id);
    throw error;
  }

  CommandOutcome _settle(CommandOutcome outcome) {
    _uncertain.remove(outcome.commandId);
    return outcome;
  }

  /// Reads `GET /api/sessions/{id}/commands/{commandId}`: the only way an
  /// uncertain command is resolved. Returns [CommandUncertain] while the
  /// gateway still does not know.
  Future<CommandOutcome> resolve(String sessionId, String commandId) async {
    final ApiResponse response;
    try {
      response = await api.send(
        ApiRequest.get(
          '${_commands(sessionId)}/${Uri.encodeComponent(commandId)}',
        ),
      );
    } on TransportException catch (error) {
      return CommandUncertain(sessionId, commandId, cause: error);
    }
    if (response.status == 404) {
      _uncertain.remove(commandId);
      return CommandNotReceived(commandId);
    }
    final command = Command.fromJson(
      field(checked(response).json(), 'command'),
    );
    return switch (command.status) {
      CommandStatus.accepted => _settle(CommandAccepted(command)),
      CommandStatus.rejected => _settle(
        CommandRejected(commandId, command: command),
      ),
      _ => CommandUncertain(sessionId, commandId, cause: command.status),
    };
  }
}
