import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_mobile/live/app.dart';
import 'package:pirc_mobile/live/conversation_composer.dart';
import 'package:pirc_mobile/live/conversation_header.dart';
import 'package:pirc_mobile/live/conversation_timeline.dart';
import 'package:pirc_mobile/live/files_pane.dart';
import 'package:pirc_mobile/live/interaction_card.dart';
import 'package:pirc_mobile/live/composer_dock.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/session_sidebar.dart';
import 'package:pirc_mobile/live/side_panel.dart';
import 'package:pirc_mobile/live/timeline_tools.dart' show TimelineRun;
import 'package:pirc_render/src/code_block.dart';

import '../../test/live_test.dart' show FakeGateway, theme;
import 'capture_fonts.dart';

Json _map(dynamic value) => value is Map
    ? value.map((key, value) => MapEntry('$key', value))
    : <String, dynamic>{};

List<Json> _maps(dynamic value) =>
    value is List ? value.map(_map).toList() : <Json>[];

Map<String, dynamic>? _bounds(WidgetTester tester, Finder finder) {
  if (finder.evaluate().isEmpty) return null;
  final rect = tester.getRect(finder.first);
  return {
    'left': rect.left,
    'top': rect.top,
    'right': rect.right,
    'bottom': rect.bottom,
    'width': rect.width,
    'height': rect.height,
  };
}

int _textCount(WidgetTester tester, String text) =>
    find.textContaining(text, findRichText: true).evaluate().length;

List<double> _selectedValues(String variable, List<dynamic> defaults) {
  final configured = Platform.environment[variable];
  if (configured == null || configured.trim().isEmpty) {
    return defaults.map((value) => (value as num).toDouble()).toList();
  }
  return configured
      .split(',')
      .map((value) => double.parse(value.trim()))
      .toList();
}

Map<String, dynamic> _styleEvidence(TextSpan root) {
  var coloredTextRuns = 0;
  final colors = <String>{};
  void visit(InlineSpan span) {
    if (span is! TextSpan) return;
    final color = span.style?.color;
    if (span.text?.trim().isNotEmpty == true && color != null) {
      coloredTextRuns++;
      colors.add(color.toString());
    }
    for (final child in span.children ?? const <InlineSpan>[]) {
      visit(child);
    }
  }

  visit(root);
  return {
    'coloredTextRuns': coloredTextRuns,
    'distinctColors': colors.length,
    'colors': colors.toList()..sort(),
  };
}

bool _isComposerSurface(Widget widget) {
  if (widget is! Container || widget.decoration is! BoxDecoration) {
    return false;
  }
  final decoration = widget.decoration as BoxDecoration;
  final radius = decoration.borderRadius;
  if (radius is! BorderRadius || !(decoration.boxShadow?.isNotEmpty ?? false)) {
    return false;
  }
  return radius.topLeft == radius.topRight &&
      radius.topLeft == radius.bottomLeft &&
      radius.topLeft == radius.bottomRight;
}

bool _intersects(Map<String, dynamic>? first, Map<String, dynamic>? second) {
  if (first == null || second == null) return false;
  final rect = Rect.fromLTRB(
    (first['left'] as num).toDouble(),
    (first['top'] as num).toDouble(),
    (first['right'] as num).toDouble(),
    (first['bottom'] as num).toDouble(),
  );
  final clip = Rect.fromLTRB(
    (second['left'] as num).toDouble(),
    (second['top'] as num).toDouble(),
    (second['right'] as num).toDouble(),
    (second['bottom'] as num).toDouble(),
  );
  return rect.overlaps(clip);
}

class _ConversationGateway extends FakeGateway {
  _ConversationGateway(this.fixture) {
    final session = _map(fixture['session']);
    final model = _maps(fixture['models']).first;
    _preferences = {
      ..._map(fixture['ui']),
      'appearance': 'system',
      'detailsOpen': false,
      'sidebarCollapsed': false,
      'panelWidth': 360,
    };
    snapshot = {
      'session': session,
      'runnerEpoch': 'conversation-screen-fixture',
      'messages': _maps(fixture['messages']),
      'interactions': _maps(_map(fixture['state'])['interactions']),
      'widgets': _map(_map(fixture['state'])['widgets']),
      'statuses': _map(_map(fixture['state'])['statuses']),
      'queue': _maps(_map(fixture['state'])['queue']),
      'run': _map(fixture['state'])['run'],
      'modelId': model['id'],
      'modelProvider': model['provider'],
      'thinking': 'medium',
    };
    drafts['${session['id']}'] = '${fixture['draft']}';
  }

  final Json fixture;
  late Json _preferences;
  final requests = <Json>[];
  final answers = <Json>[];

  @override
  dynamic normal(String method, Json args) {
    if (method == 'answer') {
      final question = _maps(_map(fixture['state'])['interactions']).single;
      if (args['sessionId'] != _map(fixture['session'])['id'] ||
          args['interactionId'] != question['id'] ||
          args['epoch'] != question['epoch'] ||
          jsonEncode(args['answer']) !=
              jsonEncode({
                'values': ['tablet'],
              })) {
        throw StateError('Unexpected outgoing fixture answer: $args');
      }
      answers.add(Map<String, dynamic>.of(args));
      return null;
    }
    if (method == 'boot') {
      return {
        'origin': 'https://gateway.example',
        'clientId': 'conversation-screen-fixture',
        'pairingStamp': 'conversation-screen-fixture-pairing-stamp',
        'targetSession': _map(fixture['session'])['id'],
        'onboardingComplete': true,
      };
    }
    if (method == 'preferences') return Map<String, dynamic>.of(_preferences);
    if (method == 'savePreferences') {
      _preferences = {..._preferences, ...args};
      return Map<String, dynamic>.of(_preferences);
    }
    if (method == 'request') {
      final path = '${args['path']}';
      requests.add({'path': path, 'method': args['method'] ?? 'GET'});
      if (path == '/api/sessions') {
        final session = _map(fixture['session']);
        return {
          'sessions': [
            {
              ...session,
              'updatedAt': DateTime.parse(
                '${session['lastActivityAt']}',
              ).millisecondsSinceEpoch,
              'runStatus': session['runnerStatus'] ?? 'stopped',
            },
          ],
        };
      }
      if (path == '/api/workspaces') {
        return {'workspaces': _maps(fixture['workspaces'])};
      }
      if (path == '/api/nodes') return {'nodes': _maps(fixture['nodes'])};
      if (path.startsWith('/api/models')) {
        return {'models': _maps(fixture['models'])};
      }
      if (path == '/api/memory') return <String, dynamic>{};
      if (path == '/api/schedules') return {'schedules': <Json>[]};

      final sessionId = '${_map(fixture['session'])['id']}';
      if (path == '/api/sessions/$sessionId/read') {
        return <String, dynamic>{};
      }
      if (path == '/api/sessions/$sessionId/panel/state') {
        return _map(fixture['panel']);
      }
      if (path.startsWith('/api/sessions/$sessionId/files?path=')) {
        return _map(fixture['directory']);
      }
      throw StateError('Unexpected conversation fixture request: $path');
    }
    return super.normal(method, args);
  }

  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    final result = await super.call(method, args);
    if (method == 'watch') {
      final id = '${args['sessionId']}';
      stream.add({'type': 'snapshot', 'sessionId': id, 'data': snapshot});
      stream.add({
        'type': 'control',
        'sessionId': id,
        'data': {'held': true, 'holderName': 'This phone', 'generation': 7},
      });
      stream.add({'type': 'connection', 'sessionId': id, 'data': 'live'});
    }
    return result;
  }
}

void main() {
  final interactive =
      Platform.environment['PARITY_CAPTURE_INTERACTIVE'] == 'true';
  final captureKind = interactive
      ? 'conversation-interaction-screen'
      : 'conversation-screen';
  final fixture = _map(
    jsonDecode(
      File('../../fixtures/mobile-parity/$captureKind.json').readAsStringSync(),
    ),
  );

  testWidgets('capture populated native conversation screen matrix', (
    tester,
  ) async {
    await tester.runAsync(loadParityFonts);
    addTearDown(() {
      tester.view.reset();
      tester.platformDispatcher.clearPlatformBrightnessTestValue();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });

    tester.view.devicePixelRatio = (fixture['deviceScaleFactor'] as num)
        .toDouble();
    final output = Directory('build/parity')..createSync(recursive: true);
    final captures = <Json>[];
    final widths = _selectedValues(
      'PARITY_CAPTURE_WIDTHS',
      fixture['widths'] as List,
    );
    final textScales = _selectedValues(
      'PARITY_CAPTURE_SCALES',
      fixture['textScales'] as List,
    );

    for (final scenario in _maps(fixture['cases'])) {
      final caseId = '${scenario['id']}';
      for (final width in widths) {
        for (final brightness in Brightness.values) {
          final themeName = brightness.name;
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          for (final textScale in textScales) {
            tester.platformDispatcher.textScaleFactorTestValue = textScale;
            tester.view.physicalSize = Size(
              width * (fixture['deviceScaleFactor'] as num).toDouble(),
              (fixture['height'] as num).toDouble() *
                  (fixture['deviceScaleFactor'] as num).toDouble(),
            );

            final gateway = _ConversationGateway(fixture);
            final controller = LiveController(gateway)
              ..mode = '${_map(fixture['ui'])['mode']}';
            final boundaryKey = GlobalKey();
            await tester.pumpWidget(
              RepaintBoundary(
                key: boundaryKey,
                child: MobileApp(theme: theme, controller: controller),
              ),
            );
            await tester.pumpAndSettle();

            final sessionId = '${_map(fixture['session'])['id']}';
            expect(
              tester.takeException(),
              isNull,
              reason: '$caseId $width/$themeName/$textScale',
            );
            expect(controller.sessionId, sessionId);
            expect(controller.connection, 'live');
            expect(controller.control['held'], isTrue);
            expect(controller.draft, fixture['draft']);
            expect(controller.attachments, isEmpty);

            controller.attachments = _maps(fixture['attachments']);
            controller.changed();
            await tester.pumpAndSettle();
            expect(
              controller.attachments,
              hasLength(_maps(fixture['attachments']).length),
            );

            if (scenario['panelOpen'] == true) {
              await tester.tap(find.byTooltip('Show side panel'));
              await tester.pumpAndSettle();
              expect(
                find.byTooltip('Hide side panel'),
                findsOneWidget,
                reason: '$caseId $width/$themeName/$textScale panel toggle',
              );
              expect(find.byType(NativeSidePanel), findsOneWidget);
              expect(find.byType(FilesPane), findsOneWidget);
              expect(
                find.text('README.md'),
                findsOneWidget,
                reason: '$caseId $width/$themeName/$textScale files fixture',
              );
            }

            expect(
              tester.takeException(),
              isNull,
              reason: '$caseId $width/$themeName/$textScale',
            );

            if (interactive) {
              expect(find.byType(NativeInteractionCard), findsOneWidget);
              final submit = find.ancestor(
                of: find.text('Submit'),
                matching: find.byType(TextButton),
              );
              expect(tester.widget<TextButton>(submit).onPressed, isNull);
              if (scenario['choice'] != null || scenario['answer'] != null) {
                await tester.ensureVisible(find.text('Tablet'));
                await tester.tap(find.text('Tablet'));
                await tester.pumpAndSettle();
                expect(tester.widget<TextButton>(submit).onPressed, isNotNull);
              }
              if (scenario['answer'] != null) {
                await tester.ensureVisible(submit);
                await tester.tap(submit);
                await tester.pumpAndSettle();
                expect(controller.questions, isEmpty);
                expect(find.byType(NativeInteractionCard), findsNothing);
              }
              expect(
                gateway.answers,
                hasLength(scenario['answer'] == null ? 0 : 1),
              );
              await tester.tapAt(
                Offset(width - 1, (fixture['height'] as num).toDouble() - 1),
              );
              await tester.pumpAndSettle();
              expect(controller.running, isTrue);
              expect(
                controller.state['queue'],
                _map(fixture['state'])['queue'],
              );
              expect(find.byType(ComposerDock), findsOneWidget);
            }
            final timelineFinder = find.byType(ConversationTimeline);
            expect(timelineFinder, findsOneWidget);
            final timelineContext = tester.element(timelineFinder);
            final conversationPosition = Scrollable.of(
              timelineContext,
            ).position;
            if (conversationPosition.hasContentDimensions) {
              conversationPosition.jumpTo(
                interactive
                    ? conversationPosition.maxScrollExtent
                    : conversationPosition.minScrollExtent,
              );
            }
            await tester.pumpAndSettle();
            expect(
              conversationPosition.pixels,
              closeTo(
                interactive
                    ? conversationPosition.maxScrollExtent
                    : conversationPosition.minScrollExtent,
                .01,
              ),
              reason:
                  '$caseId $width/$themeName/$textScale shared transcript reading position',
            );

            final overlay = scenario['panelOpen'] == true && width <= 860;
            final nativeCodeBlockFinder = find.byType(NativeCodeBlock);
            expect(nativeCodeBlockFinder, findsOneWidget);
            final codeTextFinder = find.descendant(
              of: nativeCodeBlockFinder,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is Text &&
                    widget.textSpan?.toPlainText().contains('class App') ==
                        true,
              ),
            );
            expect(
              codeTextFinder,
              findsOneWidget,
              reason: '$caseId $width/$themeName/$textScale native code span',
            );
            final nativeCodeBlock = tester.widget<NativeCodeBlock>(
              nativeCodeBlockFinder,
            );
            final codeTextSpan = tester.widget<Text>(codeTextFinder).textSpan!;
            expect(codeTextSpan, isA<TextSpan>());
            final codeStyleEvidence = _styleEvidence(codeTextSpan as TextSpan);
            expect(
              codeStyleEvidence['coloredTextRuns'],
              greaterThan(0),
              reason:
                  '$caseId $width/$themeName/$textScale syntax-colored spans',
            );
            expect(
              codeStyleEvidence['distinctColors'],
              greaterThan(1),
              reason: '$caseId $width/$themeName/$textScale syntax palette',
            );

            final contentCounts = <String, int>{
              'userMessage': _textCount(
                tester,
                '${_map(_maps(fixture['messages']).first)['content']}',
              ),
              'toolSummary': _textCount(tester, 'Ran commands'),
              'toolCount': _textCount(tester, '2 tools'),
              'assistantHeading': _textCount(tester, 'Layout review'),
              'codeBlock': _textCount(tester, 'class App'),
              'draft': _textCount(tester, '${fixture['draft']}'),
              'attachmentChip': find
                  .byKey(
                    const ValueKey('composer-attachment-chip-upload-reference'),
                  )
                  .evaluate()
                  .length,
              'filePanelEntry': find.text('README.md').evaluate().length,
            };
            final conversationContent = !overlay;
            if (conversationContent) {
              expect(
                contentCounts['userMessage'],
                greaterThan(0),
                reason: '$caseId $width/$themeName/$textScale user content',
              );
              expect(
                contentCounts['toolSummary'],
                greaterThan(0),
                reason: '$caseId $width/$themeName/$textScale tool summary',
              );
              expect(
                contentCounts['assistantHeading'],
                greaterThan(0),
                reason:
                    '$caseId $width/$themeName/$textScale assistant content',
              );
              expect(
                contentCounts['codeBlock'],
                greaterThan(0),
                reason: '$caseId $width/$themeName/$textScale code content',
              );
              expect(
                contentCounts['draft'],
                greaterThan(0),
                reason: '$caseId $width/$themeName/$textScale draft',
              );
              expect(
                contentCounts['attachmentChip'],
                1,
                reason: '$caseId $width/$themeName/$textScale attachment',
              );
            }
            if (scenario['panelOpen'] == true) {
              expect(
                contentCounts['filePanelEntry'],
                1,
                reason:
                    '$caseId $width/$themeName/$textScale visible file panel',
              );
            }

            final headerRect = _bounds(tester, find.byType(ConversationHeader));
            final headerTitleFinder = find.descendant(
              of: find.byType(ConversationHeader),
              matching: find.text(controller.title),
            );
            expect(
              headerTitleFinder,
              findsOneWidget,
              reason: '$caseId $width/$themeName/$textScale header title',
            );
            final headerTitleRect = _bounds(tester, headerTitleFinder);
            final composerRect = _bounds(
              tester,
              find.byType(ConversationComposer),
            );
            final composerSurfaceFinder = find.descendant(
              of: find.byType(ConversationComposer),
              matching: find.byWidgetPredicate(_isComposerSurface),
            );
            expect(
              composerSurfaceFinder,
              findsOneWidget,
              reason:
                  '$caseId $width/$themeName/$textScale decorated composer surface',
            );
            final composerSurfaceRect = _bounds(tester, composerSurfaceFinder);
            final timelineRect = _bounds(tester, timelineFinder);
            final runCardFinder = find.byType(TimelineRun);
            expect(
              runCardFinder,
              findsOneWidget,
              reason: '$caseId $width/$themeName/$textScale grouped tool run',
            );
            final runCardRect = _bounds(tester, runCardFinder);
            final runCardDecorationFinder = find.descendant(
              of: runCardFinder,
              matching: find.byType(DecoratedBox),
            );
            expect(
              runCardDecorationFinder,
              findsWidgets,
              reason:
                  '$caseId $width/$themeName/$textScale run-card decoration',
            );
            final runCardSurfaceRect = _bounds(
              tester,
              runCardDecorationFinder.first,
            );
            final timelineViewportRect = _bounds(
              tester,
              find.byType(CustomScrollView),
            );
            final fadeRect = _bounds(
              tester,
              find.byKey(const Key('conversation-composer-fade')),
            );
            expect(fadeRect, isNotNull);
            expect(fadeRect!['height'], 24);
            final scrollRect = tester.getRect(
              find.byType(CustomScrollView).first,
            );
            expect(fadeRect['top'], closeTo(scrollRect.bottom - 24, .01));
            expect(fadeRect['width'], closeTo(scrollRect.width, .01));
            final sidebarRect = _bounds(tester, find.byType(SessionSidebar));
            final panelRect = _bounds(tester, find.byType(NativeSidePanel));
            final filesRect = _bounds(tester, find.byType(FilesPane));
            final codeRect = _bounds(
              tester,
              find.textContaining('class App', findRichText: true),
            );
            final toolSummaryRect = _bounds(
              tester,
              find.textContaining('Ran commands', findRichText: true),
            );
            final attachmentRect = _bounds(
              tester,
              find.byKey(
                const ValueKey('composer-attachment-chip-upload-reference'),
              ),
            );
            final scrollTop = conversationPosition.pixels;
            final scrollMin = conversationPosition.minScrollExtent;
            final scrollMax = conversationPosition.maxScrollExtent;

            final screenshot =
                '$captureKind-native-$caseId-${width.toInt()}-$themeName-scale${textScale.toInt()}.png';
            await tester.runAsync(() async {
              final image =
                  await (boundaryKey.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '${output.path}/$screenshot',
              ).writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });

            captures.add({
              'case': caseId,
              'width': width,
              'height': fixture['height'],
              'theme': themeName,
              'textScale': textScale,
              'overlayPanel': overlay,
              'bounds': {
                'header': headerRect,
                'headerTitle': headerTitleRect,
                'composer': composerRect,
                'composerSurface': composerSurfaceRect,
                'timeline': timelineRect,
                'runCard': runCardRect,
                'runCardSurface': runCardSurfaceRect,
                'timelineViewport': timelineViewportRect,
                'sidebar': sidebarRect,
                'composerFade': fadeRect,
                'panel': panelRect,
                'files': filesRect,
                'code': codeRect,
                'toolSummary': toolSummaryRect,
                'attachment': attachmentRect,
              },
              'transcriptScroll': {
                'pixels': scrollTop,
                'minExtent': scrollMin,
                'maxExtent': scrollMax,
                'startsAtTop': (scrollTop - scrollMin).abs() < .01,
              },
              'contentCounts': contentCounts,
              'codeHighlight': {
                'language': nativeCodeBlock.language,
                'source': nativeCodeBlock.source,
                ...codeStyleEvidence,
              },
              'contentIntersectsTimelineViewport': {
                'code': _intersects(codeRect, timelineViewportRect),
                'toolSummary': _intersects(
                  toolSummaryRect,
                  timelineViewportRect,
                ),
              },
              'controller': {
                'sessionId': controller.sessionId,
                'title': controller.title,
                'messageCount': controller.messages.length,
                'messageIds': controller.messages
                    .map((message) => message['id'])
                    .toList(),
                'connection': controller.connection,
                'control': Map<String, dynamic>.of(controller.control),
                'draft': controller.draft,
                'attachments': controller.attachments
                    .map(
                      (attachment) => {
                        'id': attachment['id'],
                        'name': attachment['name'],
                        'kind': attachment['kind'],
                        'uploading': attachment['uploading'] == true,
                      },
                    )
                    .toList(),
                'models': controller.models
                    .map((model) => model['id'])
                    .toList(),
                'selectedModelId': controller.state['modelId'],
                'selectedModelProvider': controller.state['modelProvider'],
                'thinking': controller.state['thinking'],
                'preferences': Map<String, dynamic>.of(controller.preferences),
                'panelState': controller.panelData.value,
              },
              if (interactive)
                'interactionEvidence': {
                  'selectedLabels': [
                    for (final element
                        in find
                            .byWidgetPredicate(
                              (widget) =>
                                  widget is Semantics &&
                                  widget.properties.inMutuallyExclusiveGroup ==
                                      true &&
                                  widget.properties.checked == true,
                            )
                            .evaluate())
                      for (final option in _maps(
                        _maps(
                          _map(fixture['state'])['interactions'],
                        ).single['options'],
                      ))
                        if (((element.widget as Semantics).properties.label ??
                                '')
                            .startsWith('${option['label']}.'))
                          option['label'],
                  ],
                  'pendingIds': controller.questions
                      .map((q) => q['id'])
                      .toList(),
                  'queueIds': _maps(
                    controller.state['queue'],
                  ).map((q) => q['id']).toList(),
                  'runStatus': _map(controller.state['run'])['status'],
                  'answers': gateway.answers,
                  'cardOuter': _bounds(
                    tester,
                    find.byType(NativeInteractionCard),
                  ),
                  'card': _bounds(
                    tester,
                    find.descendant(
                      of: find.byType(NativeInteractionCard),
                      matching: find.byType(DecoratedBox),
                    ),
                  ),
                  'textBounds': {
                    for (final text in [
                      'Your input is needed',
                      'Choose a target',
                      'Use the same layout in both clients.',
                      'Phone',
                      'One conversation at a time.',
                      'Tablet',
                      'Keep the workspace panel visible.',
                      'Submit',
                    ])
                      text: _bounds(tester, find.text(text)),
                  },
                  'dockOuter': _bounds(tester, find.byType(ComposerDock)),
                  'dock': _bounds(
                    tester,
                    find.descendant(
                      of: find.byType(ComposerDock),
                      matching: find.byType(DecoratedBox),
                    ),
                  ),
                },
              'requests': List<Json>.of(gateway.requests),
              'screenshot': screenshot,
            });

            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
            await gateway.stream.close();
          }
        }
      }
    }

    await tester.runAsync(() async {
      final manifest = {
        'fixture': fixture['id'],
        'webRevision': fixture['webRevision'],
        'deviceScaleFactor': fixture['deviceScaleFactor'],
        'fontOverride': fixture['fontOverride'],
        'captures': captures,
      };
      final encoded = const JsonEncoder.withIndent('  ').convert(manifest);
      File(
        '${output.path}/$captureKind-native.json',
      ).writeAsStringSync('$encoded\n');
    });
  });
}
