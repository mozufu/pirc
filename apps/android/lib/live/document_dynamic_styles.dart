import '../l10n/app_i18n.dart';
import 'package:pirc_render/src/html_document_styles.dart';
import 'document_style_loading.dart';
import 'gateway.dart';

/// Maintains the author styles represented by a live document snapshot.
///
/// Inline styles are available immediately from their raw text. External link
/// styles are added only after [complete] receives the result for the current
/// transport ID. This class owns no network work; callers start requests for
/// requestable link descriptors and complete them when the native loader ends.
class NativeDynamicDocumentStyles {
  NativeDynamicDocumentStyles({
    Iterable<NativePreparedDocumentStyle> seeds = const [],
    this.maximumSources = defaultMaximumSources,
    this.maximumBytes = defaultMaximumBytes,
  }) : _seeds = List<NativePreparedDocumentStyle>.of(seeds) {
    if (maximumSources < 0 || maximumBytes < 0) {
      throw ArgumentError('Stylesheet limits cannot be negative.');
    }
  }

  static const int defaultMaximumSources = 64;
  static const int defaultMaximumBytes = 8 * 1024 * 1024;

  final int maximumSources;
  final int maximumBytes;
  final List<NativePreparedDocumentStyle> _seeds;
  Map<String, _DynamicStyleOwner> _owners = {};
  List<String> _snapshotDiagnostics = const [];
  List<NativeDocumentStylesheet> _stylesheets = const [];
  List<String> _diagnostics = const [];
  bool _firstSnapshotSeen = false;

  /// Current stylesheet sources in document order.
  List<NativeDocumentStylesheet> get stylesheets =>
      List<NativeDocumentStylesheet>.unmodifiable(_stylesheets);

  /// Snapshot, loader, and budget diagnostics for the current document state.
  List<String> get diagnostics => List<String>.unmodifiable(_diagnostics);

  /// Replaces the current owner snapshot and drops owners/revisions no longer
  /// present. The input has separate `sheets` and `links` descriptor arrays.
  void update(Json descriptorSnapshot) {
    final nextDiagnostics = <String>[];
    final parsed = <_DynamicStyleOwner>[];
    var sequence = 0;

    void readOwners(Object? value, {required bool inline}) {
      if (value == null) return;
      if (value is! List) {
        nextDiagnostics.add(
          tr("Invalid {0} stylesheet snapshot.", [inline ? 'sheets' : 'links']),
        );
        return;
      }
      for (final raw in value) {
        final descriptor = _asJson(raw);
        if (descriptor == null) {
          nextDiagnostics.add(tr("Invalid stylesheet owner descriptor."));
          sequence++;
          continue;
        }
        final owner = _parseOwner(
          descriptor,
          inline: inline,
          sequence: sequence,
          diagnostics: nextDiagnostics,
        );
        sequence++;
        if (owner != null) parsed.add(owner);
      }
    }

    readOwners(descriptorSnapshot['sheets'], inline: true);
    readOwners(descriptorSnapshot['links'], inline: false);
    parsed.sort(_compareOwners);

    final nextOwners = <String, _DynamicStyleOwner>{};
    for (final owner in parsed) {
      if (nextOwners.containsKey(owner.ownerId)) {
        nextDiagnostics.add(
          tr("Duplicate stylesheet owner ignored: {0}.", [owner.ownerId]),
        );
        continue;
      }
      nextOwners[owner.ownerId] = owner;
    }

    if (!_firstSnapshotSeen) {
      _seedFirstSnapshot(nextOwners.values);
      _firstSnapshotSeen = true;
    } else {
      for (final owner in nextOwners.values) {
        final previous = _owners[owner.ownerId];
        if (previous != null && previous.canRetainFor(owner)) {
          owner.loaded = previous.loaded;
          owner.seedResult = previous.seedResult;
          owner.seedTaken = previous.seedTaken;
        }
      }
    }

    _owners = nextOwners;
    _snapshotDiagnostics = List<String>.unmodifiable(nextDiagnostics);
    _rebuild();
  }

  /// Returns a matching first-navigation seed at most once per transport ID.
  /// The seed remains active for rendering until its owner changes revision.
  NativeLoadedDocumentStyles? takeSeed(String transportId) {
    final matches = _owners.values
        .where((owner) => owner.transportId == transportId)
        .toList(growable: false);
    if (matches.length != 1) return null;
    final owner = matches.single;
    final seed = owner.seedResult;
    if (seed == null || owner.seedTaken) return null;
    owner.seedTaken = true;
    return seed;
  }

  /// Applies a completed stylesheet only while its transport ID still belongs
  /// to the current owner revision. This also accepts expanded inline imports.
  /// Partial styles are kept when [NativeLoadedDocumentStyles.loaded] is false.
  bool complete(String transportId, NativeLoadedDocumentStyles loaded) {
    final matches = _owners.values
        .where((owner) => owner.transportId == transportId)
        .toList(growable: false);
    if (matches.length != 1) return false;
    final owner = matches.single;
    if (!owner.isStylesheet) return false;

    owner.loaded = _copyLoaded(loaded);
    owner.seedResult = null;
    owner.seedTaken = true;
    _rebuild();
    return true;
  }

  void _seedFirstSnapshot(Iterable<_DynamicStyleOwner> owners) {
    final available = List<NativePreparedDocumentStyle>.of(_seeds);
    for (final owner in owners) {
      if (!owner.isStylesheet) continue;
      final index = available.indexWhere((seed) => _seedMatches(seed, owner));
      if (index < 0) continue;
      final seed = available.removeAt(index);
      final result = NativeLoadedDocumentStyles(
        List<NativeDocumentStylesheet>.unmodifiable(seed.unwrappedStylesheets),
        List<String>.unmodifiable(seed.diagnostics),
        loaded: seed.loaded,
      );
      owner.loaded = result;
      owner.seedResult = result;
    }
    _seeds.clear();
  }

  bool _seedMatches(
    NativePreparedDocumentStyle seed,
    _DynamicStyleOwner owner,
  ) {
    if (seed.order != owner.order ||
        !_sameOptions(seed.options, owner.options)) {
      return false;
    }
    if (owner.inline) {
      return seed.baseUrl == owner.baseUrl &&
          seed.href == null &&
          seed.cssText == owner.cssText;
    }
    return owner.requestable &&
        seed.cssText == null &&
        seed.href == owner.fetchHref;
  }

  _DynamicStyleOwner? _parseOwner(
    Json descriptor, {
    required bool inline,
    required int sequence,
    required List<String> diagnostics,
  }) {
    final domId = _string(descriptor['id']) ?? '';
    final ownerId = _string(descriptor['ownerId']) ?? domId;
    if (ownerId.isEmpty) {
      diagnostics.add(tr("Stylesheet owner is missing ownerId."));
      return null;
    }

    final fallbackOrder = sequence;
    final rawOrder = descriptor['order'];
    final parsedOrder = _integer(rawOrder);
    if (rawOrder != null && parsedOrder == null) {
      diagnostics.add(tr("Invalid stylesheet order for owner {0}.", [ownerId]));
    }
    final revision = _integer(descriptor['revision']) ?? 0;
    final baseUrl =
        _string(descriptor['baseURL']) ?? _string(descriptor['baseUrl']) ?? '';
    final rawOptions =
        _asJson(descriptor['options'] ?? descriptor['requestOptions']) ??
        const <String, dynamic>{};
    final options = NativeStylesheetRequestOptions(
      crossOrigin: _string(
        descriptor['crossOrigin'] ?? rawOptions['crossOrigin'],
      ),
      integrity: _string(descriptor['integrity'] ?? rawOptions['integrity']),
      referrerPolicy: _string(
        descriptor['referrerPolicy'] ?? rawOptions['referrerPolicy'],
      ),
      referrerUrl:
          _string(
            descriptor['stylesheetReferrerUrl'] ??
                descriptor['referrerUrl'] ??
                rawOptions['stylesheetReferrerUrl'] ??
                rawOptions['referrerUrl'],
          ) ??
          baseUrl,
    );
    final cssText = _string(descriptor['cssText']);
    final fetchHref = _string(descriptor['fetchHref']);
    final href = _string(descriptor['href']);
    final isStylesheet = _boolean(descriptor['isStylesheet']) ?? true;
    final requestable = inline
        ? false
        : _boolean(descriptor['requestable']) ??
              (fetchHref != null && fetchHref.isNotEmpty);
    if (inline && cssText == null) {
      diagnostics.add(
        tr("Inline stylesheet owner {0} has no cssText.", [ownerId]),
      );
      return null;
    }
    if (baseUrl.isEmpty) {
      diagnostics.add(tr("Stylesheet owner {0} has no baseURL.", [ownerId]));
    }
    if (!inline && requestable && (fetchHref == null || fetchHref.isEmpty)) {
      diagnostics.add(
        tr("Stylesheet link owner {0} has no fetchHref (href: {1}).", [
          ownerId,
          href ?? 'null',
        ]),
      );
    }
    final transportId = _string(descriptor['transportId']);
    if (!inline &&
        requestable &&
        (transportId == null || transportId.isEmpty)) {
      diagnostics.add(
        tr("Stylesheet link owner {0} has no transportId.", [ownerId]),
      );
    }

    return _DynamicStyleOwner(
      ownerId: ownerId,
      domId: domId,
      order: parsedOrder ?? fallbackOrder,
      revision: revision,
      requestId: _string(descriptor['requestId']) ?? '$ownerId:$revision',
      transportId: transportId,
      baseUrl: baseUrl,
      disabled: _boolean(descriptor['disabled']) ?? false,
      media: _string(descriptor['media']),
      inline: inline,
      cssText: cssText,
      fetchHref: fetchHref,
      requestable: requestable,
      isStylesheet: isStylesheet,
      options: options,
      sequence: sequence,
    );
  }

  void _rebuild() {
    final result = <NativeDocumentStylesheet>[];
    final diagnostics = <String>[..._snapshotDiagnostics];
    final ordered = _owners.values.toList(growable: false)
      ..sort(_compareOwners);
    var sourceCount = 0;
    var sourceBytes = 0;
    var documentLimitReached = false;

    for (final owner in ordered) {
      if (!owner.isStylesheet) continue;
      final loaded = owner.loaded;
      if (loaded != null) diagnostics.addAll(loaded.diagnostics);

      final sources = owner.inline
          ? loaded?.stylesheets ??
                <NativeDocumentStylesheet>[
                  NativeDocumentStylesheet(
                    owner.cssText ?? '',
                    baseUrl: owner.baseUrl,
                  ),
                ]
          : owner.requestable
          ? loaded?.stylesheets ?? const <NativeDocumentStylesheet>[]
          : const <NativeDocumentStylesheet>[];
      final retained = <NativeDocumentStylesheet>[];
      String? truncationDiagnostic;

      for (final source in sources) {
        if (documentLimitReached) break;
        final sourceLabel = tr("owner {0}{1}", [
          owner.ownerId,
          owner.domId.isEmpty ? '' : ' (#${owner.domId})',
        ]);
        if (sourceCount >= maximumSources) {
          truncationDiagnostic = tr(
            "Document stylesheet source limit exceeded ({0}) at {1}.",
            [maximumSources, sourceLabel],
          );
          documentLimitReached = true;
          diagnostics.add(truncationDiagnostic);
          break;
        }
        final bytes = source.cssText.length * 2;
        if (bytes > maximumBytes - sourceBytes) {
          truncationDiagnostic = tr(
            "Document stylesheet decoded-text limit exceeded ({0} UTF-16 bytes) at {1}.",
            [maximumBytes, sourceLabel],
          );
          documentLimitReached = true;
          diagnostics.add(truncationDiagnostic);
          break;
        }

        sourceCount++;
        sourceBytes += bytes;
        retained.add(source);
        if (owner.disabled) continue;
        final currentMedia = owner.media?.trim();
        final media = currentMedia == null || currentMedia.isEmpty
            ? source.media
            : currentMedia;
        result.add(
          NativeDocumentStylesheet(
            source.cssText,
            baseUrl: source.baseUrl,
            media: media,
          ),
        );
      }

      // Keep only the document-wide valid prefix in owner state as well as in
      // the rendered list. This releases over-budget imported CSS instead of
      // retaining it behind a getter-only limit.
      if (loaded != null && retained.length != loaded.stylesheets.length) {
        final loadedDiagnostics = <String>[
          ...loaded.diagnostics,
          ?truncationDiagnostic,
        ];
        final compacted = NativeLoadedDocumentStyles(
          List<NativeDocumentStylesheet>.unmodifiable(retained),
          List<String>.unmodifiable(loadedDiagnostics),
          loaded: loaded.loaded,
        );
        owner.loaded = compacted;
        if (owner.seedResult != null) owner.seedResult = compacted;
      }
    }

    _stylesheets = List<NativeDocumentStylesheet>.unmodifiable(result);
    _diagnostics = List<String>.unmodifiable(diagnostics);
  }

  static NativeLoadedDocumentStyles _copyLoaded(
    NativeLoadedDocumentStyles loaded,
  ) => NativeLoadedDocumentStyles(
    List<NativeDocumentStylesheet>.unmodifiable(loaded.stylesheets),
    List<String>.unmodifiable(loaded.diagnostics),
    loaded: loaded.loaded,
  );

  static bool _sameOptions(
    NativeStylesheetRequestOptions left,
    NativeStylesheetRequestOptions right,
  ) =>
      left.crossOrigin == right.crossOrigin &&
      left.integrity == right.integrity &&
      left.referrerPolicy == right.referrerPolicy &&
      left.referrerUrl == right.referrerUrl;

  static int _compareOwners(_DynamicStyleOwner left, _DynamicStyleOwner right) {
    final byOrder = left.order.compareTo(right.order);
    return byOrder != 0 ? byOrder : left.sequence.compareTo(right.sequence);
  }

  static Json? _asJson(Object? value) {
    if (value is! Map) return null;
    final result = <String, dynamic>{};
    for (final entry in value.entries) {
      if (entry.key is String) result[entry.key as String] = entry.value;
    }
    return result;
  }

  static String? _string(Object? value) => value is String ? value : null;

  static bool? _boolean(Object? value) => value is bool ? value : null;

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num && value.isFinite) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

class _DynamicStyleOwner {
  _DynamicStyleOwner({
    required this.ownerId,
    required this.domId,
    required this.order,
    required this.revision,
    required this.requestId,
    required this.transportId,
    required this.baseUrl,
    required this.disabled,
    required this.media,
    required this.inline,
    required this.cssText,
    required this.fetchHref,
    required this.requestable,
    required this.isStylesheet,
    required this.options,
    required this.sequence,
  });

  final String ownerId;
  final String domId;
  final int order;
  final int revision;
  final String requestId;
  final String? transportId;
  final String baseUrl;
  final bool disabled;
  final String? media;
  final bool inline;
  final String? cssText;
  final String? fetchHref;
  final bool requestable;
  final bool isStylesheet;
  final NativeStylesheetRequestOptions options;
  final int sequence;

  NativeLoadedDocumentStyles? loaded;
  NativeLoadedDocumentStyles? seedResult;
  bool seedTaken = false;

  bool canRetainFor(_DynamicStyleOwner next) {
    if (ownerId != next.ownerId ||
        inline != next.inline ||
        revision != next.revision ||
        requestId != next.requestId ||
        transportId != next.transportId ||
        requestable != next.requestable ||
        isStylesheet != next.isStylesheet) {
      return false;
    }
    if (inline) return cssText == next.cssText;
    return fetchHref == next.fetchHref;
  }
}
