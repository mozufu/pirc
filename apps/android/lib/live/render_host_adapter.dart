import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:pirc_render_document/pirc_render_document.dart'
    show NativeDocumentRuntime;

import '../l10n/app_i18n.dart';
import 'package:pirc_render/src/html_file.dart' show NativeHtmlFilePicker;
import 'package:pirc_render/src/html_media_spec.dart' show NativeHtmlMediaSpec;
import 'package:pirc_render/src/render_host.dart';
import 'package:pirc_render/src/render_l10n.dart'
    show RenderL10n, RenderLocalizations;
import 'document_navigation_state.dart';
import 'gateway.dart';
import 'html_file_picker.dart';
import 'html_media.dart';

/// Connects the renderer to this app: its catalog, its document windows, its
/// media players and its file picker. Call once before the first frame, and
/// from test configuration.
void installAppRenderHost() {
  RenderL10n.delegate = const _AppRenderLocalizations();
  RenderHost.fallback = appRenderHost;
}

const appRenderHost = RenderHost(
  documentRuntime: NativeDocumentRuntime(),
  documentScopeOf: NativeDocumentScope.maybeOf,
  mediaBuilder: _media,
  filePickerFor: _filePicker,
);

Widget? _media(
  RenderDocumentScope? scope,
  NativeHtmlMediaSpec spec,
  Map<String, String> styles, {
  String? baseUrl,
  Object? accountIdentity,
}) {
  // Chat content has no document scope; this app plays only document media.
  if (scope is! NativeDocumentScope) return null;
  final document = scope;
  return NativeHtmlMedia(
    gateway: document.windows.gateway,
    spec: spec,
    styles: styles,
    baseUrl: baseUrl,
    scope: document,
    accountIdentity: accountIdentity,
  );
}

NativeHtmlFilePicker _filePicker(
  RenderDocumentScope scope, {
  bool Function()? isCurrent,
}) => createNativeHtmlFilePicker(
  (scope as NativeDocumentScope).windows.gateway,
  isCurrent: isCurrent,
);

class _AppRenderLocalizations extends RenderLocalizations {
  const _AppRenderLocalizations();
  @override
  String translate(String source, List<Object?> values) => tr(source, values);
  @override
  void watch(BuildContext context) => AppI18n.watch(context);
}

final _fetchers = Expando<RenderImageFetcher>('gateway image fetcher');

/// One fetcher per Gateway, so image cache keys keep the Gateway's identity.
RenderImageFetcher gatewayImageFetcher(Gateway gateway) =>
    _fetchers[gateway] ??= _GatewayImageFetcher(gateway);

class _GatewayImageFetcher implements RenderImageFetcher {
  _GatewayImageFetcher(this.gateway);
  final Gateway gateway;
  @override
  Future<RenderFetchedImage> fetchImage(
    Uri source, {
    String? baseUrl,
    String? documentUrl,
  }) async {
    final result = obj(
      await gateway.call('image', {
        'source': source.toString(),
        'baseUrl': ?baseUrl,
        'documentUrl': ?documentUrl,
      }),
    );
    return RenderFetchedImage(
      result['bytes'] as Uint8List,
      '${result['mimeType']}',
    );
  }
}
