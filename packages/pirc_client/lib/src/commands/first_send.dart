import 'dart:async';

import '../api_client.dart';
import '../errors.dart';
import '../json.dart';
import '../models/control_lease.dart';
import '../models/preparation.dart';
import '../transport/transport.dart';
import 'control.dart';
import 'ids.dart';

/// The result of [FirstSendClient.send].
sealed class FirstSendOutcome {
  const FirstSendOutcome(this.operationId);
  final String operationId;
}

/// The first message was handed to the node; [preparation] says how it was
/// admitted (`messageAdmission`).
class FirstSendDispatched extends FirstSendOutcome {
  FirstSendDispatched(this.preparation, this.lease)
    : super(preparation.operationId);
  final Preparation preparation;
  final ControlLease lease;
}

/// The dispatch request may or may not have run. Read
/// [FirstSendClient.receipt]; never dispatch it again through another route.
class FirstSendUncertain extends FirstSendOutcome {
  const FirstSendUncertain(super.operationId, {this.sessionId, this.cause});
  final String? sessionId;
  final Object? cause;
}

/// `/api/conversation-submissions`: the only way a conversation is created.
class FirstSendClient {
  FirstSendClient(
    this.api, {
    ControlLeaseClient? control,
    this.dispatchTimeout = const Duration(seconds: 30),
  }) : control = control ?? ControlLeaseClient(api);

  final ApiClient api;
  final ControlLeaseClient control;
  final Duration dispatchTimeout;

  static const _base = '/api/conversation-submissions';
  static String _path(String operationId, [String action = '']) =>
      '$_base/${Uri.encodeComponent(operationId)}'
      '${action.isEmpty ? '' : '/$action'}';

  static Preparation _preparation(Object? reply) =>
      Preparation.fromJson(field(reply, 'preparation'));

  /// A fresh client operation ID (`[A-Za-z0-9_-]{1,100}`).
  static String newOperationId() => randomId();

  Future<Preparation> prepare({
    required String operationId,
    required Submission submission,
    String? expectedOwner,
  }) async => _preparation(
    await api.post('$_base/prepare', {
      'operationId': operationId,
      'expectedOwner': ?expectedOwner,
      'submission': submission.toJson(),
    }),
  );

  Future<void> uploadAttachment(
    String operationId,
    String attachmentId,
    List<int> bytes,
  ) => api.json(
    ApiRequest.putBytes(
      _path(operationId, 'attachments/${Uri.encodeComponent(attachmentId)}'),
      bytes,
      contentType: 'application/octet-stream',
    ),
  );

  Future<Preparation> accept(String operationId) async =>
      _preparation(await api.post(_path(operationId, 'accept')));

  Future<Preparation> materialize(String operationId) async =>
      _preparation(await api.post(_path(operationId, 'materialize')));

  /// Sends the first message under [lease] (held on the new session).
  Future<Preparation> dispatch(String operationId, ControlLease lease) async =>
      _preparation(
        await api.json(
          ApiRequest.post(
            _path(operationId, 'dispatch'),
            json: {'clientId': lease.clientId, 'generation': lease.generation},
          ),
          timeout: dispatchTimeout,
        ),
      );

  /// The admission receipt: how an uncertain dispatch is resolved.
  Future<Preparation> receipt(String operationId) async =>
      _preparation(await api.get(_path(operationId, 'receipt')));

  Future<Preparation> get(String operationId) async =>
      _preparation(await api.get(_path(operationId)));

  /// "Send again" after a refused first message: a separate action with its
  /// own [retryId], never an automatic resend.
  Future<Preparation> retry(
    String operationId, {
    required String retryId,
    required String previousCommandId,
    required ControlLease lease,
  }) async => _preparation(
    await api.json(
      ApiRequest.post(
        _path(operationId, 'retry'),
        json: {
          'retryId': retryId,
          'previousCommandId': previousCommandId,
          'clientId': lease.clientId,
          'generation': lease.generation,
        },
      ),
      timeout: dispatchTimeout,
    ),
  );

  Future<Preparation> cancel(String operationId) async =>
      _preparation(await api.json(ApiRequest.delete(_path(operationId))));

  /// prepare → upload → accept → materialize → acquire lease → dispatch.
  /// A dispatch whose reply never arrived comes back as [FirstSendUncertain].
  Future<FirstSendOutcome> send({
    required String operationId,
    required Submission submission,
    required String clientId,
    Map<String, List<int>> attachments = const {},
    String? expectedOwner,
    String? clientName,
  }) async {
    await prepare(
      operationId: operationId,
      submission: submission,
      expectedOwner: expectedOwner,
    );
    for (final attachment in submission.attachments) {
      final bytes = attachments[attachment.id];
      if (bytes == null) {
        throw ArgumentError('No bytes for attachment ${attachment.id}');
      }
      // Staging always takes raw bytes; the prepared manifest owns the MIME
      // type, and the Gateway refuses any other content type.
      await uploadAttachment(operationId, attachment.id, bytes);
    }
    await accept(operationId);
    final ready = await materialize(operationId);
    final sessionId = ready.sessionId;
    if (sessionId == null) {
      throw const ApiError(502, 'invalid_preparation', 'No session created');
    }
    final lease = await control.acquire(
      sessionId,
      clientId: clientId,
      clientName: clientName,
    );
    try {
      return FirstSendDispatched(await dispatch(operationId, lease), lease);
    } on ApiError catch (error) {
      // A proxy's 5xx without a gateway body: the dispatch may have run.
      if (error.status < 500 || error.code != 'http_${error.status}') rethrow;
      return FirstSendUncertain(
        operationId,
        sessionId: sessionId,
        cause: error,
      );
    } on TransportException catch (error) {
      return FirstSendUncertain(
        operationId,
        sessionId: sessionId,
        cause: error,
      );
    }
  }
}
