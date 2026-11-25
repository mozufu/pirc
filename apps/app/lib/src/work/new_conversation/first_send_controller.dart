import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../../connection/storage.dart';
import '../composer/attachments.dart';
import '../session_controller.dart';

enum FirstSendPhase {
  idle,
  sending,

  /// "Not sure it arrived": only "Check status" (the receipt) resolves it.
  uncertain,

  /// The node refused the first message; "Send again" is a separate action.
  refused,

  /// It was never dispatched (a failure before the send); sending again is
  /// safe and uses the same operation.
  notSent,

  /// Admitted: the conversation exists and opens.
  done,
}

@immutable
class FirstSendState {
  const FirstSendState({
    this.phase = FirstSendPhase.idle,
    this.operationId,
    this.sessionId,
    this.workspaceId,
    this.message = '',
    this.commandId,
    this.retryEligible = false,
    this.error,
  });

  final FirstSendPhase phase;
  final String? operationId;
  final String? sessionId;
  final String? workspaceId;
  final String message;

  /// The refused first message's command, for "Send again".
  final String? commandId;
  final bool retryEligible;
  final String? error;

  Map<String, Object?> toJson() => {
    'operationId': operationId,
    'sessionId': sessionId,
    'workspaceId': workspaceId,
    'message': message,
  };
}

/// The phase a preparation is in, as the screen shows it.
FirstSendPhase phaseOf(Preparation preparation) => switch (preparation.state) {
  'admitted' => FirstSendPhase.done,
  'admission_failed' || 'stopped' || 'cancelled' => FirstSendPhase.refused,
  'outcome_unknown' || 'sending' || 'stopping' => FirstSendPhase.uncertain,
  _ => FirstSendPhase.notSent,
};

final firstSendProvider = NotifierProvider<FirstSendController, FirstSendState>(
  FirstSendController.new,
);

/// Creates a conversation with `FirstSendClient.send`. A journal in app
/// storage lets the app check an open operation after a restart.
class FirstSendController extends Notifier<FirstSendState> {
  @override
  FirstSendState build() {
    final raw = ref
        .read(sharedPreferencesProvider)
        .getString(PrefKeys.firstSendJournal);
    if (raw == null) return const FirstSendState();
    final json = jsonDecode(raw);
    if (json is! Map || json['operationId'] is! String) {
      return const FirstSendState();
    }
    // An operation was open when the app stopped: check it, never resend.
    scheduleMicrotask(checkStatus);
    return FirstSendState(
      phase: FirstSendPhase.uncertain,
      operationId: json['operationId'] as String,
      sessionId: json['sessionId'] as String?,
      workspaceId: json['workspaceId'] as String?,
      message: json['message'] as String? ?? '',
    );
  }

  FirstSendClient? get _client {
    final api = ref.read(apiProvider);
    return api == null ? null : FirstSendClient(api);
  }

  void _journal(FirstSendState next) {
    state = next;
    final prefs = ref.read(sharedPreferencesProvider);
    if (next.operationId == null ||
        next.phase == FirstSendPhase.done ||
        next.phase == FirstSendPhase.idle) {
      prefs.remove(PrefKeys.firstSendJournal);
    } else {
      prefs.setString(PrefKeys.firstSendJournal, jsonEncode(next.toJson()));
    }
  }

  FirstSendState _from(Preparation preparation, {String? error}) {
    final admission = preparation.messageAdmission;
    return FirstSendState(
      phase: phaseOf(preparation),
      operationId: preparation.operationId,
      sessionId: preparation.sessionId ?? state.sessionId,
      workspaceId: preparation.workspaceId ?? state.workspaceId,
      message: state.message,
      commandId: admission?.commandId,
      retryEligible: admission?.retryEligible ?? false,
      error: error,
    );
  }

  /// prepare → upload → accept → materialize → lease → dispatch.
  Future<void> send({
    required String workspaceId,
    required String message,
    ModelInfo? model,
    String? thinking,
    List<PendingAttachment> attachments = const [],
  }) async {
    final client = _client;
    if (client == null || state.phase == FirstSendPhase.sending) return;
    // After "not sent" the same operation is sent again: prepare is
    // idempotent and nothing was dispatched.
    final operationId = state.phase == FirstSendPhase.notSent
        ? state.operationId ?? FirstSendClient.newOperationId()
        : FirstSendClient.newOperationId();
    _journal(
      FirstSendState(
        phase: FirstSendPhase.sending,
        operationId: operationId,
        workspaceId: workspaceId,
        message: message,
      ),
    );
    try {
      final outcome = await client.send(
        operationId: operationId,
        clientId: ref.read(clientIdProvider),
        submission: Submission(
          workspaceId: workspaceId,
          message: message,
          modelProvider: model?.provider,
          modelId: model?.id,
          thinking: thinking,
          attachments: [for (final a in attachments) a.declaration],
        ),
        attachments: {for (final a in attachments) a.id: a.bytes},
      );
      switch (outcome) {
        case FirstSendDispatched(:final preparation):
          _journal(_from(preparation));
        case FirstSendUncertain(:final sessionId):
          _journal(
            FirstSendState(
              phase: FirstSendPhase.uncertain,
              operationId: operationId,
              sessionId: sessionId,
              workspaceId: workspaceId,
              message: message,
            ),
          );
      }
    } on PircException catch (error) {
      if (ref.read(connectionProvider.notifier).report(error)) return;
      _journal(
        FirstSendState(
          phase: FirstSendPhase.notSent,
          operationId: operationId,
          workspaceId: workspaceId,
          message: message,
          error: error.message,
        ),
      );
    }
  }

  /// "Check status": reads the admission receipt; never resends.
  Future<void> checkStatus() async {
    final client = _client;
    final operationId = state.operationId;
    if (client == null || operationId == null) return;
    try {
      _journal(_from(await client.receipt(operationId)));
    } on ApiError catch (error) {
      if (error.status == 404) {
        // The Gateway never prepared it: nothing was created or sent.
        _journal(
          FirstSendState(
            phase: FirstSendPhase.notSent,
            workspaceId: state.workspaceId,
            message: state.message,
          ),
        );
      } else {
        state = FirstSendState(
          phase: state.phase,
          operationId: operationId,
          sessionId: state.sessionId,
          workspaceId: state.workspaceId,
          message: state.message,
          error: error.message,
        );
      }
    } on PircException catch (error) {
      ref.read(connectionProvider.notifier).report(error);
    }
  }

  /// "Send again" after a refusal: a new retry of the refused command.
  Future<void> sendAgain() async {
    final client = _client;
    final operationId = state.operationId;
    final sessionId = state.sessionId;
    final commandId = state.commandId;
    if (client == null ||
        operationId == null ||
        sessionId == null ||
        commandId == null) {
      return;
    }
    state = _copy(FirstSendPhase.sending);
    try {
      final lease = await client.control.acquire(
        sessionId,
        clientId: ref.read(clientIdProvider),
      );
      _journal(
        _from(
          await client.retry(
            operationId,
            retryId: randomId(),
            previousCommandId: commandId,
            lease: lease,
          ),
        ),
      );
    } on TransportException {
      _journal(_copy(FirstSendPhase.uncertain));
    } on PircException catch (error) {
      if (ref.read(connectionProvider.notifier).report(error)) return;
      state = _copy(FirstSendPhase.refused, error: error.message);
    }
  }

  FirstSendState _copy(FirstSendPhase phase, {String? error}) => FirstSendState(
    phase: phase,
    operationId: state.operationId,
    sessionId: state.sessionId,
    workspaceId: state.workspaceId,
    message: state.message,
    commandId: state.commandId,
    retryEligible: state.retryEligible,
    error: error,
  );

  /// Back to an empty draft once the conversation opened.
  void reset() => _journal(const FirstSendState());
}
