import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_ui/pirc_ui.dart';

/// Sample data for the component tests and goldens (English, so the golden
/// fonts cover every glyph).
abstract final class Samples {
  static Widget avatar(
    String name,
    int color, {
    AvatarSize size = AvatarSize.standard,
    AvatarStatus status = AvatarStatus.none,
    bool me = false,
  }) => Avatar(name: name, color: color, size: size, status: status, me: me);

  /// One section per component, on the grouped page colour where the E
  /// screens use it.
  static List<(String, Widget)> sections(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final grouped = colors['surface.grouped'];
    return [
      (
        'Avatar',
        Wrap(
          spacing: 16,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.end,
          children: [
            for (var c = 1; c <= 5; c++) avatar('Pot $c', c),
            avatar('Me', 1, me: true),
            avatar('Butler', 1, size: AvatarSize.sm),
            avatar('Butler', 2, size: AvatarSize.md),
            avatar('Butler', 3, size: AvatarSize.lg),
          ],
        ),
      ),
      (
        'AvatarStatus',
        Wrap(
          spacing: 24,
          children: [
            avatar('Tester', 2, status: AvatarStatus.working),
            avatar(
              'Tester',
              2,
              size: AvatarSize.md,
              status: AvatarStatus.working,
            ),
            avatar(
              'Tester',
              2,
              size: AvatarSize.sm,
              status: AvatarStatus.working,
            ),
            avatar('Travel', 4, status: AvatarStatus.unavailable),
            avatar('Butler', 1),
          ],
        ),
      ),
      (
        'GroupAvatar',
        const Wrap(
          spacing: 24,
          children: [
            GroupAvatar(
              first: AvatarFace('Butler', color: 1),
              second: AvatarFace('Researcher', color: 3),
            ),
            GroupAvatar(
              small: true,
              first: AvatarFace('Travel', color: 4),
              second: AvatarFace('Butler', color: 1),
            ),
          ],
        ),
      ),
      (
        'ChatRow',
        Column(
          children: [
            ChatRow(
              divider: false,
              avatar: avatar('Butler', 1),
              title: 'Butler',
              role: 'Lead',
              time: '09:00',
              preview: 'Start "Tidy the API docs"?',
              previewWarning: true,
              badge: const ChatBadge.attention('2'),
              onTap: () {},
            ),
            ChatRow(
              avatar: const GroupAvatar(
                first: AvatarFace('Butler', color: 1),
                second: AvatarFace('Researcher', color: 3),
              ),
              title: 'Mobile team',
              role: '4 members',
              time: '10:34',
              preview: 'Tester: OK, I opened a work session.',
              badge: const ChatBadge.unread('3'),
              selected: true,
              onTap: () {},
            ),
            ChatRow(
              avatar: avatar('Tester', 2, status: AvatarStatus.working),
              title: 'Tester with a very long name that does not fit',
              role: 'Testing',
              time: '10:42',
              preview: 'I passed the nightly problem to you',
              previousSelected: true,
              onTap: () {},
            ),
            ChatRow(
              title: 'Check the nightly test',
              role: 'From Tester',
              time: '10:42',
              preview: 'CI-runner · Waiting for your answer',
              onTap: () {},
            ),
          ],
        ),
      ),
      (
        'Bubble',
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          spacing: 10,
          children: [
            Bubble(
              avatar: avatar('Butler', 1, size: AvatarSize.sm),
              text: 'Morning. Three nightly tests failed; Tester is on it.',
            ),
            Bubble(
              avatar: avatar('Butler', 1, size: AvatarSize.sm),
              name: 'Butler',
              hostLabel: 'Host',
              text: TextSpan(
                children: [
                  Bubble.mention(context, '@Tester'),
                  const TextSpan(text: ' can you rerun only the failures?'),
                ],
              ),
              meta: 'Woke Tester',
            ),
            const Bubble.mine(text: 'Yes, rerun only the failed cases.'),
            Bubble(
              avatar: avatar('Tester', 2, size: AvatarSize.sm),
              name: 'Me (Tester)',
              rightSide: true,
              tint: 2,
              text: 'All three were time-outs.',
            ),
            const HandoffLine(
              parts: [
                HandoffPart.name('Butler'),
                HandoffPart('asked'),
                HandoffPart.name('Tester'),
                HandoffPart('to handle "Check the nightly test"'),
              ],
            ),
          ],
        ),
      ),
      (
        'WorkCard',
        Padding(
          padding: const EdgeInsets.only(left: 36),
          child: WorkCard(
            title: 'Check the nightly test',
            subtitle: 'Coordinated by Tester · CI-runner · Waiting for you',
            onTap: () {},
          ),
        ),
      ),
      (
        'MentionPopover',
        MentionPopover<String>(
          header: 'Who? Each uses only its own permissions and budget',
          onSelected: (_) {},
          options: [
            MentionOption(
              value: 'butler',
              avatar: avatar('Butler', 1, size: AvatarSize.md),
              name: 'Butler',
              hostLabel: 'Host',
              detail: r'Can start work · $4.20 / $20 this month',
            ),
            MentionOption(
              value: 'researcher',
              avatar: avatar('Researcher', 3, size: AvatarSize.md),
              name: 'Researcher',
              detail: 'Reads pirc mobile · cannot start work',
            ),
          ],
        ),
      ),
      (
        'ProfileHeader',
        ColoredBox(
          color: grouped,
          child: ProfileHeader(
            avatar: avatar('Butler', 1, size: AvatarSize.lg),
            name: 'Butler',
            intro: 'Keeps track of what needs your decision.',
            chips: const [
              ProfileChip('Observing', dot: 'accent.default'),
              ProfileChip('Hosts 1 group'),
            ],
            actions: [
              ProfileAction(
                icon: LucideIcons.messageCircle,
                label: 'Message',
                onTap: () {},
              ),
              ProfileAction(
                icon: LucideIcons.pause,
                label: 'Pause',
                onTap: () {},
              ),
              ProfileAction(
                icon: LucideIcons.arrowLeftRight,
                label: 'Hand over',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
      (
        'HandoverItem',
        DecoratedBox(
          decoration: BoxDecoration(
            color: colors['surface.layer'],
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            children: [
              HandoverItem(
                first: true,
                kind: 'Duty',
                title: 'Sum up what needs your decision each morning',
                subtitle: 'Daily 09:00 · summary',
                toLabel: 'To',
                target: HandoverTarget(
                  label: 'Tester',
                  avatar: Avatar.custom(
                    name: 'Tester',
                    color: 2,
                    diameter: 26,
                    fontSize: 11,
                  ),
                  onTap: () {},
                ),
                fit: HandoverFit.ok,
                fitText: 'Enough permissions',
                onExpand: () {},
              ),
              HandoverItem(
                kind: 'Watch',
                title: 'Watch pirc mobile for stuck work',
                subtitle: 'Suggest after 30 minutes stuck',
                checked: true,
                onChecked: (_) {},
                fit: HandoverFit.narrowed,
                fitText: 'Tester cannot read Laptop; it watches CI-runner only',
                onExpand: () {},
                expanded: true,
                details: const ['Started 11/02', 'Last noticed 10:12'],
              ),
              HandoverItem(
                kind: 'Hosts',
                title: 'Mobile team',
                subtitle: '4 members · pirc mobile',
                toLabel: 'To',
                target: HandoverTarget(
                  label: 'No one',
                  none: true,
                  onTap: () {},
                ),
                fit: HandoverFit.stop,
                fitText: 'The group loses its host',
              ),
              const HandoverItem(
                kind: 'Reminder',
                title: 'Remind about the dentist',
                checked: false,
                fit: HandoverFit.muted,
                fitText: 'Not handed over',
              ),
            ],
          ),
        ),
      ),
      (
        'ModelAccess',
        Wrap(
          spacing: 8,
          children: [
            ModelAccess(label: 'Direct', onTap: () {}),
            ModelAccess(label: 'Ask you', onTap: () {}),
          ],
        ),
      ),
      (
        'LogRow',
        Column(
          children: [
            LogRow(
              avatar: avatar('Butler', 1, size: AvatarSize.sm),
              who: 'Butler',
              target: 'wants work · Claude Opus · High',
              time: '10:45',
              tag: const LogTag('Needs approval', tone: LogTagTone.attention),
              quote:
                  'Compare three API specs: Sonnet compared twice and disagreed',
              onTap: () {},
            ),
            LogRow(
              avatar: avatar('Tester', 2, size: AvatarSize.sm),
              who: 'Tester',
              target: '→ Butler',
              time: '10:42',
              tag: const LogTag('Message', tone: LogTagTone.direct),
              quote: 'All three failures are time-outs.',
              onTap: () {},
            ),
            LogRow(
              avatar: avatar('Butler', 1, size: AvatarSize.sm),
              who: 'Butler',
              target: '→ Tester',
              time: '10:40',
              tag: const LogTag('Handed over'),
              quote: 'Check the nightly test: find the cause first.',
            ),
          ],
        ),
      ),
      (
        'PovBar',
        Column(
          children: [
            PovBar(
              avatar: avatar('Tester', 2, size: AvatarSize.sm),
              title: "See Tester's point of view",
              subtitle: 'Its chat list and records · read only',
              onTap: () {},
            ),
            PovReadOnlyBar(
              text: "Read only: Tester's records",
              actionLabel: 'Open the work',
              onAction: () {},
            ),
          ],
        ),
      ),
      (
        'Stats',
        ColoredBox(
          color: grouped,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            spacing: 12,
            children: [
              const SizedBox(height: 4),
              const StatGrid(
                values: [
                  StatValue('1.24B', 'Tokens in all'),
                  StatValue(r'$182', 'Cost (estimate)'),
                  StatValue('41', 'Days in a row'),
                  StatValue('6', 'Pots'),
                ],
              ),
              StatCard(
                title: 'Tokens per day',
                tabs: const ['Day', 'Week', 'Total'],
                onTab: (_) {},
                child: Heatmap(
                  levels: [
                    for (var i = 0; i < 18 * 7; i++) (i * 7 + i ~/ 5) % 5,
                  ],
                  monthLabels: const ['Aug', 'Sep', 'Oct', 'Nov'],
                  lessLabel: 'Less',
                  moreLabel: 'More',
                  semanticLabel: 'Tokens per day, last 18 weeks',
                ),
              ),
              const StatCard(
                child: WeeklyBars(
                  values: [3, 5, 4, 8, 6, 9, 7, 12, 10, 8, 11, 6],
                  labels: ['12 weeks ago', 'This week 190M'],
                  semanticLabel: 'Tokens per week, last 12 weeks',
                ),
              ),
              const StatCard(
                child: CumulativeArea(
                  totals: [0, 10, 18, 40, 52, 80, 96, 124],
                  labels: ['Mar', 'Now 1.24B'],
                  semanticLabel: 'Running total of tokens',
                ),
              ),
              StatCard(
                child: BarList(
                  items: [
                    BarListItem(
                      leading: avatar('Butler', 1, size: AvatarSize.sm),
                      name: 'Butler',
                      value: r'$4.20',
                      fraction: 0.8,
                    ),
                    const BarListItem(
                      leading: BarListMark('CO'),
                      name: 'Claude Opus',
                      value: '82M',
                      fraction: 0.35,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    ];
  }
}
