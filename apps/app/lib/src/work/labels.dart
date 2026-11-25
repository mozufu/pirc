import '../../l10n/app_localizations.dart';

/// The words for status values that the backend sends as codes. An unknown
/// value is shown as it came, so a newer backend never shows a blank.
extension StatusLabels on AppLocalizations {
  /// A background task (`running`, `stopping`, `completed`, `failed`,
  /// `stopped`, `timed_out`) or a teammate (`pending`, `in_progress`,
  /// `done`, …).
  String taskStatus(String status) => switch (status) {
    'running' => stateRunning,
    'stopping' => stateStopping,
    'completed' => statusCompleted,
    'done' => stepDone,
    'failed' => stepFailed,
    'stopped' => statusStopped,
    'timed_out' => statusTimedOut,
    'pending' => statusPending,
    'in_progress' => statusInProgress,
    _ => status,
  };

  /// A checkpoint recovery job (`preparing`, `ready`, `opened`, `stale`,
  /// `failed`, `interrupted`).
  String checkpointJobState(String state) => switch (state) {
    'preparing' => jobPreparing,
    'ready' => jobReady,
    'opened' => jobOpened,
    'stale' => jobStale,
    'failed' => stepFailed,
    'interrupted' => jobInterrupted,
    _ => state,
  };

  /// A recorded file operation of a checkpoint (`pending`, `observed`,
  /// `failed`).
  String checkpointOperationState(String state) => switch (state) {
    'pending' => statusPending,
    'observed' => operationRecorded,
    'failed' => stepFailed,
    _ => state,
  };

  /// A result's kind (`markdown`, `code`, `table`).
  String resultKind(String kind) => switch (kind) {
    'markdown' => resultKindMarkdown,
    'code' => resultKindCode,
    'table' => resultKindTable,
    _ => kind,
  };
}
