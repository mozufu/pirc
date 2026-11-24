import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_render/src/html_date.dart';

NativeHtmlDateState _dateState(String source) =>
    NativeHtmlDateState.fromHtml(source);

NativeHtmlDateDescriptor _control(
  NativeHtmlDateState state,
  String source,
  String id,
) {
  final fragment = html.parseFragment(state.annotateHtml(source));
  return state.resolveControl(fragment.querySelector('#$id')!)!;
}

Widget _page(
  NativeHtmlDateState state,
  String source, {
  double scale = 1,
  Locale? hostLocale,
}) {
  final control = _control(state, source, 'visit');
  return MaterialApp(
    // The date field intentionally uses the host locale, not this page locale.
    locale: const Locale('en', 'US'),
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: NativeHtmlDateInput(
                state: state,
                control: control,
                textStyle: const TextStyle(fontSize: 16, color: Colors.black),
                hostLocale: hostLocale,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

ValueKey<String> _calendarButtonKey(String key) =>
    ValueKey('native-html-date-calendar-$key');

void main() {
  testWidgets('host locale controls field order and localized popup labels', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" name="visit" value="2024-06-15" '
        'min="2024-06-01" max="2024-06-30" step="7">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    tester.platformDispatcher.localeTestValue = const Locale('zh', 'TW');
    addTearDown(tester.platformDispatcher.clearLocaleTestValue);
    addTearDown(state.dispose);

    await tester.pumpWidget(_page(state, source));
    await tester.pumpAndSettle();

    final year = find.byKey(
      ValueKey('native-html-date-segment-${control.key}-year'),
    );
    final month = find.byKey(
      ValueKey('native-html-date-segment-${control.key}-month'),
    );
    final day = find.byKey(
      ValueKey('native-html-date-segment-${control.key}-day'),
    );
    expect(tester.getRect(year).left, lessThan(tester.getRect(month).left));
    expect(tester.getRect(month).left, lessThan(tester.getRect(day).left));
    expect(tester.widget<TextField>(year).decoration?.hintText, '年');
    expect(tester.widget<TextField>(month).decoration?.hintText, '月');
    expect(tester.widget<TextField>(day).decoration?.hintText, '日');
    expect(tester.widget<TextField>(year).controller?.text, '2024');
    expect(tester.widget<TextField>(month).controller?.text, '06');
    expect(tester.widget<TextField>(day).controller?.text, '15');
    expect(find.byTooltip('選擇日期'), findsOneWidget);

    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey('native-html-date-calendar-popup')),
      findsOneWidget,
    );
    expect(find.text('2024年06月'), findsOneWidget);
    expect(find.text('清除'), findsOneWidget);
    expect(find.text('今天'), findsOneWidget);
    expect(find.text('日'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('anchored calendar applies only selectable dates and clear', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" name="visit" value="2024-06-15" '
        'min="2024-06-01" max="2024-06-30" step="7">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _page(state, source, hostLocale: const Locale('zh', 'TW')),
    );
    await tester.pumpAndSettle();
    final button = find.byKey(_calendarButtonKey(control.key));
    final buttonRect = tester.getRect(button);
    await tester.tap(button);
    await tester.pumpAndSettle();

    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    expect(popup, findsOneWidget);
    final popupRect = tester.getRect(popup);
    final anchorGap = popupRect.bottom <= buttonRect.top
        ? buttonRect.top - popupRect.bottom
        : popupRect.top - buttonRect.bottom;
    expect(anchorGap.abs(), lessThanOrEqualTo(8.1));
    expect(popupRect.left, greaterThanOrEqualTo(0));
    expect(popupRect.right, lessThanOrEqualTo(tester.view.physicalSize.width));

    // June 20 is in range but misses the seven-day step from min=June 1.
    await tester.tap(find.text('20'));
    await tester.pumpAndSettle();
    expect(state.valueFor(control.key), '2024-06-15');
    expect(popup, findsOneWidget);

    await tester.tap(find.text('22'));
    await tester.pumpAndSettle();
    expect(state.valueFor(control.key), '2024-06-22');
    expect(popup, findsNothing);

    await tester.tap(button);
    await tester.pumpAndSettle();
    await tester.tap(find.text('清除'));
    await tester.pumpAndSettle();
    expect(state.valueFor(control.key), isEmpty);
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'calendar keyboard and outside tap dismiss without changing date',
    (tester) async {
      const source =
          '<input id="visit" type="date" name="visit" value="2024-06-15">';
      final state = _dateState(source);
      final control = _control(state, source, 'visit');
      addTearDown(state.dispose);

      await tester.pumpWidget(
        _page(state, source, hostLocale: const Locale('zh', 'TW')),
      );
      await tester.pumpAndSettle();
      final popup = find.byKey(
        const ValueKey('native-html-date-calendar-popup'),
      );
      await tester.tap(find.byKey(_calendarButtonKey(control.key)));
      await tester.pumpAndSettle();
      expect(popup, findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(state.valueFor(control.key), '2024-06-15');

      await tester.tap(find.byKey(_calendarButtonKey(control.key)));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(state.valueFor(control.key), '2024-06-16');
      expect(popup, findsNothing);

      await tester.tap(find.byKey(_calendarButtonKey(control.key)));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(popup, findsNothing);
      expect(state.valueFor(control.key), '2024-06-16');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('hiding the owning document closes its calendar without edit', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" name="visit" value="2024-06-15">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    final visible = ValueNotifier(true);
    addTearDown(state.dispose);
    addTearDown(visible.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (context, isVisible, _) => TickerMode(
            enabled: isVisible,
            child: Offstage(
              offstage: !isVisible,
              child: Scaffold(
                body: Align(
                  alignment: Alignment.topLeft,
                  child: NativeHtmlDateInput(
                    state: state,
                    control: control,
                    textStyle: const TextStyle(fontSize: 16),
                    hostLocale: const Locale('zh', 'TW'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();
    expect(popup, findsOneWidget);
    final lateSelect = tester
        .widget<InkWell>(
          find
              .ancestor(of: find.text('16'), matching: find.byType(InkWell))
              .first,
        )
        .onTap;
    expect(lateSelect, isNotNull);

    visible.value = false;
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    lateSelect!();
    await tester.pumpAndSettle();
    expect(state.valueFor(control.key), '2024-06-15');

    visible.value = true;
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('year selector respects the HTML-supported year range', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" value="0001-01-01" '
        'min="0001-01-01" max="0001-01-31">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _page(state, source, hostLocale: const Locale('zh', 'TW')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();

    expect(find.text('0001年01月'), findsOneWidget);
    final previous = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '上個月',
      ),
    );
    final next = tester.widget<IconButton>(
      find.byWidgetPredicate(
        (widget) => widget is IconButton && widget.tooltip == '下個月',
      ),
    );
    expect(previous.onPressed, isNull);
    expect(next.onPressed, isNull);

    await tester.tap(find.text('0001年01月'));
    await tester.pumpAndSettle();
    final picker = find.byKey(
      const ValueKey('native-html-date-calendar-popup'),
    );
    final yearOne = find.descendant(of: picker, matching: find.text('1'));
    expect(yearOne, findsOneWidget);
    await tester.tap(yearOne);
    await tester.pumpAndSettle();
    expect(find.text('0001年01月'), findsOneWidget);
    expect(state.valueFor(control.key), '0001-01-01');
    expect(tester.takeException(), isNull);
  });

  testWidgets('year selector scrolls the active year into view', (
    tester,
  ) async {
    const source = '<input id="visit" type="date" value="2024-06-15">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _page(state, source, hostLocale: const Locale('zh', 'TW')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();
    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    await tester.tap(
      find.descendant(of: popup, matching: find.text('2024年06月')),
    );
    await tester.pumpAndSettle();
    final activeYear = find.descendant(of: popup, matching: find.text('2024'));
    expect(activeYear, findsOneWidget);
    await tester.tap(activeYear);
    await tester.pumpAndSettle();
    expect(find.text('2024年06月'), findsOneWidget);
    expect(state.valueFor(control.key), '2024-06-15');
    expect(tester.takeException(), isNull);
  });

  testWidgets('reset or source replacement invalidates an open calendar', (
    tester,
  ) async {
    const source =
        '<input id="visit" type="date" name="visit" value="2024-06-15">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    await tester.pumpWidget(
      _page(state, source, hostLocale: const Locale('zh', 'TW')),
    );
    await tester.pumpAndSettle();
    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();
    state.updateSegment(control.key, NativeHtmlDateSegment.day, '22');
    state.resetDefaults();
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(state.valueFor(control.key), '2024-06-15');

    state.dispose();
    final replacement = _dateState(
      '<input id="visit" type="date" name="visit" value="2024-06-08">',
    );
    await tester.pumpWidget(
      _page(
        replacement,
        '<input id="visit" type="date" name="visit" value="2024-06-08">',
        hostLocale: const Locale('zh', 'TW'),
      ),
    );
    await tester.pumpAndSettle();
    expect(popup, findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    replacement.dispose();
  });

  testWidgets('scaled calendar stays inside narrow viewport', (tester) async {
    const source = '<input id="visit" type="date" value="2024-06-15">';
    final state = _dateState(source);
    final control = _control(state, source, 'visit');
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(state.dispose);

    await tester.pumpWidget(
      _page(state, source, scale: 2, hostLocale: const Locale('zh', 'TW')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(_calendarButtonKey(control.key)));
    await tester.pumpAndSettle();

    final popup = find.byKey(const ValueKey('native-html-date-calendar-popup'));
    final rect = tester.getRect(popup);
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(390));
    expect(rect.top, greaterThanOrEqualTo(0));
    expect(rect.bottom, lessThanOrEqualTo(844));
    expect(tester.takeException(), isNull);
  });

  testWidgets('date width reserves the maximum year unless max narrows it', (
    tester,
  ) async {
    const source =
        '<input id="open" type="date" value="2024-06-15">'
        '<input id="bounded" type="date" value="2024-06-15" max="2024-12-31">';
    final state = _dateState(source);
    final open = _control(state, source, 'open');
    final bounded = _control(state, source, 'bounded');
    addTearDown(state.dispose);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                NativeHtmlDateInput(
                  state: state,
                  control: open,
                  textStyle: const TextStyle(fontSize: 16),
                  hostLocale: const Locale('en', 'US'),
                ),
                NativeHtmlDateInput(
                  state: state,
                  control: bounded,
                  textStyle: const TextStyle(fontSize: 16),
                  hostLocale: const Locale('en', 'US'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final openSize = tester.getSize(
      find.byKey(ValueKey('native-html-date-${open.key}')),
    );
    final boundedSize = tester.getSize(
      find.byKey(ValueKey('native-html-date-${bounded.key}')),
    );
    final twoGlyphs = TextPainter(
      text: const TextSpan(
        text: '000000',
        style: TextStyle(fontSize: 16, height: kTextHeightNone),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final fourGlyphs = TextPainter(
      text: const TextSpan(
        text: '0000',
        style: TextStyle(fontSize: 16, height: kTextHeightNone),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    expect(
      openSize.width - boundedSize.width,
      closeTo(twoGlyphs.width - fourGlyphs.width, 0.01),
    );
    expect(tester.takeException(), isNull);
  });
}
