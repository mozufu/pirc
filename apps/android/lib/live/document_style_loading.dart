import '../l10n/app_i18n.dart';
import 'package:html/parser.dart' as html;
import 'package:flutter/services.dart';

import 'package:pirc_render/src/html_document_content.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'gateway.dart';
import 'document_referrer.dart';
import 'dart:convert';

/// Fetch attributes captured when a stylesheet owner selects its resource.
class NativeStylesheetRequestOptions {
  const NativeStylesheetRequestOptions({
    this.crossOrigin,
    this.integrity,
    this.referrerPolicy,
    required this.referrerUrl,
  });
  final String? crossOrigin, integrity, referrerPolicy;
  final String referrerUrl;
  NativeStylesheetRequestOptions imported(String url, String? policy) =>
      NativeStylesheetRequestOptions(
        crossOrigin: crossOrigin,
        referrerPolicy: policy ?? referrerPolicy,
        referrerUrl: url,
      );
  Json arguments(String url) => {
    'kind': 'stylesheet',
    'url': url,
    'method': 'GET',
    'crossOrigin': crossOrigin,
    'integrity': integrity,
    'referrerPolicy': referrerPolicy,
    'stylesheetReferrerUrl': referrerUrl,
  };
  String cacheKey(String url) =>
      jsonEncode([url, crossOrigin, integrity, referrerPolicy, referrerUrl]);
}

/// An initial document load can seed the later script owner without another GET.
class NativePreparedDocumentStyle {
  const NativePreparedDocumentStyle({
    required this.order,
    required this.href,
    required this.cssText,
    required this.baseUrl,
    required this.options,
    required this.stylesheets,
    required this.diagnostics,
    required this.loaded,
    this.media,
  });
  final int order;
  final String? media;
  List<NativeDocumentStylesheet> get unwrappedStylesheets {
    if (media == null || media!.isEmpty) return stylesheets;
    final prefix = '@media $media {';
    return [
      for (final sheet in stylesheets)
        NativeDocumentStylesheet(
          sheet.cssText.startsWith(prefix) && sheet.cssText.endsWith('}')
              ? sheet.cssText.substring(prefix.length, sheet.cssText.length - 1)
              : sheet.cssText,
          baseUrl: sheet.baseUrl,
        ),
    ];
  }

  final String? href, cssText;
  final String baseUrl;
  final NativeStylesheetRequestOptions options;
  final List<NativeDocumentStylesheet> stylesheets;
  final List<String> diagnostics;
  final bool loaded;
}

class NativeLoadedDocumentStyles {
  const NativeLoadedDocumentStyles(
    this.stylesheets,
    this.diagnostics, {
    this.prepared = const [],
    this.loaded = true,
  });
  final List<NativeDocumentStylesheet> stylesheets;
  final List<String> diagnostics;
  final List<NativePreparedDocumentStyle> prepared;
  final bool loaded;
}

/// Loads author styles in document order. Imported resources keep their own
/// final URL for relative CSS resources, and precede their importing sheet.
/// Credentials, redirects and account checks belong to the native transport.
class NativeDocumentStyleLoader {
  NativeDocumentStyleLoader({
    required this.fetch,
    required this.resolve,
    this.fetchWithOptions,
    required this.isCurrent,
    this.maximumSources = 64,
    this.maximumBytes = 8 * 1024 * 1024,
    this.maximumImportDepth = 10,
  });

  final Future<Json> Function(String reference, String baseUrl) fetch;
  final Future<Json> Function(
    String reference,
    String baseUrl,
    NativeStylesheetRequestOptions options,
  )?
  fetchWithOptions;
  final Future<String> Function(String reference, String baseUrl) resolve;
  final bool Function() isCurrent;
  final int maximumSources, maximumBytes, maximumImportDepth;
  final _cache = <String, Future<Json>>{};
  final _sheets = <NativeDocumentStylesheet>[];
  final _diagnostics = <String>[];
  int _sourceCount = 0, _bytes = 0, _failures = 0;
  final _prepared = <NativePreparedDocumentStyle>[];

  Future<NativeLoadedDocumentStyles> load(
    String source, {
    required String baseUrl,
    required String documentEncoding,
    String? documentUrl,
    String? referrerPolicy,
  }) async {
    final document = html.parse(source);
    final owners = document.querySelectorAll('style,link');
    for (var order = 0; order < owners.length; order++) {
      final node = owners[order];
      _checkCurrent();
      final type = node.attributes['type']?.trim().toLowerCase();
      if (type != null && type.isNotEmpty && type != 'text/css') continue;
      final media = node.attributes['media']?.trim();
      final conditions = [if (media != null && media.isNotEmpty) media];
      final before = _sheets.length,
          beforeDiagnostics = _diagnostics.length,
          beforeFailures = _failures;
      final rawCrossOrigin = node.attributes['crossorigin'];
      final normalizedCrossOrigin = rawCrossOrigin?.trim().toLowerCase();
      final options = NativeStylesheetRequestOptions(
        crossOrigin: rawCrossOrigin == null
            ? null
            : {
                '',
                'anonymous',
                'use-credentials',
              }.contains(normalizedCrossOrigin)
            ? normalizedCrossOrigin
            : 'anonymous',
        integrity: node.localName == 'link'
            ? node.attributes['integrity']
            : null,
        referrerUrl: documentUrl ?? baseUrl,
        referrerPolicy: NativeDocumentReferrer.fromDocument(
          url: documentUrl ?? baseUrl,
          source: source,
          headerPolicy: referrerPolicy,
          elementPolicy: node.attributes['referrerpolicy'],
        ).policy,
      );
      if (node.localName == 'style') {
        await _expand(
          NativeDocumentStylesheet(node.text, baseUrl: baseUrl),
          documentEncoding,
          const {},
          0,
          conditions,
          options,
        );
        _prepared.add(
          NativePreparedDocumentStyle(
            order: order,
            href: null,
            cssText: node.text,
            baseUrl: baseUrl,
            options: options,
            media: media,
            stylesheets: List.unmodifiable(_sheets.skip(before)),
            diagnostics: List.unmodifiable(
              _diagnostics.skip(beforeDiagnostics),
            ),
            loaded: beforeFailures == _failures,
          ),
        );
        continue;
      }
      final rel = (node.attributes['rel'] ?? '').toLowerCase().split(
        RegExp(r'[\t\n\f\r ]+'),
      );
      if (!rel.contains('stylesheet') ||
          rel.contains('alternate') ||
          node.attributes.containsKey('disabled')) {
        continue;
      }
      final href = node.attributes['href'];
      if (href == null || href.isEmpty) continue;
      if (node.attributes['title']?.isNotEmpty == true) {
        _diagnostics.add(
          tr("Preferred titled stylesheet sets are not implemented."),
        );
      }
      String resolved;
      try {
        resolved = await resolve(href, baseUrl);
      } catch (error) {
        _checkCurrent();
        _failures++;
        _diagnostics.add(
          tr("Stylesheet URL could not resolve: {0}", [
            LiveController.describe(error),
          ]),
        );
        continue;
      }
      _checkCurrent();
      await _external(
        resolved,
        baseUrl,
        documentEncoding,
        const {},
        0,
        conditions,
        options,
      );
      _prepared.add(
        NativePreparedDocumentStyle(
          order: order,
          href: resolved,
          cssText: null,
          baseUrl: baseUrl,
          options: options,
          media: media,
          stylesheets: List.unmodifiable(_sheets.skip(before)),
          diagnostics: List.unmodifiable(_diagnostics.skip(beforeDiagnostics)),
          loaded: beforeFailures == _failures,
        ),
      );
    }
    _checkCurrent();
    return NativeLoadedDocumentStyles(
      List.unmodifiable(_sheets),
      List.unmodifiable(_diagnostics),
      prepared: List.unmodifiable(_prepared),
      loaded: _failures == 0,
    );
  }

  Future<NativeLoadedDocumentStyles> loadInline(
    String cssText, {
    required String baseUrl,
    required String documentEncoding,
    required NativeStylesheetRequestOptions options,
  }) async {
    _checkCurrent();
    await _expand(
      NativeDocumentStylesheet(cssText, baseUrl: baseUrl),
      documentEncoding,
      const {},
      0,
      const [],
      options,
    );
    _checkCurrent();
    return NativeLoadedDocumentStyles(
      List.unmodifiable(_sheets),
      List.unmodifiable(_diagnostics),
      loaded: _failures == 0,
    );
  }

  Future<NativeLoadedDocumentStyles> loadExternal(
    String href, {
    required String baseUrl,
    required String documentEncoding,
    required NativeStylesheetRequestOptions options,
  }) async {
    _checkCurrent();
    await _external(
      href,
      baseUrl,
      documentEncoding,
      const {},
      0,
      const [],
      options,
    );
    _checkCurrent();
    return NativeLoadedDocumentStyles(
      List.unmodifiable(_sheets),
      List.unmodifiable(_diagnostics),
      loaded: _failures == 0,
    );
  }

  void _checkCurrent() {
    if (!isCurrent()) {
      throw StateError(tr("Document stylesheet load is stale."));
    }
  }

  Future<void> _external(
    String href,
    String baseUrl,
    String fallbackEncoding,
    Set<String> ancestors,
    int depth,
    List<String> conditions,
    NativeStylesheetRequestOptions options,
  ) async {
    _checkCurrent();
    if (depth > maximumImportDepth || _sourceCount >= maximumSources) {
      _failures++;
      _diagnostics.add(tr("Stylesheet import/source limit exceeded."));
      return;
    }
    try {
      final url = await resolve(href, baseUrl);
      _checkCurrent();
      if (ancestors.contains(url)) {
        _diagnostics.add(tr("Cyclic stylesheet import ignored: {0}", [url]));
        return;
      }
      final response = await _cache.putIfAbsent(
        options.cacheKey(url),
        () =>
            fetchWithOptions?.call(url, baseUrl, options) ??
            fetch(url, baseUrl),
      );
      _checkCurrent();
      final status = (response['status'] as num).toInt();
      if (status < 200 || status >= 300) {
        _failures++;
        _diagnostics.add(tr("Stylesheet HTTP {0}: {1}", [status, url]));
        return;
      }
      if (response['mimeType'] != 'text/css') {
        _failures++;
        _diagnostics.add(
          tr("Stylesheet MIME {0} rejected: {1}", [response['mimeType'], url]),
        );
        return;
      }
      final data = response['bytes'];
      final bytes = data is Uint8List
          ? data
          : Uint8List.fromList((data as List).cast<int>());
      if (_bytes + bytes.length > maximumBytes) {
        _failures++;
        _diagnostics.add(tr("Stylesheet byte limit exceeded: {0}", [url]));
        return;
      }
      final finalUrl = response['finalUrl'] as String;
      if (ancestors.contains(finalUrl)) {
        _diagnostics.add(
          tr("Cyclic stylesheet redirect ignored: {0}", [finalUrl]),
        );
        return;
      }
      final declaredEncoding = response['charset'] as String?;
      // CSS Syntax's fallback order: transport, leading @charset, then the
      // referring document/sheet encoding. BOM is handled by the decoder.
      final initial = String.fromCharCodes(bytes.take(1024));
      final charset = RegExp(r'^@charset "([^"\r\n]+)";').firstMatch(initial);
      final decoded = NativeHtmlDocumentContent.fromBytes(
        bytes,
        mimeType: 'text/css',
        charset: declaredEncoding ?? charset?.group(1) ?? fallbackEncoding,
      );
      await _expand(
        NativeDocumentStylesheet(decoded.text, baseUrl: finalUrl),
        decoded.encoding,
        {...ancestors, url, finalUrl},
        depth,
        conditions,
        options.imported(
          finalUrl,
          response['stylesheetReferrerPolicy'] as String?,
        ),
      );
    } catch (e) {
      if (e is PlatformException &&
          const {
            'account_changed',
            'unpaired',
          }.contains(obj(e.details)['code'])) {
        rethrow;
      }
      _checkCurrent();
      _failures++;
      _diagnostics.add(
        tr("Stylesheet could not load: {0}", [LiveController.describe(e)]),
      );
    }
  }

  Future<void> _expand(
    NativeDocumentStylesheet sheet,
    String encoding,
    Set<String> ancestors,
    int depth,
    List<String> conditions,
    NativeStylesheetRequestOptions options,
  ) async {
    _checkCurrent();
    if (++_sourceCount > maximumSources) {
      _failures++;
      _diagnostics.add(tr("Stylesheet source limit exceeded."));
      return;
    }
    // Include inline sources in the same document-wide resource budget.
    _bytes += sheet.cssText.length * 2;
    if (_bytes > maximumBytes) {
      _failures++;
      _diagnostics.add(tr("Stylesheet decoded-text limit exceeded."));
      return;
    }
    for (final imported in NativeDocumentStyleEngine.importsOf(sheet)) {
      if (!imported.supported) {
        _diagnostics.add(
          tr("Unsupported stylesheet import: {0}", [imported.href]),
        );
        continue;
      }
      await _external(
        imported.href,
        sheet.baseUrl,
        encoding,
        ancestors,
        depth + 1,
        [
          ...conditions,
          if (imported.media?.isNotEmpty == true) imported.media!,
        ],
        options.imported(sheet.baseUrl, options.referrerPolicy),
      );
    }
    // Nested @media blocks preserve AND between parent and import conditions,
    // including a comma-separated OR within either individual condition.
    var text = sheet.cssText;
    for (final condition in conditions.reversed) {
      text = '@media $condition {$text}';
    }
    _sheets.add(NativeDocumentStylesheet(text, baseUrl: sheet.baseUrl));
  }
}

/// Decode only into Dart. A stylesheet response is never a JavaScript payload.
Json nativeStylesheetResponse(Json response) {
  final raw = response['bodyBytes'];
  if (raw is! List ||
      raw.length > 8 * 1024 * 1024 ||
      raw.any((value) => value is! int || value < 0 || value > 255)) {
    throw FormatException(tr("Invalid stylesheet bytes (maximum 8 MiB)."));
  }
  if (response['status'] is! int ||
      response['url'] is! String ||
      response['mimeType'] is! String) {
    throw FormatException(tr("Invalid stylesheet response metadata."));
  }
  return {
    ...response,
    'finalUrl': response['url'],
    'bytes': Uint8List.fromList(raw.cast<int>()),
  };
}
