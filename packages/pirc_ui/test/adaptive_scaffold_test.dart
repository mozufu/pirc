import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_ui/pirc_ui.dart';

const _destinations = [
  PircDestination(icon: Icons.chat_bubble_outline, label: 'Chat', badge: 3),
  PircDestination(icon: Icons.work_outline, label: 'Work'),
  PircDestination(icon: Icons.notifications_none, label: 'Activity'),
  PircDestination(icon: Icons.calendar_today_outlined, label: 'Calendar'),
];

Widget _frame({
  bool open = false,
  bool side = false,
  VoidCallback? onSideDismiss,
}) => MaterialApp(
  theme: PircTheme.of(Brightness.light),
  home: AdaptiveScaffold(
    destinations: _destinations,
    selectedIndex: 0,
    onDestinationSelected: (_) {},
    list: ListView.builder(
      key: const Key('list'),
      itemCount: 100,
      itemBuilder: (_, i) => SizedBox(height: 48, child: Text('item $i')),
    ),
    content: open
        ? const Material(
            key: Key('content'),
            child: TextField(key: Key('draft')),
          )
        : null,
    side: side ? const Text('side', key: Key('side')) : null,
    onSideDismiss: onSideDismiss,
    placeholder: const Center(child: Text('Nothing open')),
  ),
);

Future<void> _size(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  await tester.pump();
}

/// Finders skip offstage subtrees, so this is "shown in this layout".
bool _visible(WidgetTester tester, Key key) =>
    find.byKey(key).evaluate().isNotEmpty;

void main() {
  tearDown(() {
    final view = TestWidgetsFlutterBinding.instance.platformDispatcher.views;
    for (final v in view) {
      v.resetPhysicalSize();
      v.resetDevicePixelRatio();
    }
  });

  test('layouts follow the window width', () {
    expect(PircLayout.forWidth(375), PircLayout.compact);
    expect(PircLayout.forWidth(599), PircLayout.compact);
    expect(PircLayout.forWidth(600), PircLayout.portrait);
    expect(PircLayout.forWidth(700), PircLayout.portrait);
    expect(PircLayout.forWidth(1000), PircLayout.landscape);
    expect(PircLayout.forWidth(1199), PircLayout.landscape);
    expect(PircLayout.forWidth(1300), PircLayout.desktop);
  });

  testWidgets('375: one screen with a bottom tab bar', (tester) async {
    await _size(tester, 375);
    await tester.pumpWidget(_frame());
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(_visible(tester, const Key('list')), isTrue);
    expect(find.text('3'), findsOneWidget, reason: 'tab badge');
    await tester.pumpWidget(_frame(open: true));
    expect(_visible(tester, const Key('list')), isFalse);
    expect(_visible(tester, const Key('content')), isTrue);
  });

  testWidgets('700: rail and one pane; info slides over at 440', (
    tester,
  ) async {
    await _size(tester, 700);
    await tester.pumpWidget(_frame(open: true, side: true));
    expect(find.text('Calendar'), findsOneWidget);
    expect(find.byType(NavigationBar), findsNothing);
    expect(tester.getTopLeft(find.byKey(const Key('content'))).dx, 76 + 1);
    expect(_visible(tester, const Key('list')), isFalse);
    expect(_visible(tester, const Key('content')), isTrue);
    expect(tester.getTopRight(find.byKey(const Key('side'))).dx, 700);
    expect(tester.getTopLeft(find.byKey(const Key('side'))).dx, 700 - 440);
  });

  testWidgets('700: tapping outside the 440 pane dismisses it', (tester) async {
    await _size(tester, 700);
    var dismissed = false;
    await tester.pumpWidget(
      _frame(open: true, side: true, onSideDismiss: () => dismissed = true),
    );
    await tester.tapAt(const Offset(100, 200));
    expect(dismissed, isTrue);
  });

  testWidgets('1000: list 320 and content; side replaces content', (
    tester,
  ) async {
    await _size(tester, 1000);
    await tester.pumpWidget(_frame(open: true));
    expect(tester.getSize(find.byKey(const Key('list'))).width, 320);
    expect(_visible(tester, const Key('content')), isTrue);
    await tester.pumpWidget(_frame(open: true, side: true));
    expect(_visible(tester, const Key('content')), isFalse);
    expect(_visible(tester, const Key('side')), isTrue);
  });

  testWidgets('1300: rail 72, list 340, content max 760 and side 400', (
    tester,
  ) async {
    await _size(tester, 1300);
    await tester.pumpWidget(_frame());
    expect(find.text('Nothing open'), findsOneWidget);
    await tester.pumpWidget(_frame(open: true));
    expect(tester.getTopLeft(find.byKey(const Key('list'))).dx, 72 + 1);
    expect(tester.getSize(find.byKey(const Key('list'))).width, 340);
    expect(tester.getSize(find.byKey(const Key('content'))).width, 760);
    await tester.pumpWidget(_frame(open: true, side: true));
    expect(tester.getSize(find.byKey(const Key('side'))).width, 400);
    expect(_visible(tester, const Key('side')), isTrue);
    expect(tester.getTopRight(find.byKey(const Key('side'))).dx, 1300);
  });

  testWidgets('a layout change keeps the draft and the list position', (
    tester,
  ) async {
    await _size(tester, 1300);
    await tester.pumpWidget(_frame(open: true));
    await tester.enterText(find.byKey(const Key('draft')), 'half a thought');
    await tester.drag(find.byKey(const Key('list')), const Offset(0, -480));
    await tester.pump();
    final listState = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('list')),
        matching: find.byType(Scrollable),
      ),
    );
    final offset = listState.position.pixels;
    expect(offset, greaterThan(0));
    for (final width in [1000.0, 700.0, 375.0, 1300.0]) {
      await _size(tester, width);
      expect(find.text('half a thought'), findsOneWidget, reason: '$width');
    }
    final after = tester.state<ScrollableState>(
      find.descendant(
        of: find.byKey(const Key('list')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(identical(after, listState), isTrue);
    expect(after.position.pixels, offset);
  });

  testWidgets('dark theme builds the frame', (tester) async {
    await _size(tester, 1000);
    await tester.pumpWidget(
      MaterialApp(
        theme: PircTheme.of(Brightness.dark),
        home: AdaptiveScaffold(
          destinations: _destinations,
          selectedIndex: 1,
          onDestinationSelected: (_) {},
          list: const SizedBox(),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
