import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_app/src/chat/pot_draft.dart';
import 'package:pirc_app/src/format.dart';
import 'package:pirc_app/src/preferences.dart';
import 'package:pirc_app/src/router.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/fonts.dart';
import 'support/harness.dart';
import 'support/me_fixtures.dart';
import 'support/work_fixtures.dart';

final _picture = Uint8List.fromList([137, 80, 78, 71, 1, 2, 3]);

Future<(FakeGateway, ProviderContainer)> _pump(
  WidgetTester tester,
  MeFixture fixture, {
  String location = '/me',
  double width = 375,
  double height = 1800,
}) async {
  final gateway = fixture.install();
  final container = await pumpApp(
    tester,
    gateway: gateway,
    width: width,
    height: height,
    location: location,
    overrides: [
      clockProvider.overrideWithValue(() => fixedNow),
      avatarPicturePickerProvider.overrideWithValue(() async => _picture),
    ],
    reduceMotion: true,
  );
  return (gateway, container);
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> _tapKey(WidgetTester tester, String key) =>
    _tap(tester, find.byKey(ValueKey(key)));

/// The six numbers as shown, value then label.
List<(String, String)> _stats(WidgetTester tester) => [
  for (final v in tester.widget<StatGrid>(find.byType(StatGrid)).values)
    (v.value, v.label),
];

FilledButton _save(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const ValueKey('me-edit-save')));

void main() {
  appTest('the six numbers come from the shown range and this month', (
    tester,
  ) async {
    await _pump(tester, MeFixture());
    expect(find.text('Ice Bear'), findsOneWidget);
    expect(_stats(tester), [
      ('5.3M', 'Tokens in total'),
      ('2.5M', 'Most tokens in a day'),
      (r'$38.20', 'Spent this month'),
      ('10', 'Requests this month'),
      ('6 days', 'Longest streak'),
      ('3 days', 'Current streak'),
    ]);
    expect(
      tester.widget<StatGrid>(find.byType(StatGrid)).columns,
      2,
      reason: 'two columns on phones',
    );
  });

  for (final (width, weeks, from, columns) in [
    (375.0, 18, '2026-07-26', 2),
    (700.0, 26, '2026-05-31', 3),
    (1000.0, 30, '2026-05-03', 3),
    (1300.0, 40, '2026-02-22', 3),
  ]) {
    appTest('$width wide: $weeks weeks from $from, $columns columns', (
      tester,
    ) async {
      final (gateway, _) = await _pump(
        tester,
        MeFixture(),
        width: width,
        height: 1200,
      );
      final reads = [
        for (final r in gateway.sent('GET', '/api/usage')) r.query,
      ];
      expect(reads, anyElement(equals({'from': from, 'to': '2026-11-25'})));
      expect(
        reads,
        anyElement(equals({'from': '2026-11-01', 'to': '2026-11-25'})),
      );
      final heatmap = tester.widget<Heatmap>(find.byType(Heatmap));
      expect(heatmap.levels, hasLength(weeks * 7));
      expect(heatmap.semanticLabel, 'Tokens per day, last $weeks weeks');
      expect(tester.widget<StatGrid>(find.byType(StatGrid)).columns, columns);
    });
  }

  appTest('the heatmap: five levels, a tip per day, nothing after today', (
    tester,
  ) async {
    await _pump(tester, MeFixture());
    final heatmap = tester.widget<Heatmap>(find.byType(Heatmap));
    // The last week runs Sunday Nov 22 to Saturday Nov 28.
    expect(heatmap.levels.sublist(heatmap.levels.length - 7), [
      0,
      1,
      4,
      2,
      0,
      0,
      0,
    ]);
    expect(heatmap.tips.sublist(heatmap.tips.length - 7), [
      'Nov 22 · no use',
      'Nov 23 · 500K tokens',
      'Nov 24 · 2.5M tokens',
      'Nov 25 · 1M tokens',
      '',
      '',
      '',
    ]);
    expect(heatmap.monthLabels, ['Aug', 'Sep', 'Oct', 'Nov']);
    expect(find.byTooltip('Nov 24 · 2.5M tokens'), findsOneWidget);
  });

  appTest('12 weekly bars and the running total', (tester) async {
    await _pump(tester, MeFixture());
    await _tap(tester, find.text('Week'));
    expect(find.text('Each week'), findsOneWidget);
    final bars = tester.widget<WeeklyBars>(find.byType(WeeklyBars));
    expect(bars.values, hasLength(12));
    expect(bars.values.last, 4000000);
    expect(bars.values[bars.values.length - 2], 300000);
    expect(bars.values[bars.values.length - 3], 1000000);
    expect(bars.labels, ['12 weeks ago', 'This week 4M']);
    await _tap(tester, find.text('Total'));
    expect(find.text('Running total'), findsOneWidget);
    final area = tester.widget<CumulativeArea>(find.byType(CumulativeArea));
    expect(area.totals.last, 5300000);
    expect(area.totals, hasLength(18 * 7 - 3), reason: 'up to today');
    expect(area.labels, ['Aug', 'Now 5.3M']);
  });

  appTest('this month by who and by model', (tester) async {
    await _pump(tester, MeFixture());
    final who = tester
        .widget<BarList>(
          find.descendant(
            of: find.byKey(const ValueKey('me-by-who')),
            matching: find.byType(BarList),
          ),
        )
        .items;
    expect(
      [for (final i in who) (i.name, i.value)],
      [
        ('Ice Bear (you)', '410M'),
        ('Butler', '160M'),
        ('Tester', '110M'),
        ('Researcher', '50M'),
        ('Travel buddy', '15M'),
        ('Deleted pot', '5M'),
      ],
    );
    expect(who[1].fraction, closeTo(160 / 410, 0.001));
    final models = tester
        .widget<BarList>(
          find.descendant(
            of: find.byKey(const ValueKey('me-by-model')),
            matching: find.byType(BarList),
          ),
        )
        .items;
    expect(
      [for (final i in models) (i.name, i.value)],
      [
        ('Claude Sonnet', '68%'),
        ('GPT-5', '17%'),
        ('Claude Opus', '9%'),
        ('Ollama · qwen3', '6%'),
      ],
    );
  });

  appTest('subscription money shows only with API-equivalent prices, '
      'marked as an estimate', (tester) async {
    await _pump(tester, MeFixture());
    expect(find.byKey(const ValueKey('me-estimate')), findsNothing);
    expect(find.textContaining(r'$12.00'), findsNothing);
    expect(find.textContaining('estimate'), findsNothing);
    expect(_stats(tester)[2], (r'$38.20', 'Spent this month'));
    await disposeApp(tester);

    await _pump(tester, MeFixture()..apiEquivalent = true);
    expect(
      find.text(
        r'Subscription use this month at API prices: about $12.00. '
        'This is an estimate, not money spent.',
      ),
      findsOneWidget,
    );
    expect(_stats(tester)[2], (
      r'$38.20',
      'Spent this month',
    ), reason: 'the estimate is never added to the money spent');
  });

  appTest('the drawer row shows the name and opens this page', (tester) async {
    final (_, container) = await _pump(tester, MeFixture(), location: '/chat');
    await tester.tap(find.byTooltip('Open the menu'));
    await tester.pumpAndSettle();
    final row = find.byKey(const ValueKey('drawer-me'));
    expect(
      find.descendant(of: row, matching: find.text('Ice Bear')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.text(r'This month $38.20 · 3-day streak'),
      ),
      findsOneWidget,
    );
    await _tap(tester, row);
    expect(find.byKey(const ValueKey('me')), findsOneWidget);
    expect(find.text('Overview'), findsOneWidget);
    // Back returns to the Chat tab.
    await _tap(tester, find.byTooltip('Back'));
    expect(find.byKey(const ValueKey('me')), findsNothing);
    expect(
      container.read(routerProvider).routeInformationProvider.value.uri.path,
      '/chat',
    );
  });

  group('edit profile', () {
    appTest('the name is sent trimmed with the revision', (tester) async {
      final fixture = MeFixture();
      await _pump(tester, fixture);
      await _tapKey(tester, 'me-edit');
      expect(find.text('Edit profile'), findsOneWidget);
      expect(_save(tester).onPressed, isNull, reason: 'nothing changed');
      final name = find.byKey(const ValueKey('me-edit-name'));
      await tester.enterText(name, '   ');
      await tester.pumpAndSettle();
      expect(find.text('A name is 1 to 60 characters.'), findsOneWidget);
      expect(_save(tester).onPressed, isNull);
      await tester.enterText(name, 'x' * 61);
      await tester.pumpAndSettle();
      expect(_save(tester).onPressed, isNull);
      await tester.enterText(name, '  Polar  ');
      await tester.pumpAndSettle();
      await _tapKey(tester, 'me-edit-save');
      expect(fixture.patches, [
        {'revision': 2, 'displayName': 'Polar'},
      ]);
      expect(find.text('Edit profile'), findsNothing);
      // Read again: the page and the drawer use the new name.
      expect(find.text('Polar'), findsOneWidget);
      expect(find.text('Polar (you)'), findsOneWidget);
    });

    appTest('a colour', (tester) async {
      final fixture = MeFixture();
      await _pump(tester, fixture);
      await _tapKey(tester, 'me-edit');
      await _tapKey(tester, 'swatch-2');
      final preview = tester.widget<Avatar>(
        find.descendant(
          of: find.byKey(const ValueKey('me-edit-avatar')),
          matching: find.byType(Avatar),
        ),
      );
      expect(preview.color, 2);
      await _tapKey(tester, 'me-edit-save');
      expect(fixture.patches, [
        {'revision': 2, 'avatarColor': 2},
      ]);
    });

    appTest('a picture is uploaded, then saved by its ID', (tester) async {
      final fixture = MeFixture();
      final (gateway, _) = await _pump(tester, fixture);
      await _tapKey(tester, 'me-edit');
      await _tapKey(tester, 'swatch-upload');
      expect(fixture.uploads, hasLength(1));
      expect(fixture.uploads.single.bytes, _picture);
      expect(fixture.uploads.single.contentType, 'image/png');
      expect(fixture.patches, isEmpty, reason: 'saved only with Save');
      await _tapKey(tester, 'me-edit-save');
      expect(fixture.patches, [
        {'revision': 2, 'avatarImage': 'img-me'},
      ]);
      expect(gateway.sent('GET', '/api/images/img-me'), isNotEmpty);
    });

    appTest('a picture is removed with null', (tester) async {
      final fixture = MeFixture()
        ..profile = {
          'displayName': 'Ice Bear',
          'avatarColor': 4,
          'avatarImage': 'img-old',
          'revision': 2,
        };
      await _pump(tester, fixture);
      await _tapKey(tester, 'me-edit');
      await _tapKey(tester, 'swatch-upload');
      await _tap(tester, find.text('Remove the picture'));
      expect(fixture.uploads, isEmpty);
      await _tapKey(tester, 'me-edit-save');
      expect(fixture.patches, [
        {'revision': 2, 'avatarImage': null},
      ]);
    });

    appTest('a 409 reads the profile again and keeps the edit', (tester) async {
      final fixture = MeFixture()..conflictNext = true;
      await _pump(tester, fixture);
      await _tapKey(tester, 'me-edit');
      await tester.enterText(
        find.byKey(const ValueKey('me-edit-name')),
        'Polar',
      );
      await tester.pumpAndSettle();
      await _tapKey(tester, 'me-edit-save');
      expect(find.byKey(const ValueKey('me-conflict')), findsOneWidget);
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('me-edit-name')))
            .controller!
            .text,
        'Polar',
      );
      await _tapKey(tester, 'me-edit-save');
      expect(fixture.patches.last, {'revision': 3, 'displayName': 'Polar'});
      expect(find.text('Edit profile'), findsNothing);
    });
  });

  group('golden images', () {
    for (final (name, location) in [
      ('me_week', '/me?chart=week'),
      ('me_total', '/me?chart=total'),
      ('me_edit', '/me'),
    ]) {
      for (final width in goldenWidths) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          testWidgets('$name ${width.toInt()} ${mode.name}', (tester) async {
            await tester.runAsync(loadGoldenFonts);
            final (_, container) = await _pump(
              tester,
              MeFixture.e28(),
              location: location,
              width: width,
              height: goldenHeight(width),
            );
            container.read(themeModeProvider.notifier).select(mode);
            await tester.pumpAndSettle();
            if (name == 'me_edit') {
              await tester.tap(find.byKey(const ValueKey('me-edit')));
              await tester.pumpAndSettle();
            }
            await expectLater(
              find.byType(MaterialApp),
              matchesGoldenFile(
                'goldens/${name}_${width.toInt()}_${mode.name}.png',
              ),
            );
            await disposeApp(tester);
          }, tags: ['golden']);
        }
      }
    }
  });
}
