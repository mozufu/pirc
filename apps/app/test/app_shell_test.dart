import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/calendar/calendar_screen.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/render_bridge.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/harness.dart';

FakeGateway _gateway() {
  final g = FakeGateway();
  g.json['GET /api/sessions'] = (_) => {'sessions': <Object?>[]};
  g.json['GET /api/activity'] = (_) => {'activity': <Object?>[]};
  g.json['GET /api/pots'] = (_) => {
    'pots': [
      {
        'id': 'p1',
        'state': 'active',
        'status': 'idle',
        'profile': {'name': 'Tester', 'avatarColor': 2},
      },
    ],
  };
  g.json['GET /api/pots/p1/view'] = (_) => {
    'potId': 'p1',
    'threads': <Object?>[],
    'sent': <Object?>[],
    'instructions': <Object?>[],
  };
  return g;
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required double width,
  String location = '/chat',
}) => pumpApp(tester, gateway: _gateway(), width: width, location: location);

/// Tester's point of view, the list filtered to it.
const _pov = '/activity?pot=p1&open=pov:p1';

Future<void> _resize(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 900);
  await tester.pumpAndSettle();
}

void main() {
  for (final (width, layout) in [
    (375.0, PircLayout.compact),
    (700.0, PircLayout.portrait),
    (1000.0, PircLayout.landscape),
    (1300.0, PircLayout.desktop),
  ]) {
    testWidgets('$width wide uses the $layout layout', (tester) async {
      await _pump(tester, width: width, location: _pov);
      expect(find.byType(AdaptiveScaffold), findsOneWidget);
      expect(
        find.byType(NavigationBar),
        layout == PircLayout.compact ? findsOneWidget : findsNothing,
      );
      expect(find.text("Tester's point of view"), findsOneWidget);
      final listShown = find
          .text('Nothing matches this filter.')
          .evaluate()
          .isNotEmpty;
      expect(
        listShown,
        layout == PircLayout.landscape || layout == PircLayout.desktop,
      );
    });
  }

  testWidgets('a layout change keeps the tab and the open item', (
    tester,
  ) async {
    await _pump(tester, width: 1300, location: _pov);
    for (final width in [1000.0, 700.0, 375.0, 1300.0]) {
      await _resize(tester, width);
      expect(
        find.text("Tester's point of view"),
        findsOneWidget,
        reason: '$width',
      );
      final scaffold = tester.widget<AdaptiveScaffold>(
        find.byType(AdaptiveScaffold),
      );
      expect(scaffold.selectedIndex, AppTab.activity.index, reason: '$width');
    }
  });

  testWidgets('tabs switch and keep their own open item', (tester) async {
    await _pump(tester, width: 1300, location: _pov);
    await tester.tap(find.text('Calendar'));
    await tester.pumpAndSettle();
    expect(find.byType(CalendarScreen), findsOneWidget);
    await tester.tap(find.text('Activity'));
    await tester.pumpAndSettle();
    expect(find.text("Tester's point of view"), findsOneWidget);
  });

  testWidgets('back closes the open item on a phone', (tester) async {
    await _pump(tester, width: 375, location: _pov);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text("Tester's point of view"), findsNothing);
    // Back to the list filtered to the pot.
    expect(
      find.textContaining("See Tester's point of view", findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('Traditional Chinese labels the tabs and the renderer', (
    tester,
  ) async {
    final container = await _pump(tester, width: 1300);
    container.read(languageProvider.notifier).select('zh-TW');
    await tester.pumpAndSettle();
    for (final label in ['聊天', '工作', '動態', '行事曆']) {
      expect(find.text(label), findsWidgets, reason: label);
    }
    expect(RenderL10n.language, 'zh-TW');
    container.read(languageProvider.notifier).select('en');
    await tester.pumpAndSettle();
    expect(RenderL10n.language, 'en');
  });

  testWidgets('light and dark both build', (tester) async {
    final container = await _pump(tester, width: 1000);
    for (final mode in [ThemeMode.light, ThemeMode.dark]) {
      container.read(themeModeProvider.notifier).select(mode);
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AdaptiveScaffold));
      expect(
        Theme.of(context).brightness,
        mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
      expect(Theme.of(context).extension<RenderColors>(), isNotNull);
    }
  });

  test('the renderer gets every color name it reads', () {
    // Every `colors['…']` the renderer reads, from its source.
    final names = <String>{};
    for (final file
        in Directory('../../packages/pirc_render/lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))) {
      for (final match in RegExp(
        r"colors\['([a-zA-Z.-]+)'\]",
      ).allMatches(file.readAsStringSync())) {
        names.add(match[1]!);
      }
    }
    expect(names, contains('web.bg-subtle'));
    for (final brightness in Brightness.values) {
      final colors = renderColors(brightness).values;
      for (final name in names) {
        expect(colors, contains(name), reason: '$brightness $name');
      }
    }
  });

  test('catalogs have the same messages and placeholders', () {
    Map<String, dynamic> read(String name) =>
        jsonDecode(File('lib/l10n/app_$name.arb').readAsStringSync())
            as Map<String, dynamic>;
    final en = read('en'), zh = read('zh');
    Iterable<String> keys(Map<String, dynamic> arb) =>
        arb.keys.where((key) => !key.startsWith('@'));
    expect(keys(zh).toSet(), keys(en).toSet());
    List<String> args(String value) =>
        RegExp(r'\{\w+\}').allMatches(value).map((m) => m[0]!).toList()..sort();
    for (final key in keys(en)) {
      expect(args(zh[key] as String), args(en[key] as String), reason: key);
    }
  });
}
