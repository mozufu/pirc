import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_ui/pirc_ui.dart';

import 'support/gallery.dart';

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  Brightness brightness = Brightness.light,
  bool still = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(375, 900);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MediaQuery(
      data: MediaQueryData(
        size: const Size(375, 900),
        disableAnimations: still,
      ),
      child: MaterialApp(
        theme: PircTheme.of(brightness),
        home: Scaffold(body: SingleChildScrollView(child: child)),
      ),
    ),
  );
}

Color _fill(WidgetTester tester, Finder finder) {
  final box = tester.widget<Container>(finder).decoration! as BoxDecoration;
  return box.color!;
}

void main() {
  final light = PircTheme.colors(Brightness.light);

  group('Avatar', () {
    testWidgets('sizes, colours, the initial and me', (tester) async {
      await _pump(
        tester,
        Wrap(
          children: [
            for (final size in AvatarSize.values)
              Avatar(key: ValueKey(size), name: 'butler', color: 3, size: size),
            const Avatar(key: Key('me'), name: 'Ana', me: true),
            const Avatar(key: Key('bad'), name: 'X', color: 9),
          ],
        ),
      );
      for (final (size, d) in [
        (AvatarSize.sm, 28.0),
        (AvatarSize.md, 36.0),
        (AvatarSize.standard, 48.0),
        (AvatarSize.lg, 88.0),
      ]) {
        expect(tester.getSize(find.byKey(ValueKey(size))), Size(d, d));
      }
      expect(find.text('B'), findsNWidgets(4));
      Finder disc(Key key) => find
          .descendant(of: find.byKey(key), matching: find.byType(Container))
          .first;
      expect(
        _fill(tester, disc(const ValueKey(AvatarSize.sm))),
        light['avatar.3'],
      );
      expect(_fill(tester, disc(const Key('me'))), light['fill.hoverStrong']);
      expect(_fill(tester, disc(const Key('bad'))), light['avatar.1']);
    });

    testWidgets('status: a pill when working, a dot when unavailable', (
      tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: [
            Avatar(
              key: Key('w'),
              name: 'T',
              status: AvatarStatus.working,
              statusLabel: 'Working',
            ),
            Avatar(
              key: Key('w-md'),
              name: 'T',
              size: AvatarSize.md,
              status: AvatarStatus.working,
            ),
            Avatar(
              key: Key('w-sm'),
              name: 'T',
              size: AvatarSize.sm,
              status: AvatarStatus.working,
            ),
            Avatar(
              key: Key('off'),
              name: 'T',
              status: AvatarStatus.unavailable,
              statusLabel: 'Unavailable',
            ),
            Avatar(key: Key('none'), name: 'T'),
          ],
        ),
      );
      Size pill(Key key) => tester.getSize(
        find
            .descendant(of: find.byKey(key), matching: find.byType(Container))
            .at(1),
      );
      expect(pill(const Key('w')).height, 16);
      expect(pill(const Key('w-md')).height, 14);
      expect(pill(const Key('w-sm')).height, 16);
      expect(
        tester
            .getRect(
              find
                  .descendant(
                    of: find.byKey(const Key('w-sm')),
                    matching: find.byType(Container),
                  )
                  .at(1),
            )
            .right,
        tester.getRect(find.byKey(const Key('w-sm'))).right + 8,
      );
      expect(pill(const Key('off')), const Size(12, 12));
      expect(
        find.descendant(
          of: find.byKey(const Key('none')),
          matching: find.byType(Container),
        ),
        findsOneWidget,
      );
      expect(find.bySemanticsLabel('T, Working'), findsOneWidget);
      expect(find.bySemanticsLabel('T, Unavailable'), findsOneWidget);
    });

    testWidgets('the working dots pulse unless motion is reduced', (
      tester,
    ) async {
      await _pump(
        tester,
        const Avatar(name: 'T', status: AvatarStatus.working),
        still: false,
      );
      List<double> opacities() => [
        for (final o in tester.widgetList<Opacity>(find.byType(Opacity)))
          o.opacity,
      ];
      final first = opacities();
      await tester.pump(const Duration(milliseconds: 300));
      expect(opacities(), isNot(first));
      await _pump(
        tester,
        const Avatar(name: 'T', status: AvatarStatus.working),
      );
      expect(opacities(), [1, 1, 1]);
    });

    testWidgets('an image that fails leaves the colour', (tester) async {
      await _pump(
        tester,
        Avatar(name: 'T', color: 2, image: MemoryImage(Uint8List(0))),
      );
      await tester.pumpAndSettle();
      expect(find.text('T'), findsOneWidget);
    });
  });

  testWidgets('GroupAvatar stacks two members, the second on top', (
    tester,
  ) async {
    await _pump(
      tester,
      const GroupAvatar(
        first: AvatarFace('Butler', color: 1),
        second: AvatarFace('Researcher', color: 3),
      ),
    );
    expect(tester.getSize(find.byType(GroupAvatar)), const Size(48, 48));
    final a = tester.getRect(find.text('B'));
    final r = tester.getRect(find.text('R'));
    expect(a.center.dx < r.center.dx && a.center.dy < r.center.dy, isTrue);
    expect(find.bySemanticsLabel('Butler, Researcher'), findsOneWidget);
  });

  testWidgets('GroupAvatar takes other sizes (the 88 profile)', (tester) async {
    await _pump(
      tester,
      const GroupAvatar(
        first: AvatarFace('Butler', color: 1),
        second: AvatarFace('Researcher', color: 3),
        dimension: 88,
        faceDiameter: 58,
        fontSize: 22,
      ),
    );
    expect(tester.getSize(find.byType(GroupAvatar)), const Size(88, 88));
    final faces = find.descendant(
      of: find.byType(GroupAvatar),
      matching: find.byType(Avatar),
    );
    expect(tester.getSize(faces.first), const Size(58, 58));
    expect(tester.widget<Text>(find.text('B')).style?.fontSize, 22);
  });

  group('ChatRow', () {
    testWidgets('72 with an avatar, 64 without; badges and taps', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        Column(
          children: [
            ChatRow(
              key: const Key('a'),
              avatar: const Avatar(name: 'B'),
              title: 'Butler',
              role: 'Lead',
              time: '09:00',
              preview: 'Start?',
              badge: const ChatBadge.attention('2'),
              onTap: () => taps++,
            ),
            const ChatRow(
              key: Key('n'),
              title: 'Work',
              preview: 'Laptop',
              badge: ChatBadge.unread('3'),
            ),
          ],
        ),
      );
      expect(tester.getSize(find.byKey(const Key('a'))).height, 72);
      expect(tester.getSize(find.byKey(const Key('n'))).height, 64);
      final attention = tester.widget<Container>(
        find
            .ancestor(of: find.text('2'), matching: find.byType(Container))
            .first,
      );
      expect(
        (attention.decoration! as BoxDecoration).color,
        light['status.warningSoft'],
      );
      final unread = tester.widget<Container>(
        find
            .ancestor(of: find.text('3'), matching: find.byType(Container))
            .first,
      );
      expect(
        (unread.decoration! as BoxDecoration).color,
        light['text.primary'],
      );
      await tester.tap(find.byKey(const Key('a')));
      expect(taps, 1);
    });

    testWidgets('a warning preview uses text.warning', (tester) async {
      await _pump(
        tester,
        const ChatRow(title: 'B', preview: 'Waits', previewWarning: true),
      );
      expect(
        tester.widget<Text>(find.text('Waits')).style!.color,
        light['text.warning'],
      );
    });

    testWidgets('a selected row hides its own and the next hairline', (
      tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: [
            ChatRow(key: Key('a'), title: 'A', selected: true),
            ChatRow(key: Key('b'), title: 'B', previousSelected: true),
            ChatRow(key: Key('c'), title: 'C'),
          ],
        ),
      );
      int lines() => tester
          .widgetList<CustomPaint>(find.byType(CustomPaint))
          .where((paint) => '${paint.painter?.runtimeType}' == '_TopLine')
          .length;
      expect(lines(), 1);
    });
  });

  group('Bubble', () {
    testWidgets('mine is on the right without avatar or name', (tester) async {
      await _pump(tester, const Bubble.mine(text: 'Hello'));
      expect(tester.getRect(find.text('Hello')).right, greaterThan(300));
    });

    testWidgets("another's is on the left with its name and host tag", (
      tester,
    ) async {
      await _pump(
        tester,
        const Bubble(
          avatar: Avatar(name: 'B', size: AvatarSize.sm),
          name: 'Butler',
          hostLabel: 'Host',
          text: 'Hi',
        ),
      );
      expect(tester.getRect(find.text('Hi')).left, lessThan(100));
      expect(find.text('Host'), findsOneWidget);
      expect(tester.getSize(find.byType(Bubble)).width, lessThanOrEqualTo(375));
    });

    testWidgets('in a point of view the pot is on the right, tinted 18 %', (
      tester,
    ) async {
      await _pump(
        tester,
        const Bubble(
          avatar: Avatar(name: 'T', size: AvatarSize.sm),
          rightSide: true,
          tint: 2,
          text: 'Mine',
        ),
      );
      final avatar = tester.getRect(find.byType(Avatar));
      final text = tester.getRect(find.text('Mine'));
      expect(avatar.left, greaterThan(text.right));
      final bubble = tester.widget<Container>(
        find
            .ancestor(of: find.text('Mine'), matching: find.byType(Container))
            .first,
      );
      expect(
        (bubble.decoration! as BoxDecoration).color,
        Color.lerp(light['surface.page'], light['avatar.2'], 0.18),
      );
    });
  });

  testWidgets('MentionPopover reports the picked member', (tester) async {
    String? picked;
    await _pump(
      tester,
      MentionPopover<String>(
        header: 'Who?',
        onSelected: (v) => picked = v,
        options: const [
          MentionOption(
            value: 'b',
            avatar: Avatar(name: 'B', size: AvatarSize.md),
            name: 'Butler',
            hostLabel: 'Host',
            detail: 'Can start work',
          ),
          MentionOption(
            value: 'r',
            avatar: Avatar(name: 'R', size: AvatarSize.md),
            name: 'Researcher',
            detail: 'Read only',
          ),
        ],
      ),
    );
    await tester.tap(find.text('Researcher'));
    expect(picked, 'r');
    final box = tester.widget<Container>(
      find
          .descendant(
            of: find.byType(MentionPopover<String>),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (box.decoration! as BoxDecoration).boxShadow,
      PircElevation.popLight,
    );
  });

  testWidgets('ProfileHeader shows the actions; a disabled one does nothing', (
    tester,
  ) async {
    var messages = 0;
    await _pump(
      tester,
      ProfileHeader(
        avatar: const Avatar(name: 'B', size: AvatarSize.lg),
        name: 'Butler',
        intro: 'Keeps track',
        chips: const [ProfileChip('Observing', dot: 'accent.default')],
        actions: [
          ProfileAction(
            icon: Icons.chat,
            label: 'Message',
            onTap: () => messages++,
          ),
          const ProfileAction(icon: Icons.pause, label: 'Pause', onTap: null),
        ],
      ),
    );
    await tester.tap(find.text('Message'));
    await tester.tap(find.text('Pause'));
    expect(messages, 1);
    expect(find.text('Observing'), findsOneWidget);
  });

  group('HandoverItem', () {
    testWidgets('each fit has its colour', (tester) async {
      await _pump(
        tester,
        const Column(
          children: [
            HandoverItem(
              kind: 'K',
              title: 'a',
              fit: HandoverFit.ok,
              fitText: 'ok',
            ),
            HandoverItem(
              kind: 'K',
              title: 'b',
              fit: HandoverFit.narrowed,
              fitText: 'narrowed',
            ),
            HandoverItem(
              kind: 'K',
              title: 'c',
              fit: HandoverFit.stop,
              fitText: 'stop',
            ),
            HandoverItem(
              kind: 'K',
              title: 'd',
              fit: HandoverFit.muted,
              fitText: 'muted',
            ),
          ],
        ),
      );
      for (final (text, token) in [
        ('ok', 'text.success'),
        ('narrowed', 'text.warning'),
        ('stop', 'status.danger'),
        ('muted', 'text.muted'),
      ]) {
        expect(
          tester.widget<Text>(find.text(text)).style!.color,
          light[token],
          reason: text,
        );
      }
      for (final glyph in ['✓', '!', '■', '·']) {
        expect(find.text(glyph), findsOneWidget, reason: glyph);
      }
    });

    testWidgets('the check toggles and the chevron opens the details', (
      tester,
    ) async {
      bool? checked;
      var opened = 0;
      await _pump(
        tester,
        HandoverItem(
          kind: 'Duty',
          title: 'Watch',
          subtitle: 'sub',
          checked: false,
          checkLabel: 'Hand over this item',
          onChecked: (v) => checked = v,
          onExpand: () => opened++,
          details: const ['detail'],
        ),
      );
      expect(find.text('detail'), findsNothing);
      await tester.tap(find.bySemanticsLabel('Hand over this item'));
      expect(checked, isTrue);
      await tester.tap(find.text('Watch'));
      expect(opened, 1);
      await _pump(
        tester,
        const HandoverItem(
          kind: 'Duty',
          title: 'Watch',
          details: ['detail'],
          expanded: true,
        ),
      );
      expect(find.text('detail'), findsOneWidget);
    });

    testWidgets('the details box holds an action under the lines', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        HandoverItem(
          kind: 'Duty',
          title: 'Watch',
          details: const ['Needs: more'],
          detailsAction: TextButton(
            onPressed: () => taps++,
            child: const Text('Adjust'),
          ),
          expanded: true,
        ),
      );
      expect(
        tester.getTopLeft(find.text('Adjust')).dy,
        greaterThan(tester.getBottomLeft(find.text('Needs: more')).dy),
      );
      await tester.tap(find.text('Adjust'));
      expect(taps, 1);
      await _pump(
        tester,
        HandoverItem(
          kind: 'Duty',
          title: 'Watch',
          detailsAction: TextButton(
            onPressed: () {},
            child: const Text('Adjust'),
          ),
        ),
      );
      expect(find.text('Adjust'), findsNothing);
    });

    testWidgets('the receiver chip takes another fill', (tester) async {
      await _pump(
        tester,
        const HandoverTarget(label: 'Give everything to…', color: Colors.red),
      );
      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(HandoverTarget),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.color, Colors.red);
    });

    testWidgets('the receiver chip; "no one" has no avatar', (tester) async {
      var taps = 0;
      await _pump(
        tester,
        HandoverItem(
          kind: 'Hosts',
          title: 'Group',
          toLabel: 'To',
          target: HandoverTarget(
            label: 'No one',
            none: true,
            avatar: const Avatar(name: 'X'),
            onTap: () => taps++,
          ),
        ),
      );
      expect(find.byType(Avatar), findsNothing);
      await tester.tap(find.text('No one'));
      expect(taps, 1);
    });

    testWidgets('the meta row keeps its top padding inside 36', (tester) async {
      await _pump(
        tester,
        const HandoverItem(kind: 'Duty', title: 'Watch', subtitle: 'Daily'),
      );
      expect(tester.getSize(find.byKey(const Key('handover-to'))).height, 36);
    });
  });

  testWidgets('ModelAccess is a button with its label', (tester) async {
    var taps = 0;
    await _pump(tester, ModelAccess(label: 'Ask you', onTap: () => taps++));
    expect(tester.getSize(find.byType(ModelAccess)).height, 32);
    await tester.tap(find.text('Ask you'));
    expect(taps, 1);
  });

  testWidgets('LogRow and LogTag tones', (tester) async {
    await _pump(
      tester,
      const LogRow(
        avatar: Avatar(name: 'B', size: AvatarSize.sm),
        who: 'Butler',
        target: '→ Tester',
        time: '10:40',
        tag: LogTag('Needs approval', tone: LogTagTone.attention),
        quote: 'Quote',
      ),
    );
    final tag = tester.widget<Container>(
      find
          .ancestor(
            of: find.text('Needs approval'),
            matching: find.byType(Container),
          )
          .first,
    );
    expect(
      (tag.decoration! as BoxDecoration).color,
      light['status.warningSoft'],
    );
    expect(find.text('→ Tester'), findsOneWidget);
  });

  testWidgets('PovBar and the read-only bar act', (tester) async {
    var pov = 0;
    var open = 0;
    await _pump(
      tester,
      Column(
        children: [
          PovBar(
            avatar: const Avatar(name: 'T', size: AvatarSize.sm),
            title: 'See',
            subtitle: 'sub',
            onTap: () => pov++,
          ),
          PovReadOnlyBar(
            text: 'Read only',
            actionLabel: 'Open',
            onAction: () => open++,
          ),
        ],
      ),
    );
    await tester.tap(find.textContaining('See', findRichText: true));
    await tester.tap(find.text('Open'));
    expect((pov, open), (1, 1));
  });

  group('Stats', () {
    testWidgets('the grid has the given columns', (tester) async {
      await _pump(
        tester,
        const StatGrid(
          columns: 3,
          values: [
            StatValue('1', 'a'),
            StatValue('2', 'b'),
            StatValue('3', 'c'),
            StatValue('4', 'd'),
          ],
        ),
      );
      expect(
        tester.getRect(find.text('1')).top,
        tester.getRect(find.text('3')).top,
      );
      expect(
        tester.getRect(find.text('4')).top,
        greaterThan(tester.getRect(find.text('1')).top),
      );
    });

    testWidgets('card tabs report the picked tab', (tester) async {
      int? tab;
      await _pump(
        tester,
        StatCard(
          title: 'Tokens',
          tabs: const ['Day', 'Week'],
          onTab: (i) => tab = i,
          child: const SizedBox(height: 10),
        ),
      );
      await tester.tap(find.text('Week'));
      expect(tab, 1);
    });

    testWidgets('weekly bars are relative to the largest week', (tester) async {
      await _pump(
        tester,
        const WeeklyBars(
          values: [0, 5, 10],
          labels: ['a', 'b'],
          semanticLabel: 'w',
        ),
      );
      final bars = tester
          .widgetList<Container>(
            find.descendant(
              of: find.byType(WeeklyBars),
              matching: find.byType(Container),
            ),
          )
          .toList();
      final heights = [
        for (final b in bars) tester.getSize(find.byWidget(b)).height,
      ];
      expect(heights, [2, 60, 120]);
    });

    testWidgets('the heatmap uses five levels; the bar list its fractions', (
      tester,
    ) async {
      await _pump(
        tester,
        const Column(
          children: [
            Heatmap(
              levels: [0, 1, 2, 3, 4, 9, 0],
              monthLabels: ['Nov'],
              lessLabel: 'Less',
              moreLabel: 'More',
              semanticLabel: 'h',
            ),
            BarList(
              items: [
                BarListItem(
                  leading: BarListMark('CO'),
                  name: 'Opus',
                  value: '1',
                  fraction: 0.5,
                ),
              ],
            ),
          ],
        ),
      );
      expect(find.bySemanticsLabel('h'), findsOneWidget);
      expect(
        heatColors(PircColorTokens.of(tester.element(find.byType(Heatmap)))),
        hasLength(5),
      );
      final fill = tester.widget<FractionallySizedBox>(
        find.byType(FractionallySizedBox),
      );
      expect(fill.widthFactor, 0.5);
    });
  });

  group('GroupedList', () {
    testWidgets('rows are 56 high with a hairline between them', (
      tester,
    ) async {
      var taps = 0;
      await _pump(
        tester,
        Column(
          children: [
            const GroupLabel('Basic'),
            GroupedList(
              children: [
                GroupedRow(
                  key: const Key('a'),
                  title: 'One',
                  onTap: () => taps++,
                ),
                const GroupedRow(
                  key: Key('b'),
                  title: 'Two',
                  subtitle: 'Off',
                  enabled: false,
                ),
              ],
            ),
            const GroupNote('A note', error: true),
          ],
        ),
      );
      expect(tester.getSize(find.byKey(const Key('a'))).height, 56);
      expect(tester.getTopLeft(find.byKey(const Key('a'))).dx, 16);
      expect(find.text('Basic'), findsOneWidget);
      await tester.tap(find.text('One'));
      await tester.tap(find.text('Two'));
      expect(taps, 1);
      expect(
        tester.widget<Text>(find.text('A note')).style?.color,
        light['status.danger'],
      );
    });

    testWidgets('the switch toggles; disabled, it does nothing', (
      tester,
    ) async {
      final values = <bool>[];
      await _pump(
        tester,
        Column(
          children: [
            PircSwitch(
              key: const Key('on'),
              value: true,
              onChanged: values.add,
            ),
            const PircSwitch(key: Key('locked'), value: true, onChanged: null),
          ],
        ),
      );
      expect(tester.getSize(find.byKey(const Key('on'))), const Size(52, 32));
      await tester.tap(find.byKey(const Key('on')));
      await tester.tap(find.byKey(const Key('locked')));
      expect(values, [false]);
    });

    testWidgets('Segmented, PillChip and RadioRow report their picks', (
      tester,
    ) async {
      final picked = <String>[];
      await _pump(
        tester,
        Column(
          children: [
            Segmented<String>(
              items: const [
                SegmentedItem('all', 'All'),
                SegmentedItem('off', 'Off'),
              ],
              selected: 'all',
              onSelected: picked.add,
            ),
            Row(
              children: [
                PillChip(
                  key: const Key('chip'),
                  label: 'Rigorous',
                  selected: true,
                  onTap: () => picked.add('chip'),
                ),
              ],
            ),
            GroupedList(
              children: [
                RadioRow(
                  title: 'Only answer you',
                  selected: false,
                  onTap: () => picked.add('radio'),
                ),
              ],
            ),
          ],
        ),
      );
      await tester.tap(find.text('Off'));
      await tester.tap(find.text('Rigorous'));
      await tester.tap(find.text('Only answer you'));
      expect(picked, ['off', 'chip', 'radio']);
      expect(tester.getSize(find.byKey(const Key('chip'))).height, 38);
      expect(
        tester.getSize(find.byKey(const Key('chip'))).width,
        lessThan(200),
      );
    });
  });

  testWidgets('the gallery builds in light and dark without overflow', (
    tester,
  ) async {
    for (final brightness in Brightness.values) {
      await _pump(
        tester,
        Builder(
          builder: (context) => Column(
            children: [for (final (_, w) in Samples.sections(context)) w],
          ),
        ),
        brightness: brightness,
      );
      expect(tester.takeException(), isNull);
    }
  });
}
