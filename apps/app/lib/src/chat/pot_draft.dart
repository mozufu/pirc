import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pirc_client/pirc_client.dart';

import '../work/composer/model_sheet.dart';

/// The personality templates of step ① (E7).
enum PersonalityTemplate { rigorous, concise, friendly, custom }

/// Autonomy review intervals of step ③: off, 1 day, 2 days, 1 week.
const reviewIntervals = <int?>[null, 86400, 172800, 604800];

/// Step indexes of the pot form (0-based).
abstract final class PotStep {
  static const look = 0;
  static const work = 1;
  static const reach = 2;
  static const models = 3;
  static const count = 4;
}

/// A problem the user must fix before going on; each step shows its own.
enum PotIssue {
  nameMissing,
  nameTooLong,
  personalityTooLong,
  introTooLong,
  descriptionTooLong,
  moneyInvalid,
  tokensInvalid,
  noModel,
}

const _keep = Object();

/// Characters as the Gateway counts them: Unicode scalars after trimming.
int potTextLength(String value) => value.trim().runes.length;

/// Everything the four steps edit, kept whole while the user moves
/// between steps. Step 7 (pot settings, E24) edits the same draft and
/// saves each section on its own ([profile], [work], [permissions],
/// [models], [autonomy]).
@immutable
class PotDraft {
  const PotDraft({
    this.name = '',
    this.avatarColor = 1,
    this.avatarImage,
    this.avatarBytes,
    this.personality = '',
    this.template = PersonalityTemplate.custom,
    this.intro = '',
    this.description = '',
    this.responsibilities = const [],
    this.reach = 'answer',
    this.observe = const [],
    this.dm = const DmRules(),
    this.workLocations = const [],
    this.maxConcurrentWorks = 2,
    this.moneyOn = true,
    this.moneyMicros = 20000000,
    this.tokensOn = true,
    this.tokens = 2000000,
    this.reviewIntervalS = 172800,
    this.main,
    this.fallbacks = const [],
    this.thinking = 'medium',
    this.thinkingAuto = false,
    this.workModels = const [],
  });

  /// A pot's current settings as a draft; [templates] (the localized
  /// template texts) tell which template its personality is.
  factory PotDraft.fromPot(
    Pot pot, {
    Map<PersonalityTemplate, String> templates = const {},
  }) {
    final p = pot.permissions;
    final personality = pot.profile.personality;
    var template = PersonalityTemplate.custom;
    for (final entry in templates.entries) {
      if (entry.value == personality) template = entry.key;
    }
    return PotDraft(
      name: pot.profile.name,
      avatarColor: pot.profile.avatarColor,
      avatarImage: pot.profile.avatarImage,
      personality: personality,
      template: template,
      intro: pot.work.intro,
      description: pot.work.description,
      responsibilities: pot.work.responsibilities,
      reach: p.reach,
      observe: p.observe,
      dm: p.dm,
      workLocations: p.workLocations,
      maxConcurrentWorks: p.maxConcurrentWorks,
      moneyOn: p.budgetMoneyMonthMicros != null,
      moneyMicros: p.budgetMoneyMonthMicros ?? 20000000,
      tokensOn: p.budgetTokensDay != null,
      tokens: p.budgetTokensDay ?? 2000000,
      reviewIntervalS: pot.autonomy.intervalS,
      main: pot.models.main,
      fallbacks: pot.models.fallbacks,
      thinking: pot.models.thinking,
      thinkingAuto: pot.models.thinkingAuto,
      workModels: pot.models.workModels,
    );
  }

  final String name;

  /// 1–5.
  final int avatarColor;

  /// The uploaded picture's image ID; the colour stays the fallback.
  final String? avatarImage;

  /// The picked picture (512 × 512 PNG) for the preview; never sent.
  final Uint8List? avatarBytes;
  final String personality;

  /// The last template chip chosen; picks the speech preview line.
  final PersonalityTemplate template;

  final String intro;
  final String description;
  final List<PotResponsibility> responsibilities;

  /// `answer`, `observe` or `work`.
  final String reach;

  /// Kept when reach changes, sent only when reach is not `answer`.
  final List<ObserveScope> observe;
  final DmRules dm;

  /// Kept when reach changes, sent only when reach is `work`.
  final List<WorkLocation> workLocations;
  final int maxConcurrentWorks;
  final bool moneyOn;

  /// Money per month in micro-dollars (0 while the field is not a
  /// positive amount).
  final int moneyMicros;
  final bool tokensOn;

  /// Tokens per day (0 while the field is not a positive number).
  final int tokens;

  /// Seconds between autonomy reviews; null turns them off.
  final int? reviewIntervalS;

  /// Null until the model list arrives (then the Gateway's default).
  final PotModelChoice? main;
  final List<PotModelChoice> fallbacks;
  final String thinking;
  final bool thinkingAuto;

  /// Kept when reach changes, sent only when reach is `work`.
  final List<PotWorkModel> workModels;

  PotDraft copyWith({
    String? name,
    int? avatarColor,
    Object? avatarImage = _keep,
    Object? avatarBytes = _keep,
    String? personality,
    PersonalityTemplate? template,
    String? intro,
    String? description,
    List<PotResponsibility>? responsibilities,
    String? reach,
    List<ObserveScope>? observe,
    DmRules? dm,
    List<WorkLocation>? workLocations,
    int? maxConcurrentWorks,
    bool? moneyOn,
    int? moneyMicros,
    bool? tokensOn,
    int? tokens,
    Object? reviewIntervalS = _keep,
    Object? main = _keep,
    List<PotModelChoice>? fallbacks,
    String? thinking,
    bool? thinkingAuto,
    List<PotWorkModel>? workModels,
  }) => PotDraft(
    name: name ?? this.name,
    avatarColor: avatarColor ?? this.avatarColor,
    avatarImage: identical(avatarImage, _keep)
        ? this.avatarImage
        : avatarImage as String?,
    avatarBytes: identical(avatarBytes, _keep)
        ? this.avatarBytes
        : avatarBytes as Uint8List?,
    personality: personality ?? this.personality,
    template: template ?? this.template,
    intro: intro ?? this.intro,
    description: description ?? this.description,
    responsibilities: responsibilities ?? this.responsibilities,
    reach: reach ?? this.reach,
    observe: observe ?? this.observe,
    dm: dm ?? this.dm,
    workLocations: workLocations ?? this.workLocations,
    maxConcurrentWorks: maxConcurrentWorks ?? this.maxConcurrentWorks,
    moneyOn: moneyOn ?? this.moneyOn,
    moneyMicros: moneyMicros ?? this.moneyMicros,
    tokensOn: tokensOn ?? this.tokensOn,
    tokens: tokens ?? this.tokens,
    reviewIntervalS: identical(reviewIntervalS, _keep)
        ? this.reviewIntervalS
        : reviewIntervalS as int?,
    main: identical(main, _keep) ? this.main : main as PotModelChoice?,
    fallbacks: fallbacks ?? this.fallbacks,
    thinking: thinking ?? this.thinking,
    thinkingAuto: thinkingAuto ?? this.thinkingAuto,
    workModels: workModels ?? this.workModels,
  );

  /// The main model set to [model], its thinking level fitted to the
  /// levels [model] accepts.
  PotDraft withMain(ModelInfo model) => copyWith(
    main: PotModelChoice(provider: model.provider, model: model.id),
    thinking: fitThinking(thinking, model.thinkingLevels),
  );

  /// The main model from [catalog] when none is chosen yet: the Gateway's
  /// default model, else the first one. Thinking stays Medium (or the
  /// nearest lower level the model accepts).
  PotDraft withDefaultModel(ModelCatalog catalog) {
    if (main != null || catalog.models.isEmpty) return this;
    final preferred = catalog.defaultModel;
    final model =
        (preferred == null
            ? null
            : currentModel(catalog.models, preferred.provider, preferred.id)) ??
        catalog.models.first;
    return withMain(model);
  }

  bool get mayWork => reach == 'work';

  PotProfile get profile => PotProfile(
    name: name.trim(),
    avatarColor: avatarColor,
    personality: personality.trim(),
    avatarImage: avatarImage,
  );

  PotWorkSection get work => PotWorkSection(
    intro: intro.trim(),
    description: description.trim(),
    responsibilities: [
      for (final r in responsibilities)
        PotResponsibility(title: r.title.trim(), detail: r.detail.trim()),
    ],
  );

  /// What the Gateway accepts for this reach: no observe scopes while it
  /// only answers, no work locations unless it may start work.
  PotPermissions get permissions => PotPermissions(
    reach: reach,
    observe: reach == 'answer' ? const [] : observe,
    dm: DmRules(
      send: dm.send,
      receive: dm.receive,
      sendTo: dm.send == 'selected' ? dm.sendTo : const [],
      receiveFrom: dm.receive == 'selected' ? dm.receiveFrom : const [],
    ),
    workLocations: mayWork ? workLocations : const [],
    maxConcurrentWorks: maxConcurrentWorks,
    // A limit left unusable while the step hides it (reach changed) is
    // sent as the default; while shown, [issues] stops the step.
    budgetMoneyMonthMicros: moneyOn
        ? (moneyMicros > 0 ? moneyMicros : 20000000)
        : null,
    budgetTokensDay: tokensOn ? (tokens > 0 ? tokens : 2000000) : null,
  );

  /// Work models only when it may start work.
  PotModels get models => PotModels(
    main: main ?? const PotModelChoice(provider: '', model: ''),
    fallbacks: fallbacks,
    thinking: thinking,
    thinkingAuto: thinkingAuto,
    workModels: mayWork ? workModels : const [],
  );

  PotAutonomy get autonomy => PotAutonomy(intervalS: reviewIntervalS);

  PotInput toInput() => PotInput(
    profile: profile,
    work: work,
    permissions: permissions,
    models: models,
    autonomy: autonomy,
  );

  /// What [step] sends to the Gateway, to compare two drafts section by
  /// section. Step ③ holds the permissions and the review interval.
  Object? sectionJson(int step) => switch (step) {
    PotStep.look => profile.toJson(),
    PotStep.work => work.toJson(),
    PotStep.reach => [_permissionsJson(), autonomy.toJson()],
    _ => models.toJson(),
  };

  Object? _permissionsJson() {
    try {
      return permissions.toJson();
    } on ArgumentError {
      return null;
    }
  }

  /// Whether [step] sends the same as in [other].
  bool sameSection(int step, PotDraft other) =>
      _equalJson(sectionJson(step), other.sectionJson(step));

  /// This draft with [step]'s fields taken from [other] (a pot read again
  /// keeps the user's unsaved edit of that section).
  PotDraft withSectionFrom(int step, PotDraft other) => switch (step) {
    PotStep.look => copyWith(
      name: other.name,
      avatarColor: other.avatarColor,
      avatarImage: other.avatarImage,
      avatarBytes: other.avatarBytes,
      personality: other.personality,
      template: other.template,
    ),
    PotStep.work => copyWith(
      intro: other.intro,
      description: other.description,
      responsibilities: other.responsibilities,
    ),
    PotStep.reach => copyWith(
      reach: other.reach,
      observe: other.observe,
      dm: other.dm,
      workLocations: other.workLocations,
      maxConcurrentWorks: other.maxConcurrentWorks,
      moneyOn: other.moneyOn,
      moneyMicros: other.moneyMicros,
      tokensOn: other.tokensOn,
      tokens: other.tokens,
      reviewIntervalS: other.reviewIntervalS,
    ),
    _ => copyWith(
      main: other.main,
      fallbacks: other.fallbacks,
      thinking: other.thinking,
      thinkingAuto: other.thinkingAuto,
      workModels: other.workModels,
    ),
  };

  /// What keeps [step] from going on.
  Set<PotIssue> issues(int step) => switch (step) {
    PotStep.look => {
      if (potTextLength(name) == 0) PotIssue.nameMissing,
      if (potTextLength(name) > 40) PotIssue.nameTooLong,
      if (potTextLength(personality) > 8000) PotIssue.personalityTooLong,
    },
    PotStep.work => {
      if (potTextLength(intro) > 200) PotIssue.introTooLong,
      if (potTextLength(description) > 8000) PotIssue.descriptionTooLong,
    },
    PotStep.reach => {
      if (mayWork && moneyOn && moneyMicros <= 0) PotIssue.moneyInvalid,
      if (mayWork && tokensOn && tokens <= 0) PotIssue.tokensInvalid,
    },
    PotStep.models => {if (main == null) PotIssue.noModel},
    _ => const {},
  };
}

bool _equalJson(Object? a, Object? b) {
  if (a is Map && b is Map) {
    return a.length == b.length &&
        a.keys.every((key) => b.containsKey(key) && _equalJson(a[key], b[key]));
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_equalJson(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}

/// [current] fitted to [levels]: kept when the model accepts it, else the
/// nearest lower level it accepts, else its lowest level. Off (or a model
/// without thinking, which gets `off`) starts again from Medium.
String fitThinking(String current, List<String> levels) =>
    fitThinkingToLevels(current, levels);

/// The thinking levels [model] accepts, lowest first.
List<String> thinkingLevelsOf(ModelInfo? model) => thinkingLevelsFor(model);

/// The step a refused create or save concerns. The Gateway's 400s carry
/// only a code and a message, so this reads them; null when it cannot
/// tell (the current step shows it).
int? potErrorStep(ApiError error) {
  if (error.code == 'unknown_model') return PotStep.models;
  if (error.status != 400 && error.status != 404) return null;
  final message = error.message.toLowerCase();
  bool starts(String text) => message.startsWith(text);
  bool has(String text) => message.contains(text);
  if (starts('name ') ||
      has('avatarcolor') ||
      starts('personality') ||
      has('picture')) {
    return PotStep.look;
  }
  if (starts('intro') || starts('description') || has('responsibilit')) {
    return PotStep.work;
  }
  if (has('thinking') || has('model')) return PotStep.models;
  if (has('maxconcurrentworks') ||
      has('limit') ||
      has('work location') ||
      has('observ') ||
      has('scope') ||
      has('peers') ||
      has('session') ||
      has('autonomy') ||
      has('workspace')) {
    return PotStep.reach;
  }
  return null;
}

/// Picks a picture and returns it cropped to a centred square and scaled
/// to 512 × 512 PNG, or null when the user picks nothing. Tests replace
/// it.
final avatarPicturePickerProvider = Provider<Future<Uint8List?> Function()>(
  (ref) => () async {
    final file = await openFile(
      acceptedTypeGroups: const [
        XTypeGroup(
          label: 'images',
          extensions: ['png', 'jpg', 'jpeg', 'webp'],
          mimeTypes: ['image/png', 'image/jpeg', 'image/webp'],
          uniformTypeIdentifiers: [
            'public.png',
            'public.jpeg',
            'org.webmproject.webp',
          ],
        ),
      ],
    );
    if (file == null) return null;
    return squareAvatarPng(await file.readAsBytes());
  },
);

/// [bytes] (any image the engine decodes) cropped to a centred square and
/// scaled to [size] × [size], as PNG.
Future<Uint8List> squareAvatarPng(Uint8List bytes, {int size = 512}) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final image = (await codec.getNextFrame()).image;
  codec.dispose();
  final side = math.min(image.width, image.height).toDouble();
  final source = Rect.fromLTWH(
    (image.width - side) / 2,
    (image.height - side) / 2,
    side,
    side,
  );
  final recorder = ui.PictureRecorder();
  ui.Canvas(recorder).drawImageRect(
    image,
    source,
    Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble()),
    ui.Paint()..filterQuality = ui.FilterQuality.high,
  );
  final picture = recorder.endRecording();
  final square = await picture.toImage(size, size);
  picture.dispose();
  image.dispose();
  final data = await square.toByteData(format: ui.ImageByteFormat.png);
  square.dispose();
  return data!.buffer.asUint8List();
}
