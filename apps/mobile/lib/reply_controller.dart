import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'bridge.dart';

class ReplyController extends ChangeNotifier {
  ReplyController(this.repository);
  final ReplyRepository repository;
  ReplySnapshot? snapshot;
  String? choice;
  bool busy = false;
  bool outcomeUnknown = false;
  String? error;
  bool _disposed = false;
  bool get canSubmit =>
      !busy &&
      !outcomeUnknown &&
      error == null &&
      choice != null &&
      snapshot?.status == ReplyStatus.pending;

  void select(String value) {
    if (busy || outcomeUnknown || snapshot?.status != ReplyStatus.pending) {
      return;
    }
    choice = value;
    _emit();
  }

  Future<void> refresh() async {
    if (busy) return;
    busy = true;
    error = null;
    _emit();
    try {
      final latest = await repository.read();
      if (snapshot != null && snapshot!.revision != latest.revision) {
        choice = null;
      }
      snapshot = latest;
      // Pending does not prove that an in-flight submission won't arrive later.
      if (snapshot!.status == ReplyStatus.handled ||
          snapshot!.status == ReplyStatus.expired) {
        outcomeUnknown = false;
      }
    } catch (_) {
      error = '無法確認最新狀態，請重試';
    } finally {
      busy = false;
      _emit();
    }
  }

  Future<void> submit() async {
    if (!canSubmit) return;
    final confirmedRevision = snapshot!.revision;
    final confirmedChoice = choice!;
    busy = true;
    error = null;
    _emit();
    bool attempted = false;
    try {
      final latest = await repository.read();
      snapshot = latest;
      if (latest.status != ReplyStatus.pending) return;
      if (latest.revision != confirmedRevision) {
        choice = null;
        error = '問題已更新，請重新確認';
        return;
      }
      attempted = true;
      snapshot = await repository.answer(confirmedRevision, confirmedChoice);
    } on PlatformException catch (e) {
      outcomeUnknown = attempted && e.code != 'REJECTED';
      error = outcomeUnknown ? '不確定是否已送達，請檢查狀態' : '問題狀態已變更，請重新整理';
    } catch (_) {
      outcomeUnknown = attempted;
      error = attempted ? '不確定是否已送達，請檢查狀態' : '無法確認最新狀態，請重試';
    } finally {
      busy = false;
      _emit();
    }
  }

  void resetSelection() {
    choice = null;
    outcomeUnknown = false;
    error = null;
  }

  void _emit() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}

class ArtifactSelection {
  int selected = 1;
  int latest = 1;
  final Map<int, double> offsets = {};
  bool get hasUpdate => latest > selected;
  void receive(int version) {
    if (version > latest) latest = version;
  }

  void switchTo(int version, double currentOffset) {
    if (version < 1 || version > latest) return;
    offsets[selected] = currentOffset;
    selected = version;
  }

  double get offset => offsets[selected] ?? 0;
}
