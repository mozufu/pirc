import 'package:flutter/foundation.dart';
import 'package:pirc_render/pirc_render.dart';

import 'platform/files.dart';

/// The renderer host on Web (and every platform but Android) until M9
/// (plans/roadmap.md M8 step 6): no message media, no document runtime.
///
/// Android gets `document_host_io.dart` instead, through the conditional
/// import in `app.dart`, so the Web build never compiles the runtime or the
/// scripts channel.
RenderHost documentRenderHost({TargetPlatform? platform}) => const RenderHost();

/// Closes every document script session (unpairing); nothing to close here.
Future<void> closeDocumentScripts() async {}

/// Saves the target of an `<a download>` (Android only); refused here.
Future<String?> saveDocumentLink(
  FilesPlatform files,
  String href, {
  String? download,
}) async => throw UnsupportedError('Document downloads need Android');
