import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:pirc_render/pirc_render.dart';
import 'package:pirc_render_document/pirc_render_document.dart';

import 'document_media.dart';
import 'platform/files.dart';
import 'platform/media.dart';

/// The renderer host for the whole app (`RenderHost.fallback`). On Android
/// it plays the media of messages and tool results: they load only after a
/// tap and without credentials, through the scripts channel. It never
/// carries the document runtime: chat content gets no top layer, no canvas
/// and no script callbacks. macOS and Web keep the plain host until M9
/// (plans/roadmap.md M8 step 6).
RenderHost documentRenderHost({TargetPlatform? platform}) {
  if ((platform ?? defaultTargetPlatform) != TargetPlatform.android) {
    return const RenderHost();
  }
  return RenderHost(mediaBuilder: _messageMedia);
}

/// The host for a fetched-document view: the document runtime (tier 3) and
/// the view's document scope. Only such a view places it, in a
/// [RenderHostScope] around itself; the document views come with the port
/// of the old `live/document_*` files. Android only.
RenderHost fetchedDocumentHost({
  required RenderDocumentScope? Function(BuildContext context) documentScopeOf,
  RenderMediaBuilder? mediaBuilder,
}) => RenderHost(
  documentRuntime: const NativeDocumentRuntime(),
  documentScopeOf: documentScopeOf,
  mediaBuilder: mediaBuilder,
);

const _scripts = ChannelScriptsPlatform();

final RenderMediaBuilder _messageMedia = messageMediaBuilder(
  players: const ChannelMediaPlayers(),
  fetch: (url, requestId) async {
    final media = await _scripts.media(url, requestId: requestId);
    return (media.bytes, media.mimeType);
  },
  cancel: _scripts.cancelMedia,
);

/// Closes every document script session and cancels their requests
/// (unpairing).
Future<void> closeDocumentScripts() async {
  if (defaultTargetPlatform != TargetPlatform.android) return;
  await const ChannelScriptsPlatform().closeAll();
}

/// Saves the target of an `<a download>` in a message through the system
/// save picker ([FilesPlatform.save]). Only `data:` links are saved: a
/// message document has no credentials to fetch a remote file with.
/// Returns the saved name, or null when the user cancelled.
Future<String?> saveDocumentLink(
  FilesPlatform files,
  String href, {
  String? download,
}) => DocumentDownload.link(href, download: download).save(files.save);
