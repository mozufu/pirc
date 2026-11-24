import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/bridge.dart';
import 'package:pirc_mobile/reply_controller.dart';

class FakeRepository implements ReplyRepository {
  ReplySnapshot current = const ReplySnapshot(
    revision: 1,
    status: ReplyStatus.pending,
  );
  int writes = 0;
  Completer<ReplySnapshot>? readGate;
  bool loseResponse = false;
  @override
  Future<ReplySnapshot> read() async =>
      readGate == null ? current : readGate!.future;
  @override
  Future<ReplySnapshot> answer(int revision, String choice) async {
    writes++;
    if (loseResponse) throw PlatformException(code: 'OUTCOME_UNKNOWN');
    return current = ReplySnapshot(
      revision: revision + 1,
      status: ReplyStatus.handled,
      answer: choice,
    );
  }
}

void main() {
  test(
    'checking and choosing never submit; double tap only writes once',
    () async {
      final repo = FakeRepository();
      final controller = ReplyController(repo);
      await controller.refresh();
      controller.select('先驗證浮窗');
      expect(repo.writes, 0);
      repo.readGate = Completer();
      final first = controller.submit();
      await controller.submit();
      expect(controller.canSubmit, false);
      expect(repo.writes, 0);
      repo.readGate!.complete(repo.current);
      await first;
      expect(repo.writes, 1);
      expect(controller.snapshot!.status, ReplyStatus.handled);
      controller.dispose();
    },
  );

  for (final status in [
    ReplyStatus.handled,
    ReplyStatus.expired,
    ReplyStatus.offline,
    ReplyStatus.controlledElsewhere,
  ]) {
    test('refresh before submit refuses $status without writing', () async {
      final repo = FakeRepository();
      final controller = ReplyController(repo);
      await controller.refresh();
      controller.select('先驗證浮窗');
      repo.current = ReplySnapshot(revision: 2, status: status);
      await controller.submit();
      expect(repo.writes, 0);
      expect(controller.snapshot!.status, status);
      controller.dispose();
    });
  }

  test('new revision requires another explicit confirmation', () async {
    final repo = FakeRepository();
    final controller = ReplyController(repo);
    await controller.refresh();
    controller.select('先驗證浮窗');
    repo.current = const ReplySnapshot(
      revision: 2,
      status: ReplyStatus.pending,
    );
    await controller.submit();
    expect(repo.writes, 0);
    expect(controller.choice, null);
    expect(controller.canSubmit, false);
    controller.dispose();
  });

  test(
    'unknown result never retries, even after a still-pending refresh',
    () async {
      final repo = FakeRepository()..loseResponse = true;
      final controller = ReplyController(repo);
      await controller.refresh();
      controller.select('先驗證浮窗');
      await controller.submit();
      expect(controller.outcomeUnknown, true);
      await controller.refresh();
      await controller.submit();
      expect(controller.outcomeUnknown, true);
      expect(repo.writes, 1);
      repo.current = const ReplySnapshot(
        revision: 2,
        status: ReplyStatus.handled,
      );
      await controller.refresh();
      expect(controller.outcomeUnknown, false);
      expect(controller.canSubmit, false);
      controller.dispose();
    },
  );

  test('background refresh preserves the unsubmitted choice', () async {
    final repo = FakeRepository();
    final controller = ReplyController(repo);
    await controller.refresh();
    controller.select('先驗證浮窗');
    await controller.refresh();
    expect(controller.choice, '先驗證浮窗');
    expect(repo.writes, 0);
    controller.dispose();
  });

  test(
    'artifact updates never replace selected version or its scroll offset',
    () {
      final artifact = ArtifactSelection();
      artifact.receive(2);
      expect(artifact.selected, 1);
      expect(artifact.hasUpdate, true);
      artifact.switchTo(2, 320);
      expect(artifact.offset, 0);
      artifact.switchTo(1, 80);
      expect(artifact.offset, 320);
      artifact.switchTo(2, 321);
      expect(artifact.offset, 80);
      artifact.receive(1);
      expect(artifact.latest, 2);
    },
  );
}
