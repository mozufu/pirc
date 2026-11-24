import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/document_canvas_pointer.dart';

typedef _ReceivedEvent = (String, Map<String, dynamic>);

Widget _host({
  required GlobalKey surfaceKey,
  required GlobalKey canvasKey,
  required Object documentIdentity,
  required String elementId,
  required NativeCanvasPointerEventCallback onEvent,
  VoidCallback? Function(Map<String, dynamic> data)? onTouchClickQueued,
  bool touchActionNone = false,
  Offset Function()? viewportOrigin,
  Widget? parent,
}) {
  final canvas = SizedBox(
    width: 300,
    height: 150,
    child: NativeDocumentCanvasPointer(
      key: surfaceKey,
      documentIdentity: documentIdentity,
      elementId: elementId,
      touchActionNone: touchActionNone,
      viewportOrigin: viewportOrigin,
      onTouchClickQueued: onTouchClickQueued,
      onEvent: onEvent,
      child: SizedBox.expand(
        key: canvasKey,
        child: const ColoredBox(color: Colors.white),
      ),
    ),
  );
  return MaterialApp(
    home: Scaffold(body: parent ?? Center(child: canvas)),
  );
}

void main() {
  testWidgets('forwards touch taps with viewport-relative coordinates', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();
    final identity = Object();
    const viewportOrigin = Offset(13, 27);

    await tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: identity,
        elementId: 'canvas-1',
        viewportOrigin: () => viewportOrigin,
        onEvent: (type, data) async {
          received.add((type, Map<String, dynamic>.from(data)));
          return true;
        },
      ),
    );

    final topLeft = tester.getTopLeft(find.byKey(canvasKey));
    final localTap = const Offset(150, 75);
    await tester.tapAt(topLeft + localTap);
    await tester.pumpAndSettle();

    expect(received.map((event) => event.$1), <String>[
      'pointerdown',
      'pointerup',
      'click',
    ]);
    final down = received.first.$2;
    expect(down['pointerType'], 'touch');
    expect(down['isPrimary'], isTrue);
    expect(down['button'], 0);
    expect(down['buttons'], 1);
    expect(down['pressure'], greaterThan(0));
    expect(down['offsetX'], closeTo(localTap.dx, 0.01));
    expect(down['offsetY'], closeTo(localTap.dy, 0.01));
    expect(
      down['clientX'],
      closeTo(topLeft.dx + localTap.dx - viewportOrigin.dx, 0.01),
    );
    expect(
      down['clientY'],
      closeTo(topLeft.dy + localTap.dy - viewportOrigin.dy, 0.01),
    );
    expect(down['geometry'], <String, double>{
      'left': topLeft.dx - viewportOrigin.dx,
      'top': topLeft.dy - viewportOrigin.dy,
      'width': 300,
      'height': 150,
    });
    expect(received.last.$2['pointerId'], down['pointerId']);
  });

  testWidgets(
    'queues touch marker synchronously and completes after dispatch',
    (tester) async {
      final events = <_ReceivedEvent>[];
      final order = <String>[];
      final downDispatch = Completer<bool>();
      final clickDispatch = Completer<bool>();
      final surfaceKey = GlobalKey();
      final canvasKey = GlobalKey();
      Map<String, dynamic>? markedData;
      Map<String, dynamic>? dispatchedClickData;
      var completions = 0;

      await tester.pumpWidget(
        _host(
          surfaceKey: surfaceKey,
          canvasKey: canvasKey,
          documentIdentity: Object(),
          elementId: 'canvas-1',
          onEvent: (type, data) {
            events.add((type, data));
            if (type == 'pointerdown') {
              order.add('down-start');
              return downDispatch.future;
            }
            if (type == 'click') {
              order.add('click-start');
              dispatchedClickData = data;
              return clickDispatch.future;
            }
            return Future<bool>.value(true);
          },
          onTouchClickQueued: (data) {
            order.add('marker');
            markedData = data;
            return () {
              completions++;
              order.add('complete');
            };
          },
        ),
      );

      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(canvasKey)),
        kind: PointerDeviceKind.touch,
      );
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(order, <String>['down-start', 'marker']);
      expect(markedData?['pointerType'], 'touch');
      expect(markedData?['isPrimary'], isTrue);
      expect(events.any((event) => event.$1 == 'click'), isFalse);

      downDispatch.complete(true);
      await tester.pump();
      expect(order, <String>['down-start', 'marker', 'click-start']);
      expect(identical(dispatchedClickData, markedData), isTrue);
      expect(completions, 0);

      clickDispatch.complete(true);
      await tester.pumpAndSettle();
      expect(completions, 1);
      expect(order.last, 'complete');
    },
  );

  testWidgets('queues one marker per accepted touch click', (tester) async {
    var queued = 0;
    var clicks = 0;
    var completions = 0;
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: Object(),
        elementId: 'canvas-1',
        onEvent: (type, data) async {
          if (type == 'click') clicks++;
          return true;
        },
        onTouchClickQueued: (_) {
          queued++;
          return () => completions++;
        },
      ),
    );

    final point = tester.getCenter(find.byKey(canvasKey));
    await tester.tapAt(point);
    await tester.tapAt(point);
    await tester.pumpAndSettle();

    expect(queued, 2);
    expect(clicks, 2);
    expect(completions, 2);
  });

  testWidgets('mouse drag keeps its pointer id and clicks on an inside up', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: Object(),
        elementId: 'canvas-1',
        onEvent: (type, data) async {
          received.add((type, Map<String, dynamic>.from(data)));
          return true;
        },
      ),
    );

    final topLeft = tester.getTopLeft(find.byKey(canvasKey));
    final start = topLeft + const Offset(30, 20);
    final end = topLeft + const Offset(180, 100);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
      buttons: kPrimaryMouseButton,
    );
    await gesture.moveTo(end);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    final pointerEvents = received
        .where(
          (event) =>
              event.$1 == 'pointerdown' ||
              event.$1 == 'pointermove' ||
              event.$1 == 'pointerup' ||
              event.$1 == 'click',
        )
        .toList();
    expect(pointerEvents.map((event) => event.$1), <String>[
      'pointerdown',
      'pointermove',
      'pointerup',
      'click',
    ]);
    expect(pointerEvents.map((event) => event.$2['pointerId']).toSet(), <int>{
      1,
    });
    expect(pointerEvents.first.$2['pointerType'], 'mouse');
    expect(pointerEvents.first.$2['button'], 0);
    expect(pointerEvents.first.$2['buttons'], 1);
    expect(pointerEvents.last.$2['button'], 0);
    expect(pointerEvents.last.$2['buttons'], 0);
    expect(pointerEvents.last.$2['offsetX'], closeTo(180, 0.01));
    expect(pointerEvents.last.$2['offsetY'], closeTo(100, 0.01));
  });

  testWidgets('auto touch action yields to scrolling and cancels once', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();
    var touchClicksQueued = 0;
    final canvas = SizedBox(
      width: 300,
      height: 150,
      child: NativeDocumentCanvasPointer(
        key: surfaceKey,
        documentIdentity: Object(),
        elementId: 'canvas-1',
        touchActionNone: false,
        onTouchClickQueued: (_) {
          touchClicksQueued++;
          return null;
        },
        onEvent: (type, data) async {
          received.add((type, Map<String, dynamic>.from(data)));
          return true;
        },
        child: SizedBox.expand(
          key: canvasKey,
          child: const ColoredBox(color: Colors.white),
        ),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: <Widget>[
                const SizedBox(height: 80),
                canvas,
                const SizedBox(height: 900),
              ],
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(canvasKey)),
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveBy(const Offset(0, -60));
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();

    expect(received.where((event) => event.$1 == 'pointercancel').length, 1);
    expect(received.any((event) => event.$1 == 'click'), isFalse);
    expect(touchClicksQueued, 0);
  });

  testWidgets('runs queued completion once when click dispatch throws', (
    tester,
  ) async {
    var queued = 0;
    var completions = 0;
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();

    await tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: Object(),
        elementId: 'canvas-1',
        onEvent: (type, data) async {
          if (type == 'click') throw StateError('click dispatch failed');
          return true;
        },
        onTouchClickQueued: (_) {
          queued++;
          return () => completions++;
        },
      ),
    );

    await tester.tapAt(tester.getCenter(find.byKey(canvasKey)));
    await tester.pumpAndSettle();

    expect(queued, 1);
    expect(completions, 1);
    expect(tester.takeException(), isNotNull);
  });

  testWidgets('coalesces moves behind an awaited down and keeps edge order', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final firstDown = Completer<bool>();
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();
    var heldDown = false;

    await tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: Object(),
        elementId: 'canvas-1',
        touchActionNone: true,
        onEvent: (type, data) {
          received.add((type, Map<String, dynamic>.from(data)));
          if (type == 'pointerdown' && !heldDown) {
            heldDown = true;
            return firstDown.future;
          }
          return Future<bool>.value(true);
        },
      ),
    );

    final topLeft = tester.getTopLeft(find.byKey(canvasKey));
    final start = topLeft + const Offset(100, 60);
    final gesture = await tester.startGesture(
      start,
      kind: PointerDeviceKind.touch,
    );
    await gesture.moveTo(start + const Offset(2, 2));
    await gesture.moveTo(start + const Offset(4, 4));
    await gesture.moveTo(start + const Offset(6, 6));
    await gesture.up();

    expect(received.map((event) => event.$1), <String>['pointerdown']);
    firstDown.complete(true);
    await tester.pump();
    await tester.pumpAndSettle();

    expect(received.map((event) => event.$1), <String>[
      'pointerdown',
      'pointermove',
      'pointerup',
      'click',
    ]);
    expect(received[1].$2['offsetX'], closeTo(106, 0.01));
    expect(received[1].$2['offsetY'], closeTo(66, 0.01));
  });

  testWidgets('touch-action changes do not interrupt an existing pointer', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();
    final owner = Object();
    Future<void> pumpPolicy(bool none) => tester.pumpWidget(
      _host(
        surfaceKey: surfaceKey,
        canvasKey: canvasKey,
        documentIdentity: owner,
        elementId: 'canvas-1',
        touchActionNone: none,
        onEvent: (type, data) async {
          received.add((type, data));
          return false;
        },
      ),
    );
    await pumpPolicy(true);
    final point =
        tester.getTopLeft(find.byKey(canvasKey)) + const Offset(40, 55);
    final gesture = await tester.startGesture(point);
    await tester.pump();
    await pumpPolicy(false);
    await gesture.moveBy(const Offset(100, 40));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(received.where((e) => e.$1 == 'pointercancel'), isEmpty);
    expect(received.where((e) => e.$1 == 'pointerup'), hasLength(1));
  });

  testWidgets('owner, element, and disposal changes cancel active streams', (
    tester,
  ) async {
    final received = <_ReceivedEvent>[];
    final surfaceKey = GlobalKey();
    final canvasKey = GlobalKey();
    final firstIdentity = Object();
    final secondIdentity = Object();

    Future<void> pumpOwner(Object identity, String elementId) =>
        tester.pumpWidget(
          _host(
            surfaceKey: surfaceKey,
            canvasKey: canvasKey,
            documentIdentity: identity,
            elementId: elementId,
            touchActionNone: true,
            onEvent: (type, data) async {
              received.add((type, Map<String, dynamic>.from(data)));
              return true;
            },
          ),
        );

    await pumpOwner(firstIdentity, 'canvas-a');
    final point = tester.getCenter(find.byKey(canvasKey));
    final ownerGesture = await tester.startGesture(
      point,
      pointer: 51,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await pumpOwner(secondIdentity, 'canvas-a');
    await tester.pump();
    expect(received.where((event) => event.$1 == 'pointercancel').length, 1);
    await ownerGesture.cancel();

    final elementGesture = await tester.startGesture(
      tester.getCenter(find.byKey(canvasKey)),
      pointer: 52,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await pumpOwner(secondIdentity, 'canvas-b');
    await tester.pump();
    expect(received.where((event) => event.$1 == 'pointercancel').length, 2);
    await elementGesture.cancel();

    final disposalGesture = await tester.startGesture(
      tester.getCenter(find.byKey(canvasKey)),
      pointer: 53,
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(received.where((event) => event.$1 == 'pointercancel').length, 3);
    await disposalGesture.cancel();
    await tester.pump();
    expect(received.where((event) => event.$1 == 'pointercancel').length, 3);
  });
}
