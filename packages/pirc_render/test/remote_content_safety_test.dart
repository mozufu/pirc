import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirc_render/pirc_render.dart';

import 'support/render_theme.dart';

/// Safety regression (default suite): untrusted chat content must not reach
/// the network by being displayed. Remote images and media wait for a tap;
/// nothing else in the content may cause a request at all.
void main() {
  testWidgets('displaying remote references sends no request', (t) async {
    final requests = <String>[];
    await HttpOverrides.runZoned(() async {
      await _pump(t, _remoteMessage);
      await t.pumpAndSettle();
      expect(requests, isEmpty);
      expect(
        find.byKey(const ValueKey('remote-content-placeholder')),
        findsWidgets,
      );
    }, createHttpClient: (_) => _CountingHttp(requests));
  });

  testWidgets('a tap loads exactly the tapped image', (t) async {
    final requests = <String>[];
    await HttpOverrides.runZoned(() async {
      await _pump(
        t,
        '<img src="https://img.example.test/h.png" alt="held html">\n\n'
        '![held md](https://img.example.test/m.png)',
      );
      await t.pumpAndSettle();
      expect(requests, isEmpty);
      await t.tap(find.text('held html'));
      await t.pumpAndSettle();
      expect(requests, ['https://img.example.test/h.png']);
    }, createHttpClient: (_) => _CountingHttp(requests));
  });

  testWidgets('inline data: images show without a tap', (t) async {
    final data = 'data:image/png;base64,${base64Encode(_png)}';
    await _pump(t, '![inline]($data)');
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsNothing,
    );
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('a policy that loads on display is an explicit opt-out', (
    t,
  ) async {
    await _pump(
      t,
      '![remote](https://img.example.test/r.png)',
      loadOnActivation: false,
    );
    expect(
      find.byKey(const ValueKey('remote-content-placeholder')),
      findsNothing,
    );
  });
}

Future<void> _pump(
  WidgetTester t,
  String source, {
  bool? loadOnActivation,
}) async {
  Widget body = SingleChildScrollView(child: NativeMarkdown(source: source));
  if (loadOnActivation != null) {
    body = NativeRemoteContentPolicy(
      loadOnActivation: loadOnActivation,
      child: body,
    );
  }
  await t.pumpWidget(
    MaterialApp(
      theme: renderTestTheme(),
      home: Scaffold(body: body),
    ),
  );
}

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Records every URL content tries to open and refuses it.
class _CountingHttp implements HttpClient {
  _CountingHttp(this.urls);
  final List<String> urls;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('getUrl') ||
        name.contains('openUrl') ||
        name.contains('postUrl')) {
      urls.add('${invocation.positionalArguments.last}');
      throw const SocketException('blocked by test');
    }
    return null;
  }
}

const _remoteMessage = '''
Before ![md alt](https://img.example.test/md.png "md title") after

<img src="https://img.example.test/html.png" alt="html alt" loading="eager" decoding="sync" fetchpriority="high">

<img src="https://img.example.test/base.png" srcset="https://img.example.test/s1.png 1x, https://img.example.test/s2.png 2x" alt="srcset alt">

<picture><source srcset="https://img.example.test/pic.webp" type="image/webp"><img src="https://img.example.test/pic.png" alt="picture alt"></picture>

<video src="https://media.example.test/v.mp4" poster="https://img.example.test/poster.png" controls></video>

<audio src="https://media.example.test/a.mp3" controls></audio>

<div style="background:url(https://img.example.test/bg.png);height:20px">bg</div>

<ul style="list-style-image:url(https://img.example.test/li.png)"><li>item</li></ul>

<div style="border:10px solid red;border-image:url(https://img.example.test/bi.png) 30 round">bi</div>

<svg width="40" height="40" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"><image href="https://img.example.test/svgimg.png" width="40" height="40"/><use href="https://img.example.test/sym.svg#a"/></svg>

<form action="https://recv.example.test/post"><input type="image" src="https://img.example.test/submit.png" alt="go"></form>

<a href="https://x.example.test/y" ping="https://img.example.test/ping">link</a>

<table background="https://img.example.test/tbl.png"><tr><td>c</td></tr></table>

<link rel="preload" as="image" href="https://img.example.test/preload.png">
<meta http-equiv="refresh" content="0;url=https://img.example.test/refresh">
<style>@import url(https://img.example.test/import.css); body{background:url(https://img.example.test/style.png)}</style>
''';
