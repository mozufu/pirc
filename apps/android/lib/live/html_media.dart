import '../l10n/app_i18n.dart';
import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_render/src/html_media_spec.dart';
import 'package:pirc_render/src/html_media_box.dart';
import 'package:pirc_render/src/html_inline_intrinsic_overflow.dart';
import 'gateway.dart';
import 'document_navigation_state.dart';
import 'package:pirc_render/src/document_object_urls.dart';
import 'document_download.dart';
import 'markdown_image.dart';
import 'package:pirc_render/src/remote_content_gate.dart';
import 'common.dart' show guarded;

String htmlMediaSignature(NativeHtmlMediaSpec spec) =>
    '${spec.kind.name}:${spec.hasSrcAttribute}:${spec.rawSrc}:${spec.candidates.map((s) => '${s.url}|${s.typeHint}').join(';')}';

bool htmlMediaTypeHintSupported(String? hint) {
  if (hint == null || hint.trim().isEmpty) return true;
  final mime = hint.split(';').first.trim().toLowerCase();
  return const {
    'audio/mpeg',
    'audio/mp3',
    'audio/mp4',
    'audio/aac',
    'audio/wav',
    'audio/x-wav',
    'audio/wave',
    'audio/flac',
    'audio/x-flac',
    'audio/ogg',
    'audio/webm',
    'video/mp4',
    'video/webm',
    'video/ogg',
    'video/quicktime',
    'application/ogg',
  }.contains(mime);
}

class HtmlMediaState extends ChangeNotifier {
  HtmlMediaState({
    required this.gateway,
    required this.spec,
    required this.isCurrent,
    this.baseUrl,
    this.documentUrl,
    this.connection,
    this.objectUrls,
  }) : muted = spec.muted;
  final Gateway gateway;
  NativeHtmlMediaSpec spec;
  final String? baseUrl, documentUrl;
  final bool Function() isCurrent;
  final Future<Json> Function()? connection;
  final NativeDocumentObjectUrlBinding? objectUrls;
  Json? data;
  String? error, loadedSource;
  bool disposed = false, loading = false, active = false, everPlayed = false;
  bool muted;
  double rate = 1;
  int _ticket = 0, _revision = 0, _seekRevision = 0;
  Future<bool>? _opening;
  Timer? _poll;
  bool _polling = false;
  int? get id => data?['id'] as int?;
  bool get playing => data?['playing'] == true;
  double get duration =>
      math.max(0, (data?['duration'] as num?)?.toDouble() ?? 0);
  double get position =>
      ((data?['position'] as num?)?.toDouble() ?? 0).clamp(0, duration);
  bool get valid => !disposed && isCurrent();
  void emit() {
    if (!disposed) notifyListeners();
  }

  Future<void> _close(int player) async {
    try {
      await gateway.call('htmlMediaClose', {'id': player});
    } catch (_) {}
  }

  void initialize() {
    muted = spec.muted;
    if (spec.candidates.isEmpty) return;
    if (spec.preload?.trim().toLowerCase() != 'none' ||
        spec.autoplay && spec.muted) {
      unawaited(open());
    }
  }

  Future<bool> open() {
    if (_opening != null) return _opening!;
    if (!valid || spec.candidates.isEmpty) return Future.value(false);
    final ticket = ++_ticket;
    loading = true;
    error = null;
    emit();
    Future<bool> run() async {
      try {
        final boot = connection == null
            ? obj(await gateway.call('boot'))
            : await connection!();
        if (!valid || ticket != _ticket) return false;
        Object? lastFailure;
        for (final candidate in spec.candidates) {
          if (!htmlMediaTypeHintSupported(candidate.typeHint)) continue;
          try {
            final args = <String, dynamic>{
              'pairingStamp': boot['pairingStamp'],
              'kind': spec.kind.name,
              'muted': muted,
              'loop': spec.loop,
            };
            final source = candidate.url
                .replaceAll(RegExp(r'[\t\n\r]'), '')
                .replaceAll(RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'), '');
            final sourceScheme = Uri.tryParse(source)?.scheme.toLowerCase();
            if (sourceScheme == 'blob') {
              final binding = objectUrls;
              if (binding == null) {
                throw StateError(tr("Document object URL is unavailable."));
              }
              if (!valid || ticket != _ticket || !binding.current) return false;
              final blob = await binding.read(source);
              if (!valid || ticket != _ticket || !binding.current) return false;
              args.addAll({'bytes': blob.bytes, 'mimeType': blob.mimeType});
            } else if (sourceScheme == 'data') {
              if (source.length > 32 * 1024 * 1024 * 3 + 4096) {
                throw StateError(tr("Media exceeds 32 MiB."));
              }
              final uri = UriData.parse(source), bytes = uri.contentAsBytes();
              if (bytes.length > 32 * 1024 * 1024) {
                throw StateError(tr("Media exceeds 32 MiB."));
              }
              args.addAll({'bytes': bytes, 'mimeType': uri.mimeType});
            } else {
              args.addAll({
                'source': source,
                if (baseUrl != null) 'baseUrl': baseUrl,
                if (documentUrl != null) 'documentUrl': documentUrl,
              });
            }
            final result = obj(await gateway.call('htmlMediaOpen', args));
            final player = result['id'] as int;
            if (!valid ||
                ticket != _ticket ||
                (sourceScheme == 'blob' && objectUrls?.current != true)) {
              await _close(player);
              return false;
            }
            data = result;
            loadedSource = source;
            error = null;
            _poll ??= Timer.periodic(const Duration(milliseconds: 200), (
              _,
            ) async {
              if (!valid || !active || !playing || _polling) return;
              _polling = true;
              try {
                await command('status');
              } finally {
                _polling = false;
              }
            });
            if (spec.autoplay && muted && active) {
              await command('play');
            }
            emit();
            return true;
          } catch (e) {
            lastFailure = e;
            if (!valid || ticket != _ticket || objectUrls?.current == false) {
              return false;
            }
          }
        }
        throw lastFailure ?? StateError(tr("No playable media source."));
      } catch (_) {
        if (valid && ticket == _ticket) {
          error = tr("Unable to play media.");
          emit();
        }
        return false;
      } finally {
        if (!disposed && ticket == _ticket) {
          loading = false;
          _opening = null;
          emit();
        }
      }
    }

    return _opening = run();
  }

  Future<bool> command(
    String action, {
    double? position,
    double? volume,
    double? rate,
    bool? loop,
  }) async {
    if (!valid || id == null || action == 'play' && !active) return false;
    final revision = ++_revision, player = id;
    final seekRevision = action == 'seek' ? ++_seekRevision : null;
    try {
      final result = obj(
        await gateway.call('htmlMediaControl', {
          'id': player,
          'action': action,
          'position': ?position?.round(),
          'volume': ?volume,
          'rate': ?rate,
          'loop': ?loop,
        }),
      );
      if (valid && id == player && action == 'play' && !active) {
        await command('pause');
        return false;
      }
      if (valid && revision == _revision && id == player) {
        data = result;
        error = null;
        if (action == 'play') everPlayed = true;
        emit();
      } else if (valid &&
          id == player &&
          action == 'seek' &&
          seekRevision == _seekRevision) {
        data = {...?data, 'position': result['position']};
        emit();
      }
      return valid && id == player;
    } catch (_) {
      if (valid && revision == _revision) {
        error = tr("Unable to control media.");
        emit();
      }
      return false;
    }
  }

  Future<void> togglePlay() async {
    if (loading) return;
    if (id == null && !await open()) return;
    await command(playing ? 'pause' : 'play');
  }

  Future<void> retry() async {
    final previous = id;
    data = null;
    error = null;
    ++_ticket;
    ++_revision;
    if (previous != null) await _close(previous);
    if (valid) await open();
  }

  void setActive(bool value) {
    if (active == value) return;
    active = value;
    if (!value && playing) {
      unawaited(command('pause'));
    }
  }

  Future<void> toggleMute() async {
    final next = !muted;
    if (await command('volume', volume: next ? 0 : 1)) {
      muted = next;
      emit();
    }
  }

  Future<void> setRate(double value) async {
    if (await command('rate', rate: value)) {
      rate = value;
      emit();
    }
  }

  Future<void> applyFlags(NativeHtmlMediaSpec next) async {
    final old = spec;
    spec = next;
    if (old.loop != next.loop && id != null) {
      await command('loop', loop: next.loop);
    }
    if (old.muted != next.muted &&
        id != null &&
        await command('volume', volume: next.muted ? 0 : 1)) {
      muted = next.muted;
      emit();
    }
  }

  Future<void> save() async {
    final player = id;
    if (!valid || player == null) return;
    final result = obj(await gateway.call('htmlMediaRead', {'id': player}));
    if (!valid || id != player) return;
    await NativeDocumentDownload.response(
      result,
    ).save(gateway, '${result['pairingStamp']}');
  }

  @override
  void dispose() {
    disposed = true;
    ++_ticket;
    ++_revision;
    _poll?.cancel();
    final player = id;
    if (player != null) unawaited(_close(player));
    super.dispose();
  }
}

/// Flutter controls and texture display for an HTML media element.
///
/// In held content a remote source (including a poster) is a placeholder until
/// the user taps it: the player, which opens the media and fetches the poster,
/// is not built before that. Inline `data:` and local `blob:` sources play as
/// before.
class NativeHtmlMedia extends StatelessWidget {
  const NativeHtmlMedia({
    super.key,
    required this.gateway,
    required this.spec,
    this.baseUrl,
    this.scope,
    this.accountIdentity,
    this.styles = const {},
  });
  final Gateway gateway;
  final NativeHtmlMediaSpec spec;
  final String? baseUrl;
  final NativeDocumentScope? scope;
  final Object? accountIdentity;
  final Map<String, String> styles;

  static String? _remoteReference(String? raw) {
    if (raw == null) return null;
    final value = raw
        .replaceAll(RegExp(r'[\t\n\r]'), '')
        .replaceAll(RegExp(r'^[\x00-\x20]+|[\x00-\x20]+$'), '');
    final scheme = Uri.tryParse(value)?.scheme.toLowerCase();
    return scheme == 'data' || scheme == 'blob' ? null : value;
  }

  @override
  Widget build(BuildContext context) {
    final player = NativeHtmlMediaPlayer(
      gateway: gateway,
      spec: spec,
      baseUrl: baseUrl,
      scope: scope,
      accountIdentity: accountIdentity,
      styles: styles,
    );
    final remote = [
      for (final candidate in spec.candidates) _remoteReference(candidate.url),
      _remoteReference(spec.poster),
    ].nonNulls.firstOrNull;
    if (remote == null) return player;
    return NativeRemoteContentGate(
      source: remote,
      kind: NativeRemoteContentKind.media,
      builder: (_) => player,
    );
  }
}

/// The player behind [NativeHtmlMedia]; building it starts the media load.
class NativeHtmlMediaPlayer extends StatefulWidget {
  const NativeHtmlMediaPlayer({
    super.key,
    required this.gateway,
    required this.spec,
    this.baseUrl,
    this.scope,
    this.accountIdentity,
    this.styles = const {},
  });
  final Gateway gateway;
  final NativeHtmlMediaSpec spec;
  final String? baseUrl;
  final NativeDocumentScope? scope;
  final Object? accountIdentity;
  final Map<String, String> styles;
  @override
  State<NativeHtmlMediaPlayer> createState() => _NativeHtmlMediaState();
}

class _NativeHtmlMediaState extends State<NativeHtmlMediaPlayer>
    with WidgetsBindingObserver {
  late HtmlMediaState state;
  NativeDocumentObjectUrlBinding? _objectUrls;
  bool _created = false;
  DialogRoute<void>? expanded;
  bool saving = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _create() {
    final scope = widget.scope,
        account = widget.accountIdentity ?? widget.scope?.accountIdentity;
    state = HtmlMediaState(
      gateway: widget.gateway,
      spec: widget.spec,
      baseUrl: widget.baseUrl,
      documentUrl: scope?.documentUrl,
      connection: scope?.windows.connection,
      objectUrls: _objectUrls,
      isCurrent: () =>
          mounted &&
          (scope == null ||
              !scope.windows.disposed &&
                  scope.windows.accountIdentity == account &&
                  scope.window?.disposed != true),
    );
    state.initialize();
  }

  @override
  void didUpdateWidget(NativeHtmlMediaPlayer old) {
    super.didUpdateWidget(old);
    if (old.gateway != widget.gateway ||
        old.baseUrl != widget.baseUrl ||
        old.scope?.documentUrl != widget.scope?.documentUrl ||
        old.accountIdentity != widget.accountIdentity ||
        htmlMediaSignature(old.spec) != htmlMediaSignature(widget.spec)) {
      _closeExpanded();
      state.dispose();
      _create();
      _visibility();
    } else {
      unawaited(state.applyFlags(widget.spec));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final binding = NativeDocumentObjectUrlScope.maybeOf(context)?.binding;
    if (!_created || !identical(binding, _objectUrls)) {
      if (_created) state.dispose();
      _objectUrls = binding;
      _create();
      _created = true;
    }
    _visibility();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState value) {
    _visibility();
  }

  void _visibility() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final visible =
        (lifecycle == null || lifecycle == AppLifecycleState.resumed) &&
        TickerMode.valuesOf(context).enabled &&
        (expanded?.isActive ?? ModalRoute.of(context)?.isActive ?? true);
    state.setActive(visible);
  }

  void _closeExpanded() {
    final route = expanded;
    expanded = null;
    if (route?.isActive == true) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (route!.isActive) route.navigator?.removeRoute(route);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closeExpanded();
    state.dispose();
    super.dispose();
  }

  bool get audio => widget.spec.kind == NativeHtmlMediaKind.audio;
  String time(double value) {
    final s = value ~/ 1000;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Size get dimensions {
    if (audio) return widget.spec.controls ? const Size(300, 54) : Size.zero;
    final naturalW = (state.data?['width'] as num?)?.toDouble() ?? 0,
        naturalH = (state.data?['height'] as num?)?.toDouble() ?? 0;
    final hasNatural = naturalW > 0 && naturalH > 0;
    final widthAttr = widget.styles.containsKey('width')
        ? null
        : widget.spec.width;
    final heightAttr = widget.styles.containsKey('height')
        ? null
        : widget.spec.height;
    final width =
        widthAttr?.toDouble() ??
        (widget.spec.height != null && hasNatural
            ? widget.spec.height! * naturalW / naturalH
            : hasNatural
            ? naturalW
            : 300);
    final height =
        heightAttr?.toDouble() ??
        (widget.spec.width != null && hasNatural
            ? widget.spec.width! * naturalH / naturalW
            : hasNatural
            ? naturalH
            : 150);
    return Size(width, height);
  }

  Future<void> expand() async {
    if (expanded != null) return;
    final route = DialogRoute<void>(
      context: context,
      builder: (context) => Dialog.fullscreen(
        backgroundColor: Colors.black,
        child: SafeArea(
          child: AnimatedBuilder(
            animation: state,
            builder: (context, _) => _video(context, full: true),
          ),
        ),
      ),
    );
    setState(() => expanded = route);
    state.setActive(true);
    await Navigator.of(context, rootNavigator: false).push(route);
    if (mounted && identical(expanded, route)) {
      expanded = null;
      _visibility();
    }
  }

  Widget _button(
    String label,
    IconData icon,
    VoidCallback? action, {
    bool light = false,
  }) => SizedBox(
    width: 36,
    height: 36,
    child: IconButton(
      tooltip: label,
      onPressed: action,
      padding: EdgeInsets.zero,
      icon: Icon(
        icon,
        size: 18,
        color: light ? Colors.white : const Color(0xff202124),
      ),
    ),
  );
  Widget _controls(BuildContext context, {bool full = false}) {
    final light = !audio || Theme.of(context).brightness == Brightness.dark;
    return LayoutBuilder(
      builder: (context, box) {
        final wide =
            box.maxWidth > 240 &&
            MediaQuery.textScalerOf(context).scale(11) <= 15;
        if (box.maxWidth < 36) return SizedBox(height: audio ? 54 : 40);
        final color = light ? Colors.white : const Color(0xff202124);
        return SizedBox(
          height: audio ? 54 : 40,
          child: Row(
            children: [
              _button(
                state.playing ? tr("Pause media") : tr("Play media"),
                state.playing ? LucideIcons.pause : LucideIcons.play,
                state.loading || widget.spec.candidates.isEmpty
                    ? null
                    : () => unawaited(state.togglePlay()),
                light: light,
              ),
              if (wide)
                Text(
                  '${time(state.position)} / ${time(state.duration)}',
                  style: TextStyle(color: color, fontSize: 11, height: 1),
                ),
              if (box.maxWidth >= 120)
                Expanded(
                  child: SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 4,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 8,
                      ),
                      activeTrackColor: color,
                      inactiveTrackColor: color.withValues(alpha: .3),
                      thumbColor: color,
                    ),
                    child: Slider(
                      value: state.position,
                      max: state.duration > 0 ? state.duration : 1,
                      onChanged: state.id == null
                          ? null
                          : (value) => unawaited(
                              state.command('seek', position: value),
                            ),
                    ),
                  ),
                ),
              if (box.maxWidth < 120) const Spacer(),
              if (wide)
                _button(
                  state.muted ? tr("Unmute media") : tr("Mute media"),
                  state.muted ? LucideIcons.volumeX : LucideIcons.volume2,
                  state.id == null ? null : () => unawaited(state.toggleMute()),
                  light: light,
                ),
              if (!audio && wide)
                _button(
                  full ? tr("Exit fullscreen") : tr("Fullscreen media"),
                  full ? LucideIcons.minimize : LucideIcons.maximize,
                  state.id == null
                      ? null
                      : () =>
                            full ? Navigator.pop(context) : unawaited(expand()),
                  light: true,
                ),
              if (box.maxWidth >= 84)
                PopupMenuButton<String>(
                  tooltip: tr("More media controls"),
                  enabled: state.id != null,
                  icon: Icon(
                    LucideIcons.ellipsisVertical,
                    size: 17,
                    color: color,
                  ),
                  padding: EdgeInsets.zero,
                  onSelected: (value) async {
                    if (value == 'mute') {
                      await state.toggleMute();
                    } else if (value == 'fullscreen') {
                      if (full) {
                        Navigator.pop(context);
                      } else {
                        await expand();
                      }
                    } else if (value == 'save') {
                      if (saving) return;
                      setState(() => saving = true);
                      try {
                        await guarded(context, state.save);
                      } finally {
                        if (mounted) setState(() => saving = false);
                      }
                    } else {
                      await state.setRate(double.parse(value));
                    }
                  },
                  itemBuilder: (_) => [
                    if (!wide)
                      PopupMenuItem(
                        value: 'mute',
                        child: Text(
                          state.muted ? tr("Unmute media") : tr("Mute media"),
                        ),
                      ),
                    if (!audio && !wide)
                      PopupMenuItem(
                        value: 'fullscreen',
                        child: Text(
                          full ? tr("Exit fullscreen") : tr("Fullscreen media"),
                        ),
                      ),
                    for (final rate in [
                      .25,
                      .5,
                      .75,
                      1.0,
                      1.25,
                      1.5,
                      1.75,
                      2.0,
                    ])
                      PopupMenuItem(
                        value: '$rate',
                        child: Text(
                          '${rate == 1 ? 'Normal' : '$rate×'}${state.rate == rate ? ' ✓' : ''}',
                        ),
                      ),
                    PopupMenuItem(
                      value: 'save',
                      enabled: !saving,
                      child: Text(tr("Save media")),
                    ),
                  ],
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _error() => LayoutBuilder(
    builder: (context, box) {
      if (box.maxWidth < 160 || box.maxHeight < 120) {
        return Center(
          child: _button(
            tr("Unable to play media. Retry"),
            LucideIcons.rotateCw,
            () => unawaited(state.retry()),
            light: true,
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              tr("Unable to play media."),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: Colors.white, fontSize: 12),
            ),
            TextButton(
              onPressed: () => unawaited(state.retry()),
              child: Text(tr("Retry")),
            ),
          ],
        ),
      );
    },
  );
  Widget _video(BuildContext context, {bool full = false}) {
    final poster = widget.spec.poster;
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (state.id != null &&
              (full || expanded == null) &&
              (poster == null || state.everPlayed))
            FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: ((state.data?['width'] as num?)?.toDouble() ?? 1).clamp(
                  1,
                  double.infinity,
                ),
                height: ((state.data?['height'] as num?)?.toDouble() ?? 1)
                    .clamp(1, double.infinity),
                child: Texture(textureId: state.id!),
              ),
            ),
          if (poster != null && !state.everPlayed)
            NativeMarkdownImage(
              gateway: widget.gateway,
              source: Uri.parse(poster),
              baseUrl: widget.baseUrl,
              borderRadius: 0,
            ),
          if (state.loading)
            const Center(
              child: SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          if (state.error != null) _error(),
          if (widget.spec.controls)
            Align(
              alignment: Alignment.bottomCenter,
              child: ColoredBox(
                color: const Color(0xbb000000),
                child: _controls(context, full: full),
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    AppI18n.watch(context);
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        final size = dimensions;
        if (audio &&
            !widget.spec.controls &&
            widget.styles['display'] == null) {
          return const SizedBox.shrink();
        }
        final child = audio
            ? Material(
                color: Theme.of(context).brightness == Brightness.dark
                    ? const Color(0xff333333)
                    : const Color(0xfff1f3f4),
                borderRadius: BorderRadius.circular(27),
                child: state.error != null
                    ? Row(
                        children: [
                          Expanded(
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Text(
                                tr("Unable to play media."),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11,
                                  color:
                                      Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : const Color(0xff202124),
                                ),
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () => unawaited(state.retry()),
                            child: Text(tr("Retry")),
                          ),
                        ],
                      )
                    : _controls(context),
              )
            : _video(context);
        final width = (state.data?['width'] as num?)?.toDouble() ?? 0,
            height = (state.data?['height'] as num?)?.toDouble() ?? 0;
        final frame = NativeHtmlMediaBox(
          naturalSize: size,
          styles: widget.styles,
          fontSize:
              double.tryParse(
                (widget.styles['font-size'] ?? '').replaceFirst(
                  RegExp(r'px$'),
                  '',
                ),
              ) ??
              DefaultTextStyle.of(context).style.fontSize ??
              16,
          intrinsicRatio: !audio && width > 0 && height > 0
              ? width / height
              : null,
          widthAttributeSpecified:
              !widget.styles.containsKey('width') && widget.spec.width != null,
          heightAttributeSpecified:
              !widget.styles.containsKey('height') &&
              widget.spec.height != null,
          child: size.width == 0 || size.height == 0
              ? const SizedBox.shrink()
              : child,
        );
        if (widget.styles.values.any((value) => value.contains('%'))) {
          return frame;
        }
        return NativeHtmlInlineIntrinsicOverflow(
          intrinsicSize: frame.intrinsicSize,
          baselineFromTop: frame.intrinsicSize.height,
          child: frame,
        );
      },
    );
  }
}
