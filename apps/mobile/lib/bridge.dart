import 'package:flutter/services.dart';

enum ReplyStatus { pending, handled, expired, controlledElsewhere, offline }

class ReplySnapshot {
  const ReplySnapshot({
    required this.revision,
    required this.status,
    this.answer,
    this.actor,
    this.answeredAt,
    this.latestVersion = 1,
    this.draft = '',
  });
  factory ReplySnapshot.fromMap(Map<Object?, Object?> map) => ReplySnapshot(
    revision: map['revision'] as int,
    status: ReplyStatus.values.byName(map['status'] as String),
    answer: map['answer'] as String?,
    actor: map['actor'] as String?,
    answeredAt: map['answeredAt'] as String?,
    latestVersion: map['latestVersion'] as int,
    draft: map['draft'] as String? ?? '',
  );
  final int revision;
  final ReplyStatus status;
  final String? answer, actor, answeredAt;
  final int latestVersion;
  final String draft;
}

abstract interface class ReplyRepository {
  Future<ReplySnapshot> read();
  Future<ReplySnapshot> answer(int revision, String choice);
}

/// Local test contract, NOT the gateway API. Android owns the shared fixture.
class MobileBridge implements ReplyRepository {
  static const channel = MethodChannel('dev.pirc.mobile/validation');
  Future<T?> invoke<T>(String method, [Object? arguments]) =>
      channel.invokeMethod<T>(method, arguments);
  @override
  Future<ReplySnapshot> read() async => ReplySnapshot.fromMap(
    (await channel.invokeMapMethod<Object?, Object?>('read'))!,
  );
  @override
  Future<ReplySnapshot> answer(int revision, String choice) async =>
      ReplySnapshot.fromMap(
        (await channel.invokeMapMethod<Object?, Object?>('answer', {
          'revision': revision,
          'choice': choice,
        }))!,
      );
}
