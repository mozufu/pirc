import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../../connection/connection.dart';
import '../../connection/data.dart';
import '../../connection/storage.dart';
import '../session_controller.dart';
import 'attachments.dart';
import 'model_sheet.dart';

/// Where a message goes while a run is active: `steer` (into the current
/// turn) or `follow_up` (after it).
enum SendWhen { steer, followUp }

/// A command whose outcome is not known ("Not sure it arrived").
@immutable
class UncertainSend {
  const UncertainSend(this.commandId, this.text);
  final String commandId;

  /// The text that may have been sent; it returns to the draft only when
  /// the Gateway says the command never arrived.
  final String text;
}

@immutable
class ComposerState {
  const ComposerState({
    this.draft = '',
    this.when = SendWhen.steer,
    this.attachments = const [],
    this.sending = false,
    this.uncertain,
    this.checking = false,
    this.error,
  });

  final String draft;
  final SendWhen when;
  final List<PendingAttachment> attachments;
  final bool sending;
  final UncertainSend? uncertain;
  final bool checking;

  /// The last refusal, shown under the composer.
  final String? error;

  ComposerState copyWith({
    String? draft,
    SendWhen? when,
    List<PendingAttachment>? attachments,
    bool? sending,
    UncertainSend? uncertain,
    bool clearUncertain = false,
    bool? checking,
    String? error,
    bool clearError = false,
  }) => ComposerState(
    draft: draft ?? this.draft,
    when: when ?? this.when,
    attachments: attachments ?? this.attachments,
    sending: sending ?? this.sending,
    uncertain: clearUncertain ? null : uncertain ?? this.uncertain,
    checking: checking ?? this.checking,
    error: clearError ? null : error ?? this.error,
  );
}

final composerProvider = NotifierProvider.autoDispose
    .family<ComposerController, ComposerState, String>(ComposerController.new);

/// Sends commands for one session through `CommandSender` with
/// `session.binding`. Drafts are kept per session in app storage and are
/// never sent automatically; an uncertain command is resolved only with
/// "Check status" and never sent again (N8).
class ComposerController extends Notifier<ComposerState> {
  ComposerController(this.sessionId);

  final String sessionId;
  CommandSender? _sender;

  /// A send is taking control or asking first; it has not started uploading.
  bool _preparing = false;

  String get _draftKey => '${PrefKeys.draftPrefix}$sessionId';

  @override
  ComposerState build() {
    final api = ref.watch(apiProvider);
    _sender = api == null ? null : CommandSender(api);
    final saved = ref.read(sharedPreferencesProvider).getString(_draftKey);
    return ComposerState(draft: saved ?? '');
  }

  SessionController get _session =>
      ref.read(sessionControllerProvider(sessionId).notifier);

  void setDraft(String text) {
    state = state.copyWith(draft: text, clearError: true);
    final prefs = ref.read(sharedPreferencesProvider);
    text.isEmpty ? prefs.remove(_draftKey) : prefs.setString(_draftKey, text);
  }

  void setWhen(SendWhen when) => state = state.copyWith(when: when);

  Future<void> attach() async {
    final picked = await ref.read(filePickerProvider)();
    if (picked.isEmpty) return;
    state = state.copyWith(attachments: [...state.attachments, ...picked]);
  }

  void removeAttachment(String id) => state = state.copyWith(
    attachments: [
      for (final a in state.attachments)
        if (a.id != id) a,
    ],
  );

  /// Sends the draft: a `prompt` when idle, `steer` or `follow_up` while a
  /// run is active. Sending takes control; [confirmTakeover] asks first when
  /// another client acted in this session within the last 30 seconds.
  Future<void> send({
    required bool runActive,
    Future<bool> Function(String name)? confirmTakeover,
  }) async {
    final text = state.draft.trim();
    if ((text.isEmpty && state.attachments.isEmpty) ||
        state.sending ||
        _preparing ||
        state.uncertain != null) {
      return;
    }
    _preparing = true;
    state = state.copyWith(clearError: true);
    try {
      final lease = await _session.leaseForSend(confirm: confirmTakeover);
      if (lease == null) return;
      state = state.copyWith(sending: true);
      final uploads = <String>[];
      final api = ref.read(apiProvider);
      try {
        for (final attachment in state.attachments) {
          uploads.add(
            await SessionsApi(api!).upload(
              sessionId,
              attachment.bytes,
              filename: attachment.name,
              contentType: attachment.mimeType,
            ),
          );
        }
      } on PircException catch (error) {
        // Nothing was sent: the draft and the attachments stay.
        if (!ref.read(connectionProvider.notifier).report(error)) {
          state = state.copyWith(error: error.message);
        }
        return;
      }
      final ids = uploads.isEmpty ? null : uploads;
      final payload = !runActive
          ? CommandPayload.prompt(text, uploadIds: ids)
          : state.when == SendWhen.steer
          ? CommandPayload.steer(text, uploadIds: ids)
          : CommandPayload.followUp(text, uploadIds: ids);
      final outcome = await _send(payload, lease: lease);
      switch (outcome) {
        case CommandAccepted() || CommandDuplicate():
          setDraft('');
          state = state.copyWith(attachments: const []);
        case CommandUncertain(:final commandId):
          setDraft('');
          state = state.copyWith(
            attachments: const [],
            uncertain: UncertainSend(commandId, text),
          );
        case CommandRejected() || CommandNotReceived() || null:
          break;
      }
    } finally {
      _preparing = false;
      if (state.sending) state = state.copyWith(sending: false);
    }
  }

  /// "Stop this work". The queue Pi clears returns to the draft.
  Future<void> stop() async {
    final queued = [
      for (final item
          in ref.read(sessionControllerProvider(sessionId)).state?.queue ??
              const <QueueItem>[])
        item.content,
    ];
    final outcome = await _send(CommandPayload.stop());
    if (outcome is CommandAccepted && queued.isNotEmpty) {
      final draft = state.draft.trim();
      setDraft([if (draft.isNotEmpty) draft, ...queued].join('\n\n'));
    }
  }

  Future<CommandOutcome?> setModel(ModelInfo model) =>
      _send(CommandPayload.setModel(model.provider, model.id));

  /// Sets [model] and, when its levels no longer accept the chosen thinking
  /// level, the nearest lower one the model accepts (the pot forms' rule).
  Future<void> changeModel(ModelInfo model) async {
    final before = ref
        .read(sessionControllerProvider(sessionId))
        .state
        ?.thinkingLevel;
    final next = before == null
        ? null
        : fitThinkingToLevels(before, model.thinkingLevels);
    await setModel(model);
    if (next != null && next != before) await setThinking(next);
  }

  Future<CommandOutcome?> setThinking(String level) =>
      _send(CommandPayload.setThinking(level));

  Future<CommandOutcome?> setApprovalMode(String mode) =>
      _send(CommandPayload.setApprovalMode(mode));

  /// "Check status" of an uncertain command; never sends it again.
  Future<void> checkStatus() async {
    final uncertain = state.uncertain;
    final sender = _sender;
    if (uncertain == null || sender == null) return;
    state = state.copyWith(checking: true);
    try {
      final outcome = await sender.resolve(sessionId, uncertain.commandId);
      switch (outcome) {
        case CommandAccepted() || CommandDuplicate():
          state = state.copyWith(clearUncertain: true);
        case CommandRejected():
          state = state.copyWith(clearUncertain: true, error: _rejected);
          setDraft(uncertain.text);
        case CommandNotReceived():
          // It never arrived, so it did not run: the text is the user's again.
          state = state.copyWith(clearUncertain: true);
          setDraft(uncertain.text);
        case CommandUncertain():
          break;
      }
    } on PircException catch (error) {
      state = state.copyWith(error: error.message);
    } finally {
      state = state.copyWith(checking: false);
    }
  }

  static const _rejected = 'rejected';

  /// Sends [payload] under [lease]; a plain Stop needs no lease and goes
  /// with this device's client ID alone.
  Future<CommandOutcome?> _send(
    CommandPayload payload, {
    ControlLease? lease,
  }) async {
    final sender = _sender;
    final view = ref.read(sessionControllerProvider(sessionId));
    final control = lease ?? _session.heldLease;
    final stop = payload.type == 'stop';
    if (sender == null || (!stop && control == null) || view.state == null) {
      return null;
    }
    try {
      final outcome = await sender.send(
        sessionId: sessionId,
        payload: payload,
        lease: control,
        clientId: ref.read(clientIdProvider),
        binding: view.state!.session.binding,
      );
      if (outcome is CommandRejected) {
        state = state.copyWith(
          error: switch (outcome.command?.error) {
            final Map<Object?, Object?> error =>
              '${error['message'] ?? _rejected}',
            _ => _rejected,
          },
        );
      }
      return outcome;
    } on StaleEnvironment {
      // The draft stays; a new snapshot brings the current binding.
      unawaited(_session.reload());
      state = state.copyWith(error: 'stale_environment');
    } on LostControl {
      _session.lostControl();
    } on PircException catch (error) {
      if (!ref.read(connectionProvider.notifier).report(error)) {
        state = state.copyWith(error: error.message);
      }
    } on ArgumentError {
      // No binding yet: load it again.
      unawaited(_session.reload());
    }
    return null;
  }
}
