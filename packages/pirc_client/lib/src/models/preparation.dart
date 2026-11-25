import 'package:meta/meta.dart';

import '../json.dart';

/// How the first message of a new conversation was admitted.
@immutable
class MessageAdmission {
  const MessageAdmission({
    this.outcome,
    this.commandId,
    this.retryId,
    this.attemptNumber,
    this.retryEligible = false,
    this.stopRequested = false,
    this.stopConfirmed = false,
    this.recovery,
  });

  factory MessageAdmission.fromJson(Object? json) => MessageAdmission(
    outcome: str(field(json, 'outcome')),
    commandId: str(field(json, 'commandId')),
    retryId: str(field(json, 'retryId')),
    attemptNumber: number(field(json, 'attemptNumber')),
    retryEligible: field(json, 'retryEligible') == true,
    stopRequested: field(json, 'stopRequested') == true,
    stopConfirmed: field(json, 'stopConfirmed') == true,
    recovery: field(json, 'recovery'),
  );

  final String? outcome;
  final String? commandId;
  final String? retryId;
  final int? attemptNumber;
  final bool retryEligible;
  final bool stopRequested;
  final bool stopConfirmed;
  final Object? recovery;
}

/// A first-send preparation (`/api/conversation-submissions`).
@immutable
class Preparation {
  const Preparation({
    required this.operationId,
    this.sessionId,
    this.workspaceId,
    required this.state,
    this.accepted = false,
    this.nodeMapped = false,
    this.stagedAttachmentIds = const [],
    this.attachmentsExpiresAt,
    this.attachmentsExpiredAt,
    this.cleanupPending = false,
    this.acceptedAt,
    this.deliveryError,
    this.messageAdmission,
    this.cleanupError,
    this.submission,
  });

  factory Preparation.fromJson(Object? json) {
    final admission = field(json, 'messageAdmission');
    return Preparation(
      operationId: str(field(json, 'operationId')) ?? '',
      sessionId: str(field(json, 'sessionId')),
      workspaceId: str(field(json, 'workspaceId')),
      state: str(field(json, 'state')) ?? '',
      accepted: field(json, 'accepted') == true,
      nodeMapped: field(json, 'nodeMapped') == true,
      stagedAttachmentIds: [
        for (final id in array(field(json, 'stagedAttachmentIds')) ?? const [])
          ?str(id),
      ],
      attachmentsExpiresAt: number(field(json, 'attachmentsExpiresAt')),
      attachmentsExpiredAt: number(field(json, 'attachmentsExpiredAt')),
      cleanupPending: field(json, 'cleanupPending') == true,
      acceptedAt: number(field(json, 'acceptedAt')),
      deliveryError: field(json, 'deliveryError'),
      messageAdmission: admission == null
          ? null
          : MessageAdmission.fromJson(admission),
      cleanupError: field(json, 'cleanupError'),
      submission: object(field(json, 'submission')),
    );
  }

  final String operationId;
  final String? sessionId;
  final String? workspaceId;

  /// preparing, accepted, ready, sending, admitted, admission_failed,
  /// outcome_unknown, stopping, stopped or cancelled.
  final String state;
  final bool accepted;
  final bool nodeMapped;
  final List<String> stagedAttachmentIds;
  final int? attachmentsExpiresAt;
  final int? attachmentsExpiredAt;
  final bool cleanupPending;
  final int? acceptedAt;
  final Object? deliveryError;
  final MessageAdmission? messageAdmission;
  final Object? cleanupError;
  final Map<String, Object?>? submission;
}

/// An attachment declared in a first-send submission.
@immutable
class SubmissionAttachment {
  const SubmissionAttachment({
    required this.id,
    required this.name,
    required this.mimeType,
    required this.byteSize,
    required this.sha256,
  });

  final String id;
  final String name;
  final String mimeType;
  final int byteSize;
  final String sha256;

  Map<String, Object?> toJson() => {
    'id': id,
    'name': name,
    'mimeType': mimeType,
    'byteSize': byteSize,
    'sha256': sha256,
  };
}

/// What a first send creates: `submission` of the prepare request.
@immutable
class Submission {
  const Submission({
    required this.workspaceId,
    required this.message,
    this.modelProvider,
    this.modelId,
    this.thinking,
    this.attachments = const [],
  });

  final String workspaceId;
  final String message;
  final String? modelProvider;
  final String? modelId;
  final String? thinking;
  final List<SubmissionAttachment> attachments;

  Map<String, Object?> toJson() => {
    'workspaceId': workspaceId,
    'message': message,
    if (modelProvider != null && modelId != null)
      'model': {'provider': modelProvider, 'id': modelId},
    'thinking': ?thinking,
    if (attachments.isNotEmpty)
      'attachments': [for (final a in attachments) a.toJson()],
  };
}
