import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_touch_boundary.dart';

void main() {
  late List<(String, String?, Offset)> exits;
  late NativeDocumentTouchBoundary boundary;
  setUp(() {
    exits = [];
    boundary = NativeDocumentTouchBoundary(
      onExit: (id, target, position) => exits.add((id, target, position)),
    );
  });
  void touch(
    int pointer,
    String? target, [
    Offset point = const Offset(10, 20),
  ]) {
    boundary.down(PointerDownEvent(pointer: pointer));
    expect(boundary.up(PointerUpEvent(pointer: pointer)), isTrue);
    boundary.completeTarget(target, point);
  }

  test('inside touch keeps hover; measured outside touch exits only once', () {
    touch(1, 'canvas');
    boundary.acceptedClick('canvas');
    boundary.reconcile();
    expect(exits, isEmpty);
    touch(2, 'button', const Offset(12, 40));
    boundary.reconcile();
    expect(exits, [('canvas', 'button', const Offset(12, 40))]);
  });

  test('click finishing after an outside touch cannot revive old hover', () {
    touch(1, 'canvas');
    touch(2, null, const Offset(80, 20));
    boundary.acceptedClick('canvas');
    boundary.reconcile();
    expect(exits, [('canvas', null, const Offset(80, 20))]);
  });

  test('outside touch while click is pending does not exit twice', () {
    touch(1, 'canvas');
    boundary.acceptedClick('canvas');
    touch(2, null);
    boundary.reconcile();
    expect(exits, hasLength(1));
  });

  test('late click from another canvas preserves the latest canvas hover', () {
    touch(1, 'a');
    touch(2, 'b');
    boundary.acceptedClick('b');
    boundary.reconcile();
    boundary.acceptedClick('a');
    boundary.reconcile();
    expect(exits, [('a', 'b', const Offset(10, 20))]);
    touch(3, null);
    expect(exits.last.$1, 'b');
  });

  test('unavailable hit does not reuse a preceding outside target', () {
    touch(1, null);
    boundary.down(const PointerDownEvent(pointer: 2));
    expect(boundary.up(const PointerUpEvent(pointer: 2)), isTrue);
    boundary.acceptedClick('canvas');
    boundary.reconcile();
    expect(exits, isEmpty);
    touch(3, null);
    expect(exits, hasLength(1));
  });

  test(
    'secondary and canceled touches cannot replace the completed target',
    () {
      boundary.down(const PointerDownEvent(pointer: 1));
      boundary.down(const PointerDownEvent(pointer: 2));
      expect(boundary.up(const PointerUpEvent(pointer: 2)), isFalse);
      boundary.cancel(const PointerCancelEvent(pointer: 1));
      expect(boundary.up(const PointerUpEvent(pointer: 1)), isFalse);
      boundary.down(const PointerDownEvent(pointer: 3));
      expect(boundary.up(const PointerUpEvent(pointer: 3)), isTrue);
    },
  );

  test('remaining finger never becomes primary; next gesture does', () {
    boundary.down(const PointerDownEvent(pointer: 1));
    boundary.down(const PointerDownEvent(pointer: 2));
    expect(boundary.up(const PointerUpEvent(pointer: 1)), isTrue);
    boundary.down(const PointerDownEvent(pointer: 3));
    expect(boundary.up(const PointerUpEvent(pointer: 2)), isFalse);
    expect(boundary.up(const PointerUpEvent(pointer: 3)), isFalse);
    touch(4, null);
  });

  test('mouse events do not alter touch reconciliation', () {
    boundary.down(
      const PointerDownEvent(pointer: 1, kind: PointerDeviceKind.mouse),
    );
    expect(
      boundary.up(
        const PointerUpEvent(pointer: 1, kind: PointerDeviceKind.mouse),
      ),
      isFalse,
    );
    touch(2, 'canvas');
  });

  test(
    'document detach clears targets and invalidates pending completion epoch',
    () {
      touch(1, null);
      boundary.acceptedClick('canvas');
      final epoch = boundary.epoch;
      boundary.clear();
      expect(boundary.epoch, isNot(epoch));
      boundary.reconcile();
      touch(2, null);
      expect(exits, isEmpty);
    },
  );
  test('new primary down and cancel invalidate a pending real-frame hit', () {
    touch(1, 'canvas');
    final firstUp = boundary.sequence;
    boundary.down(const PointerDownEvent(pointer: 2));
    expect(boundary.sequence, isNot(firstUp));
    final nextDown = boundary.sequence;
    boundary.cancel(const PointerCancelEvent(pointer: 2));
    expect(boundary.sequence, isNot(nextDown));
  });
  test('outside exit waits for every genuinely accepted queued click', () {
    touch(1, 'canvas');
    boundary.acceptedClick('canvas');
    boundary.queuedClick('canvas', 30);
    boundary.queuedClick('canvas', 31);
    touch(2, null);
    expect(exits, isEmpty);
    boundary.acceptedClick('canvas');
    boundary.finishedClick('canvas', 30);
    boundary.reconcile();
    expect(exits, isEmpty);
    boundary.finishedClick('canvas', 31);
    boundary.reconcile();
    expect(exits, [('canvas', null, const Offset(10, 20))]);
  });

  test('clearing a document releases old accepted queue tokens', () {
    boundary.queuedClick('old-canvas', 30);
    boundary.clear();
    touch(1, 'new-canvas');
    boundary.acceptedClick('new-canvas');
    touch(2, null);
    expect(exits.single.$1, 'new-canvas');
  });
}
