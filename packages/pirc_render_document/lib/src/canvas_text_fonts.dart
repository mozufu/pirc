import 'package:flutter/services.dart';

/// The system fonts that Android's text shaper picks for Canvas text in
/// document scripts, through the `org.mozufu.pirc/fonts` channel (M8 step 7).
/// The Kotlin side reads installed fonts only; it makes no request.
abstract interface class CanvasTextFonts {
  /// Whether [collect] works here (Android 12 or later).
  Future<bool> supported();

  /// The fonts for each of [families] (at most 16) in regular, italic, bold
  /// and bold italic, for Latin letters, digits and the scripts of [sample]
  /// (at most 4096 UTF-16 code units).
  Future<CanvasTextFontSet> collect(List<String> families, String sample);
}

/// One font file, as the shaper selected it.
class CanvasTextFontResource {
  const CanvasTextFontResource({
    required this.id,
    required this.bytes,
    required this.ttcIndex,
    required this.originalTtcIndex,
    required this.weight,
    required this.italic,
    required this.fakeBold,
    required this.fakeItalic,
    required this.axes,
    required this.label,
  });

  factory CanvasTextFontResource.fromMap(Map<Object?, Object?> map) =>
      CanvasTextFontResource(
        id: map['id']! as String,
        bytes: map['bytes']! as Uint8List,
        ttcIndex: map['ttcIndex']! as int,
        originalTtcIndex: map['originalTtcIndex']! as int,
        weight: map['weight']! as int,
        italic: map['italic']! as bool,
        fakeBold: map['fakeBold']! as bool,
        fakeItalic: map['fakeItalic']! as bool,
        axes: {
          for (final axis in (map['axes'] as List? ?? const []).cast<Map>())
            axis['axis'] as String: (axis['value'] as num).toDouble(),
        },
        label: map['label']! as String,
      );

  final String id;
  final Uint8List bytes;
  final int ttcIndex, originalTtcIndex, weight;
  final bool italic, fakeBold, fakeItalic;

  /// Variation axis values by tag (`wght`, `ital`, …).
  final Map<String, double> axes;

  /// The system file name, for diagnostics.
  final String label;
}

/// Which resources one family uses at one weight and slant.
class CanvasTextFontMatch {
  const CanvasTextFontMatch({
    required this.family,
    required this.weight,
    required this.italic,
    required this.resourceIds,
  });

  factory CanvasTextFontMatch.fromMap(Map<Object?, Object?> map) =>
      CanvasTextFontMatch(
        family: map['family']! as String,
        weight: map['weight']! as int,
        italic: map['italic']! as bool,
        resourceIds: (map['resourceIds']! as List).cast<String>(),
      );

  final String family;
  final int weight;
  final bool italic;
  final List<String> resourceIds;
}

class CanvasTextFontSet {
  const CanvasTextFontSet({required this.resources, required this.matches});

  factory CanvasTextFontSet.fromMap(Map<Object?, Object?> map) =>
      CanvasTextFontSet(
        resources: [
          for (final resource in (map['resources']! as List).cast<Map>())
            CanvasTextFontResource.fromMap(resource),
        ],
        matches: [
          for (final match in (map['matches']! as List).cast<Map>())
            CanvasTextFontMatch.fromMap(match),
        ],
      );

  final List<CanvasTextFontResource> resources;
  final List<CanvasTextFontMatch> matches;
}

class ChannelCanvasTextFonts implements CanvasTextFonts {
  const ChannelCanvasTextFonts();

  static const channel = MethodChannel('org.mozufu.pirc/fonts');

  @override
  Future<bool> supported() async {
    try {
      final result = await channel.invokeMapMethod<String, Object?>(
        'fontCapabilities',
      );
      return result?['canvasText'] == true;
    } on MissingPluginException {
      return false;
    }
  }

  @override
  Future<CanvasTextFontSet> collect(
    List<String> families,
    String sample,
  ) async {
    final result = await channel.invokeMapMethod<Object?, Object?>(
      'canvasTextFonts',
      {'families': families, 'sample': sample},
    );
    return CanvasTextFontSet.fromMap(result!);
  }
}

/// For tests: a fixed font set, and the requests made.
class FakeCanvasTextFonts implements CanvasTextFonts {
  FakeCanvasTextFonts({
    this.isSupported = true,
    this.fonts = const CanvasTextFontSet(resources: [], matches: []),
  });

  bool isSupported;
  CanvasTextFontSet fonts;
  final requests = <(List<String>, String)>[];

  @override
  Future<bool> supported() async => isSupported;

  @override
  Future<CanvasTextFontSet> collect(
    List<String> families,
    String sample,
  ) async {
    if (!isSupported) throw PlatformException(code: 'UNSUPPORTED');
    requests.add((families, sample));
    return fonts;
  }
}
