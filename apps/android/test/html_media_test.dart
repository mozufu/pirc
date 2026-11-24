import 'package:pirc_mobile/rendering/remote_content_gate.dart';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html;
import 'package:pirc_mobile/live/common.dart';
import 'package:pirc_mobile/rendering/document_object_urls.dart';
import 'package:pirc_mobile/live/gateway.dart';
import 'package:pirc_mobile/live/html_media.dart';
import 'package:pirc_mobile/rendering/html_media_spec.dart';
import 'live_test.dart' show theme;

NativeHtmlMediaSpec spec(String source) =>
    NativeHtmlMediaSpec.fromElement(html.parseFragment(source).children.single);

class MediaGateway extends Gateway {
  final calls = <(String, Json)>[];
  final entries = <int, Json>{};
  int next = 10;
  Future<dynamic> Function(String, Json)? handler;
  @override
  Future<dynamic> call(String method, [Json args = const {}]) async {
    calls.add((method, args));
    if (handler != null) return handler!(method, args);
    return normal(method, args);
  }

  dynamic normal(String method, Json args) {
    if (method == 'boot') {
      return {'pairingStamp': 'stamp', 'origin': 'https://gateway.example'};
    }
    if (method == 'htmlMediaOpen') {
      final id = next++;
      final audio = args['kind'] == 'audio';
      entries[id] = {
        'id': id,
        'width': audio ? 0 : 320,
        'height': audio ? 0 : 180,
        'duration': 3000,
        'position': 0,
        'playing': false,
        'mimeType': audio ? 'audio/wav' : 'video/mp4',
        'muted': args['muted'],
        'rate': 1.0,
      };
      return {...entries[id]!};
    }
    if (method == 'htmlMediaClose') {
      entries.remove(args['id']);
      return null;
    }
    if (method == 'htmlMediaControl') {
      final data = entries[args['id']]!;
      switch (args['action']) {
        case 'play':
          data['playing'] = true;
        case 'pause':
          data['playing'] = false;
        case 'seek':
          data['position'] = args['position'];
        case 'rate':
          data['rate'] = args['rate'];
        case 'volume':
          data['muted'] = args['volume'] == 0;
      }
      return {...data};
    }
    if (method == 'htmlMediaRead') {
      return {
        'bytes': Uint8List.fromList([1, 2, 3]),
        'mimeType': 'video/mp4',
        'finalUrl': 'https://gateway.example/loaded.mp4',
        'headersRelevant': {},
        'pairingStamp': 'stamp',
      };
    }
    if (method == 'saveDocument') return {'bytesWritten': 3};
    throw StateError('Unexpected $method');
  }
}

Future<void> settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 10));
}

Widget host(
  MediaGateway g,
  String markup, {
  Brightness brightness = Brightness.light,
  double scale = 1,
}) => MaterialApp(
  theme: theme.build(brightness),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(body: RichTextBody(markup, gateway: g)),
);
void main() {
  setUpAll(() => NativeRemoteContentPolicy.debugOpenForTests = true);
  tearDownAll(() => NativeRemoteContentPolicy.debugOpenForTests = false);
  test('direct src failure never tries child sources', () async {
    final g = MediaGateway();
    g.handler = (method, args) async {
      if (method == 'htmlMediaOpen') throw StateError('decoder failed');
      return g.normal(method, args);
    };
    final s = HtmlMediaState(
      gateway: g,
      spec: spec('<video src="bad.mp4"><source src="good.mp4"></video>'),
      isCurrent: () => true,
    );
    expect(await s.open(), isFalse);
    expect(
      g.calls.where((c) => c.$1 == 'htmlMediaOpen').map((c) => c.$2['source']),
      ['bad.mp4'],
    );
    s.dispose();
  });
  test(
    'ordered sources skip unsupported types and advance after resource failure',
    () async {
      final g = MediaGateway();
      g.handler = (method, args) async {
        if (method == 'htmlMediaOpen' && args['source'] == 'bad.mp4') {
          throw StateError('404');
        }
        return g.normal(method, args);
      };
      final s = HtmlMediaState(
        gateway: g,
        spec: spec(
          '<video><source src="skip" type="video/not-supported"><source src="bad.mp4" type="video/mp4"><source src="good.mp4" type="video/mp4"></video>',
        ),
        baseUrl: 'https://gateway.example/page',
        isCurrent: () => true,
      );
      expect(await s.open(), isTrue);
      expect(s.loadedSource, 'good.mp4');
      expect(
        g.calls
            .where((c) => c.$1 == 'htmlMediaOpen')
            .map((c) => c.$2['source']),
        ['bad.mp4', 'good.mp4'],
      );
      s.dispose();
    },
  );
  test('late opened texture is closed after account invalidation', () async {
    final g = MediaGateway(), pending = Completer<Json>();
    var valid = true;
    g.handler = (method, args) async =>
        method == 'htmlMediaOpen' ? pending.future : g.normal(method, args);
    final s = HtmlMediaState(
      gateway: g,
      spec: spec('<video src="clip.mp4">'),
      isCurrent: () => valid,
    );
    final opening = s.open();
    await Future<void>.delayed(Duration.zero);
    valid = false;
    pending.complete({'id': 99});
    expect(await opening, isFalse);
    expect(s.data, isNull);
    expect(g.calls.where((c) => c.$1 == 'htmlMediaClose').single.$2['id'], 99);
    s.dispose();
  });
  test(
    'hidden muted autoplay never starts; manual play pauses on hiding',
    () async {
      final g = MediaGateway();
      final s = HtmlMediaState(
        gateway: g,
        spec: spec('<video src="clip.mp4" autoplay muted>'),
        isCurrent: () => true,
      );
      s.initialize();
      await s.open();
      expect(
        g.calls.where(
          (c) => c.$1 == 'htmlMediaControl' && c.$2['action'] == 'play',
        ),
        isEmpty,
      );
      s.setActive(true);
      await s.togglePlay();
      expect(s.playing, isTrue);
      s.setActive(false);
      await Future<void>.delayed(Duration.zero);
      expect(s.playing, isFalse);
      s.dispose();
    },
  );
  test('paused seek acknowledgment survives a later volume control', () async {
    final g = MediaGateway(), pending = Completer<Json>();
    final s = HtmlMediaState(
      gateway: g,
      spec: spec('<video src="clip.mp4" muted>'),
      isCurrent: () => true,
    );
    await s.open();
    expect(
      g.calls.firstWhere((c) => c.$1 == 'htmlMediaOpen').$2['muted'],
      true,
    );
    g.handler = (method, args) async =>
        method == 'htmlMediaControl' && args['action'] == 'seek'
        ? pending.future
        : g.normal(method, args);
    final seeking = s.command('seek', position: 1200);
    await s.toggleMute();
    pending.complete({...s.data!, 'position': 1200, 'muted': true});
    await seeking;
    expect(s.position, 1200);
    expect(s.muted, false);
    expect(s.data!['muted'], false);
    s.dispose();
  });
  test(
    'play acknowledgment arriving after hiding is immediately paused',
    () async {
      final g = MediaGateway(), pending = Completer<Json>();
      final s = HtmlMediaState(
        gateway: g,
        spec: spec('<video src="clip.mp4">'),
        isCurrent: () => true,
      );
      await s.open();
      s.setActive(true);
      g.handler = (method, args) async =>
          method == 'htmlMediaControl' && args['action'] == 'play'
          ? pending.future
          : g.normal(method, args);
      final playing = s.command('play');
      s.setActive(false);
      pending.complete({...s.data!, 'playing': true});
      expect(await playing, false);
      expect(s.playing, false);
      expect(g.calls.last.$2['action'], 'pause');
      s.dispose();
    },
  );
  test('data bytes and save reuse loaded media without refetch', () async {
    final g = MediaGateway();
    final s = HtmlMediaState(
      gateway: g,
      spec: spec('<video src="data:video/mp4;base64,AQID">'),
      isCurrent: () => true,
    );
    expect(await s.open(), isTrue);
    expect(g.calls.firstWhere((c) => c.$1 == 'htmlMediaOpen').$2['bytes'], [
      1,
      2,
      3,
    ]);
    await s.save();
    expect(g.calls.where((c) => c.$1 == 'htmlMediaOpen'), hasLength(1));
    final save = g.calls.firstWhere((c) => c.$1 == 'saveDocument').$2;
    expect(save['bytes'], [1, 2, 3]);
    expect(save['name'], 'loaded.mp4');
    expect(save['pairingStamp'], 'stamp');
    s.dispose();
  });
  test(
    'blob media source is accepted while file and content URLs stay unsafe',
    () {
      final blob = spec('<video src="blob:https://example.test/id"></video>');
      expect(blob.candidates.single.url, 'blob:https://example.test/id');
      expect(
        () => spec('<video src="file:///tmp/clip.mp4"></video>'),
        throwsFormatException,
      );
      expect(
        () => spec('<audio src="content://provider/clip"></audio>'),
        throwsFormatException,
      );
    },
  );

  test(
    'blob media is prepared from the current document binding and keeps its URL identity',
    () async {
      const url = 'blob:https://example.test/document/clip';
      final g = MediaGateway();
      final reads = <String>[];
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => true,
        readBytes: (requested) async {
          reads.add(requested);
          return {
            'ok': true,
            'url': requested,
            'type': 'video/mp4',
            'size': 3,
            'bytesBase64': 'AQID',
          };
        },
      );
      final state = HtmlMediaState(
        gateway: g,
        spec: spec('<video src="$url"></video>'),
        isCurrent: () => true,
        objectUrls: binding,
      );

      expect(await state.open(), isTrue);
      expect(reads, [url]);
      expect(state.loadedSource, url);
      final opened = g.calls.singleWhere((call) => call.$1 == 'htmlMediaOpen');
      expect(opened.$2['bytes'], [1, 2, 3]);
      expect(opened.$2['mimeType'], 'video/mp4');
      expect(opened.$2.containsKey('source'), isFalse);
      expect(opened.$2.containsValue(url), isFalse);
      state.dispose();
    },
  );

  test('stale object URL read never reaches the native media opener', () async {
    const url = 'blob:https://example.test/document/late';
    final pending = Completer<Json>();
    var current = true;
    var reads = 0;
    final g = MediaGateway();
    final binding = NativeDocumentObjectUrlBinding(
      owner: Object(),
      isCurrent: () => current,
      readBytes: (_) {
        reads++;
        return pending.future;
      },
    );
    final state = HtmlMediaState(
      gateway: g,
      spec: spec('<video src="$url"></video>'),
      isCurrent: () => true,
      objectUrls: binding,
    );

    final opening = state.open();
    await Future<void>.delayed(Duration.zero);
    expect(reads, 1);
    current = false;
    pending.complete({
      'ok': true,
      'url': url,
      'type': 'video/mp4',
      'size': 3,
      'bytesBase64': 'AQID',
    });
    expect(await opening, isFalse);
    expect(g.calls.where((call) => call.$1 == 'htmlMediaOpen'), isEmpty);
    state.dispose();
  });

  test(
    'blob player opened after binding invalidation is immediately closed',
    () async {
      const url = 'blob:https://example.test/document/opening';
      final pending = Completer<Json>();
      final entered = Completer<void>();
      var current = true;
      final g = MediaGateway();
      g.handler = (method, args) async {
        if (method == 'htmlMediaOpen') {
          entered.complete();
          return pending.future;
        }
        return g.normal(method, args);
      };
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => current,
        readBytes: (requested) async => {
          'ok': true,
          'url': requested,
          'type': 'video/mp4',
          'size': 3,
          'bytesBase64': 'AQID',
        },
      );
      final state = HtmlMediaState(
        gateway: g,
        spec: spec('<video src="$url"></video>'),
        isCurrent: () => true,
        objectUrls: binding,
      );

      final opening = state.open();
      await entered.future;
      current = false;
      pending.complete({
        'id': 91,
        'width': 320,
        'height': 180,
        'duration': 3000,
        'position': 0,
        'playing': false,
        'mimeType': 'video/mp4',
        'muted': false,
        'rate': 1.0,
      });
      expect(await opening, isFalse);
      expect(state.data, isNull);
      expect(
        g.calls.where((call) => call.$1 == 'htmlMediaClose').single.$2['id'],
        91,
      );
      state.dispose();
    },
  );

  test(
    'revoked blob candidate falls back without forwarding the object URL',
    () async {
      const url = 'blob:https://example.test/document/revoked';
      final g = MediaGateway();
      var reads = 0;
      final binding = NativeDocumentObjectUrlBinding(
        owner: Object(),
        isCurrent: () => true,
        readBytes: (_) async {
          reads++;
          throw StateError('Object URL was revoked.');
        },
      );
      final state = HtmlMediaState(
        gateway: g,
        spec: spec(
          '<video><source src="$url" type="video/mp4"><source src="fallback.mp4" type="video/mp4"></video>',
        ),
        baseUrl: 'https://example.test/page',
        isCurrent: () => true,
        objectUrls: binding,
      );

      expect(await state.open(), isTrue);
      expect(reads, 1);
      expect(state.loadedSource, 'fallback.mp4');
      final opens = g.calls
          .where((call) => call.$1 == 'htmlMediaOpen')
          .toList();
      expect(opens, hasLength(1));
      expect(opens.single.$2['source'], 'fallback.mp4');
      expect(opens.single.$2.containsValue(url), isFalse);
      state.dispose();
    },
  );

  test(
    'unavailable blob media never opens an arbitrary URI natively',
    () async {
      const url = 'blob:https://example.test/document/missing';
      final g = MediaGateway();
      final state = HtmlMediaState(
        gateway: g,
        spec: spec('<video src="$url"></video>'),
        isCurrent: () => true,
      );

      expect(await state.open(), isFalse);
      expect(g.calls.where((call) => call.$1 == 'htmlMediaOpen'), isEmpty);
      expect(g.calls.any((call) => call.$2.containsValue(url)), isFalse);
      state.dispose();
    },
  );

  testWidgets('NativeHtmlMedia reads the inherited object URL binding', (
    t,
  ) async {
    const url = 'blob:https://example.test/document/widget';
    final g = MediaGateway();
    final binding = NativeDocumentObjectUrlBinding(
      owner: Object(),
      isCurrent: () => true,
      readBytes: (requested) async => {
        'ok': true,
        'url': requested,
        'type': 'video/mp4',
        'size': 3,
        'bytesBase64': 'AQID',
      },
    );
    await t.pumpWidget(
      MaterialApp(
        home: NativeDocumentObjectUrlScope(
          binding: binding,
          child: Scaffold(
            body: NativeHtmlMedia(
              gateway: g,
              spec: spec('<video src="$url"></video>'),
            ),
          ),
        ),
      ),
    );
    await settle(t);
    final opened = g.calls.singleWhere((call) => call.$1 == 'htmlMediaOpen');
    expect(opened.$2['bytes'], [1, 2, 3]);
    expect(opened.$2.containsKey('source'), isFalse);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });

  testWidgets('empty media boxes follow Chrome defaults and do not fetch', (
    t,
  ) async {
    final g = MediaGateway();
    await t.pumpWidget(
      host(
        g,
        '<video controls></video><audio controls></audio><audio></audio>',
      ),
    );
    await settle(t);
    final media = find.byType(NativeHtmlMedia);
    expect(media, findsNWidgets(3));
    expect(t.getSize(media.at(0)), const Size(300, 150));
    expect(t.getSize(media.at(1)), const Size(300, 54));
    expect(t.getSize(media.at(2)), Size.zero);
    expect(g.calls, isEmpty);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  testWidgets(
    'preload none opens only on actual play; pause/seek/mute preserve state',
    (t) async {
      final g = MediaGateway();
      await t.pumpWidget(
        host(g, '<audio controls preload="none" src="tone.wav"></audio>'),
      );
      await settle(t);
      expect(g.calls, isEmpty);
      await t.tap(find.byTooltip('Play media'));
      await settle(t);
      expect(find.byTooltip('Pause media'), findsOneWidget);
      await t.tap(find.byTooltip('Mute media'));
      await settle(t);
      expect(find.byTooltip('Unmute media'), findsOneWidget);
      final slider = t.widget<Slider>(find.byType(Slider));
      slider.onChanged!(1500);
      await settle(t);
      expect(g.entries.values.single['position'], 1500);
      await t.tap(find.byTooltip('Pause media'));
      await settle(t);
      expect(g.entries.values.single['playing'], isFalse);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await settle(t);
      expect(g.entries, isEmpty);
    },
  );
  testWidgets('inline table HTML routes media through the same native player', (
    t,
  ) async {
    final g = MediaGateway();
    await t.pumpWidget(
      host(
        g,
        '| Media |\n| --- |\n| <audio controls src="tone.wav"></audio> |',
      ),
    );
    await settle(t);
    expect(find.byType(NativeHtmlMedia), findsOneWidget);
    expect(g.calls.where((c) => c.$1 == 'htmlMediaOpen'), hasLength(1));
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
  for (final width in [390.0, 1024.0]) {
    for (final brightness in Brightness.values) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('media controls fit $width $brightness scale$scale', (
          t,
        ) async {
          t.view.devicePixelRatio = 1;
          t.view.physicalSize = Size(width, 900);
          addTearDown(t.view.reset);
          final g = MediaGateway();
          await t.pumpWidget(
            host(
              g,
              '<video controls src="clip.mp4"></video><audio controls src="tone.wav"></audio>',
              brightness: brightness,
              scale: scale,
            ),
          );
          await settle(t);
          expect(find.byType(NativeHtmlMedia), findsNWidgets(2));
          expect(t.takeException(), isNull);
          await t.pumpWidget(const SizedBox());
        });
      }
    }
  }
  for (final row in [
    ('width="100"', '', const Size(100, 150)),
    ('height="100"', '', const Size(300, 100)),
    ('width="0"', '', const Size(0, 150)),
    ('', 'style="width:100px;height:40px"', const Size(100, 40)),
    ('width="640"', 'style="max-width:100%"', const Size(390, 150)),
  ]) {
    testWidgets('media default/CSS size ${row.$1} ${row.$2}', (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(390, 900);
      addTearDown(t.view.reset);
      final g = MediaGateway();
      await t.pumpWidget(
        host(g, '<video controls ${row.$1} ${row.$2}></video>'),
      );
      await settle(t);
      expect(t.getSize(find.byType(NativeHtmlMedia)), row.$3);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
    });
  }
}
