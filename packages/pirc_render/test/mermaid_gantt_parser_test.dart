import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/src/mermaid/gantt_model.dart';
import 'package:pirc_render/src/mermaid/gantt_parser.dart';

const _fixturePath = '../../fixtures/mobile-parity/mermaid-gantt.json';

void main() {
  group('native Mermaid Gantt parser', () {
    test(
      'resolves sections, statuses, exclusions, dates, and dependencies',
      () {
        final diagram = parseNativeMermaidGantt('''
gantt
title Delivery plan
dateFormat YYYY-MM-DD
axisFormat %b %d
todayMarker off
excludes weekends, 2024-01-08
section Build
Build API : done, api, 2024-01-05, 2d
QA : active, qa, after api, 3d
Ship marker : milestone, release, 2024-01-12, 0d
section Ship
Release : crit, release-task, 2024-01-15, 2024-01-16
''');

        expect(diagram.title, 'Delivery plan');
        expect(diagram.dateFormat, 'YYYY-MM-DD');
        expect(diagram.axisFormat, '%b %d');
        expect(diagram.todayMarkerEnabled, isFalse);
        expect(diagram.excludesWeekends, isTrue);
        expect(diagram.excludedDates, contains(DateTime.utc(2024, 1, 8)));
        expect(diagram.sections.map((section) => section.name), [
          'Build',
          'Ship',
        ]);
        expect(diagram.tasks.map((task) => task.label), [
          'Build API ',
          'QA ',
          'Ship marker ',
          'Release ',
        ]);

        final api = diagram.tasks[0];
        final qa = diagram.tasks[1];
        final milestone = diagram.tasks[2];
        final release = diagram.tasks[3];
        expect(api.statuses, contains(NativeMermaidGanttTaskStatus.done));
        expect(api.start, DateTime.utc(2024, 1, 5));
        expect(api.end, DateTime.utc(2024, 1, 10));
        expect(qa.statuses, contains(NativeMermaidGanttTaskStatus.active));
        expect(qa.dependencies, ['api']);
        expect(qa.start, api.end);
        expect(qa.end, DateTime.utc(2024, 1, 15));
        expect(qa.renderEnd, DateTime.utc(2024, 1, 13));
        expect(milestone.isMilestone, isTrue);
        expect(milestone.start, milestone.end);
        expect(
          release.statuses,
          contains(NativeMermaidGanttTaskStatus.critical),
        );
        expect(release.sectionIndex, 1);
        expect(release.start, DateTime.utc(2024, 1, 15));
        expect(release.end, DateTime.utc(2024, 1, 16));
      },
    );

    test('supports task lines without explicit IDs and exact UTC times', () {
      final diagram = parseNativeMermaidGantt('''
gantt
dateFormat YYYY-MM-DD HH:mm
todayMarker off
section Deploy
Compile : 2024-03-10 08:00, 1h
Publish : active, 2024-03-10 09:00, 30m
''');
      expect(diagram.tasks[0].hasExplicitId, isFalse);
      expect(diagram.tasks[1].hasExplicitId, isFalse);
      expect(diagram.tasks[0].id, isNot(diagram.tasks[1].id));
      expect(diagram.tasks[0].start, DateTime.utc(2024, 3, 10, 8));
      expect(diagram.tasks[0].end, DateTime.utc(2024, 3, 10, 9));
      expect(diagram.tasks[1].end, DateTime.utc(2024, 3, 10, 9, 30));
    });

    test('resolves multiple dependencies after declarations', () {
      final diagram = parseNativeMermaidGantt('''
gantt
todayMarker off
section Work
Final : final, after first second, 1d
First : first, 2024-02-01, 2d
Second : second, 2024-02-01, 4d
''');
      final finalTask = diagram.tasks.first;
      expect(finalTask.dependencies, ['first', 'second']);
      expect(finalTask.start, DateTime.utc(2024, 2, 5));
      expect(finalTask.end, DateTime.utc(2024, 2, 6));
    });

    test('creates a default section for tasks without a section header', () {
      final diagram = parseNativeMermaidGantt('''
gantt
todayMarker off
Task : 2024-03-01, 1d
''');
      expect(diagram.sections, hasLength(1));
      expect(diagram.sections.single.name, isEmpty);
      expect(diagram.tasks.single.sectionIndex, 0);
    });

    test('rejects unsupported date formats, directives, IDs, and broken graphs', () {
      final cases = [
        'gantt\ndateFormat DD/MM/YYYY\nsection A\nTask : 2024/01/01, 1d',
        'gantt\ntodayMarker off\nsection A\nTask : active, 2024-01-01, 1d\nclick Task href "x"',
        'gantt\ntodayMarker off\nsection A\nTask : task, 2024-01-01, 1d\nAgain : task, 2024-01-02, 1d',
        'gantt\ntodayMarker off\nsection A\nTask : after missing, 1d',
        'gantt\ntodayMarker off\nsection A\nA : a, after b, 1d\nB : b, after a, 1d',
        'gantt\ntodayMarker off\nsection A\nTask : 2024-02-30, 1d',
        'gantt\ntodayMarker off\nsection A\nTask : milestone, 2024-01-01, 1d',
      ];
      for (final source in cases) {
        expect(
          () => parseNativeMermaidGantt(source),
          throwsFormatException,
          reason: source,
        );
      }
    });

    test('parses every pinned browser Gantt fixture case', () {
      final fixture = jsonDecode(File(_fixturePath).readAsStringSync()) as Map;
      final fixedNow = DateTime.parse(fixture['fixedNow'] as String);
      final cases = fixture['cases'] as List;
      for (final item in cases.cast<Map>()) {
        final fenced = item['source'] as String;
        final source = fenced
            .replaceFirst(RegExp(r'^```mermaid\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), '');
        final diagram = parseNativeMermaidGantt(source, clock: fixedNow);
        expect(diagram.tasks, isNotEmpty, reason: item['id'] as String);
      }

      final mainSource = (cases[0] as Map)['source'] as String;
      final main = parseNativeMermaidGantt(
        mainSource
            .replaceFirst(RegExp(r'^```mermaid\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), ''),
        clock: fixedNow,
      );
      expect(main.tasks.map((task) => task.id), [
        'kickoff',
        'spec',
        'review',
        'approval',
        'task1',
        'range',
        'impl',
        'qa',
        'short',
        'minutes',
        'week',
        'release',
        'task2',
      ]);
      expect(main.tasks[1].label, 'Specification ');
      expect(main.tasks[2].start, DateTime.utc(2026, 7, 9));
      expect(main.tasks[2].end, DateTime.utc(2026, 7, 13));
      expect(main.tasks[2].renderEnd, DateTime.utc(2026, 7, 11));
      expect(main.tasks[6].end, DateTime.utc(2026, 7, 15));
      expect(main.tasks[6].renderEnd, DateTime.utc(2026, 7, 15));
      expect(main.tasks[10].end, DateTime.utc(2026, 7, 22));
      expect(main.tasks[12].previousTaskId, 'release');
      expect(main.tasks[12].start, DateTime.utc(2026, 7, 16, 4, 30));
      expect(main.tasks[12].start, main.tasks[11].end);
      expect(main.tasks[12].end, DateTime.utc(2026, 7, 17, 4, 30));

      final clockSource = (cases[1] as Map)['source'] as String;
      final clock = parseNativeMermaidGantt(
        clockSource
            .replaceFirst(RegExp(r'^```mermaid\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), ''),
        clock: fixedNow,
      );
      expect(clock.tasks.first.start, DateTime.utc(2026, 7, 6, 9));
      expect(clock.tasks.last.id, 'task1');

      final inclusiveSource = (cases[2] as Map)['source'] as String;
      final inclusive = parseNativeMermaidGantt(
        inclusiveSource
            .replaceFirst(RegExp(r'^```mermaid\s*'), '')
            .replaceFirst(RegExp(r'\s*```$'), ''),
        clock: fixedNow,
      );
      expect(inclusive.inclusiveEndDates, isTrue);
      expect(inclusive.tasks.last.end, DateTime.utc(2026, 7, 10));
    });

    test('enforces size limits', () {
      expect(
        () =>
            parseNativeMermaidGantt('gantt\n${List.filled(50001, 'x').join()}'),
        throwsFormatException,
      );
      expect(
        () => parseNativeMermaidGantt(
          'gantt\nsection A\n${List.filled(501, 'Task : 2024-01-01, 1d').join('\n')}',
        ),
        throwsFormatException,
      );
    });
  });
}
