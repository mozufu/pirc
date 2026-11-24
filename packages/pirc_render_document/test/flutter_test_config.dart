import 'dart:async';

import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render_document/pirc_render_document.dart';

/// Documents in these tests run with the native script runtime installed.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  RenderHost.fallback = const RenderHost(
    documentRuntime: NativeDocumentRuntime(),
  );
  await testMain();
}
