import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'pot_draft.dart';

/// The four sections of a pot (E7–E10), each editing a [PotDraft]: the
/// New pot steps show one at a time, the pot's settings (E24) all on one
/// page.

/// The pot's name in sentences, or "this pot" before it has one.
String potNameOrThis(AppLocalizations l10n, PotDraft draft) =>
    draft.name.trim().isEmpty ? l10n.potThisPot : draft.name.trim();

String templateText(AppLocalizations l10n, PersonalityTemplate template) =>
    switch (template) {
      PersonalityTemplate.rigorous => l10n.potTemplateRigorousText,
      PersonalityTemplate.concise => l10n.potTemplateConciseText,
      PersonalityTemplate.friendly => l10n.potTemplateFriendlyText,
      PersonalityTemplate.custom => '',
    };

/// The localized template texts, for [PotDraft.fromPot].
Map<PersonalityTemplate, String> templateTexts(AppLocalizations l10n) => {
  for (final template in PersonalityTemplate.values)
    if (template != PersonalityTemplate.custom)
      template: templateText(l10n, template),
};

String _templateLabel(AppLocalizations l10n, PersonalityTemplate template) =>
    switch (template) {
      PersonalityTemplate.rigorous => l10n.potTemplateRigorous,
      PersonalityTemplate.concise => l10n.potTemplateConcise,
      PersonalityTemplate.friendly => l10n.potTemplateFriendly,
      PersonalityTemplate.custom => l10n.potTemplateCustom,
    };

String _previewLine(AppLocalizations l10n, PersonalityTemplate template) =>
    switch (template) {
      PersonalityTemplate.rigorous => l10n.potPreviewRigorous,
      PersonalityTemplate.concise => l10n.potPreviewConcise,
      PersonalityTemplate.friendly => l10n.potPreviewFriendly,
      PersonalityTemplate.custom => l10n.potPreviewCustom,
    };

String reachLabel(AppLocalizations l10n, String reach) => switch (reach) {
  'observe' => l10n.potReachObserve,
  'work' => l10n.potReachWork,
  _ => l10n.potReachAnswer,
};

const _providerNames = {
  'anthropic': 'Anthropic',
  'openai': 'OpenAI',
  'openai-codex': 'OpenAI Codex',
  'openrouter': 'OpenRouter',
  'deepseek': 'DeepSeek',
  'xai': 'xAI',
  'github-copilot': 'GitHub Copilot',
};

/// "Anthropic": a provider ID as a name.
String providerLabel(String id) =>
    _providerNames[id] ??
    (id.isEmpty ? id : '${id[0].toUpperCase()}${id.substring(1)}');

/// "Anthropic · Claude Sonnet".
String modelLabel(List<ModelInfo> models, String provider, String model) {
  final info = currentModel(models, provider, model);
  return '${providerLabel(provider)} · ${info?.name ?? model}';
}

TextStyle? formFieldStyle(BuildContext context, {double size = 15}) =>
    Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: size);

InputDecoration plainField(BuildContext context, String hint) {
  final colors = PircColorTokens.of(context);
  return InputDecoration.collapsed(
    hintText: hint,
    hintStyle: TextStyle(color: colors['text.faint']),
  );
}

/// `e-in`: a one-line field row (52 high) with an optional 72 label.
class FormInputRow extends StatelessWidget {
  const FormInputRow({super.key, this.label, required this.field, this.suffix});

  final String? label;
  final Widget field;
  final String? suffix;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final muted = TextStyle(fontSize: 14, color: colors['text.muted']);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          spacing: 12,
          children: [
            if (label != null)
              SizedBox(width: 72, child: Text(label!, style: muted)),
            Expanded(child: field),
            if (suffix != null) Text(suffix!, style: muted),
          ],
        ),
      ),
    );
  }
}

/// `e-ta`: a multi-line field, at least 96 high.
class _TextArea extends StatelessWidget {
  const _TextArea({
    required this.fieldKey,
    required this.controller,
    required this.hint,
    required this.onChanged,
  });

  final Key fieldKey;
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 96),
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: TextField(
        key: fieldKey,
        controller: controller,
        onChanged: onChanged,
        minLines: 2,
        maxLines: null,
        keyboardType: TextInputType.multiline,
        style: formFieldStyle(context)?.copyWith(height: 23 / 15),
        decoration: plainField(context, hint),
      ),
    ),
  );
}

/// "＋ Add …" in a group (`accent.pressed`).
class _AddRow extends StatelessWidget {
  const _AddRow({required this.label, required this.onTap, super.key});
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = PircColorTokens.of(context)['accent.pressed'];
    return GroupedRow(
      onTap: onTap,
      enabled: onTap != null,
      titleWidget: Row(
        spacing: 6,
        children: [
          Icon(LucideIcons.plus, size: 18, color: color),
          Flexible(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

Widget _chevron(BuildContext context) => Icon(
  LucideIcons.chevronRight,
  size: 16,
  color: PircColorTokens.of(context)['text.faint'],
);

/// Keeps [controller] equal to [value] when the draft changes elsewhere.
void _sync(TextEditingController controller, String value) {
  if (controller.text != value) controller.text = value;
}

String _issueText(AppLocalizations l10n, PotIssue issue) => switch (issue) {
  PotIssue.nameMissing => l10n.potNameMissing,
  PotIssue.nameTooLong => l10n.potTooLong(40),
  PotIssue.personalityTooLong => l10n.potTooLong(8000),
  PotIssue.introTooLong => l10n.potTooLong(200),
  PotIssue.descriptionTooLong => l10n.potTooLong(8000),
  PotIssue.moneyInvalid || PotIssue.tokensInvalid => l10n.potBudgetInvalid,
  PotIssue.noModel => l10n.potNoModels,
};

List<Widget> _errors(
  AppLocalizations l10n,
  Set<PotIssue> issues,
  List<PotIssue> these,
) => [
  for (final issue in these)
    if (issues.contains(issue))
      GroupNote(
        _issueText(l10n, issue),
        error: true,
        key: ValueKey('issue-${issue.name}'),
      ),
];

Future<T?> _sheet<T>(BuildContext context, WidgetBuilder builder) =>
    showModalBottomSheet<T>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.8,
          ),
          child: builder(context),
        ),
      ),
    );

class _SheetTitle extends StatelessWidget {
  const _SheetTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
    child: Text(text, style: Theme.of(context).textTheme.titleLarge),
  );
}

// ① Look and personality (E7).

/// Step ①: the avatar (five colours or an uploaded picture), the name and
/// the personality with its templates and speech preview.
class PotLookForm extends ConsumerStatefulWidget {
  const PotLookForm({
    super.key,
    required this.draft,
    required this.onChanged,
    this.issues = const {},
  });

  final PotDraft draft;
  final ValueChanged<PotDraft> onChanged;
  final Set<PotIssue> issues;

  @override
  ConsumerState<PotLookForm> createState() => _PotLookFormState();
}

class _PotLookFormState extends ConsumerState<PotLookForm> {
  late final _name = TextEditingController(text: widget.draft.name);
  late final _personality = TextEditingController(
    text: widget.draft.personality,
  );
  PotDraft get _draft => widget.draft;

  @override
  void didUpdateWidget(PotLookForm old) {
    super.didUpdateWidget(old);
    _sync(_name, widget.draft.name);
    _sync(_personality, widget.draft.personality);
  }

  @override
  void dispose() {
    _name.dispose();
    _personality.dispose();
    super.dispose();
  }

  void _template(PersonalityTemplate template) {
    final text = templateText(AppLocalizations.of(context), template);
    _personality.text = text;
    widget.onChanged(_draft.copyWith(template: template, personality: text));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final picture = avatarPicture(ref, _draft.avatarImage, _draft.avatarBytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 8),
          child: Center(
            child: Avatar(
              name: _draft.name,
              color: _draft.avatarColor,
              size: AvatarSize.lg,
              image: picture,
            ),
          ),
        ),
        AvatarPicker(
          color: _draft.avatarColor,
          image: _draft.avatarImage,
          bytes: _draft.avatarBytes,
          note: l10n.potAvatarNote,
          onColor: (color) =>
              widget.onChanged(_draft.copyWith(avatarColor: color)),
          onPicture: (id, bytes) => widget.onChanged(
            _draft.copyWith(avatarImage: id, avatarBytes: bytes),
          ),
        ),
        GroupLabel(l10n.potGroupBasic),
        GroupedList(
          children: [
            FormInputRow(
              label: l10n.potName,
              field: TextField(
                key: const ValueKey('pot-name'),
                controller: _name,
                onChanged: (value) =>
                    widget.onChanged(_draft.copyWith(name: value)),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, l10n.potNameHint),
                textInputAction: TextInputAction.next,
              ),
            ),
          ],
        ),
        ..._errors(l10n, widget.issues, const [
          PotIssue.nameMissing,
          PotIssue.nameTooLong,
        ]),
        GroupLabel(l10n.potGroupPersonality),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final template in PersonalityTemplate.values)
                PillChip(
                  key: ValueKey('template-${template.name}'),
                  label: _templateLabel(l10n, template),
                  selected: _draft.template == template,
                  onTap: () => _template(template),
                ),
            ],
          ),
        ),
        GroupedList(
          children: [
            _TextArea(
              fieldKey: const ValueKey('pot-personality'),
              controller: _personality,
              hint: l10n.potPersonalityHint,
              onChanged: (value) =>
                  widget.onChanged(_draft.copyWith(personality: value)),
            ),
          ],
        ),
        ..._errors(l10n, widget.issues, const [PotIssue.personalityTooLong]),
        GroupNote(l10n.potPersonalityNote),
        GroupLabel(l10n.potGroupPreview),
        _Preview(
          avatar: Avatar(
            name: _draft.name,
            color: _draft.avatarColor,
            size: AvatarSize.sm,
            image: picture,
          ),
          text: _previewLine(l10n, _draft.template),
          note: l10n.potPreviewNote,
        ),
      ],
    );
  }
}

/// The picture to show for an avatar being edited: the picked [bytes]
/// (not shown by the Gateway yet), else the uploaded [image].
ImageProvider? avatarPicture(WidgetRef ref, String? image, Uint8List? bytes) =>
    bytes != null ? MemoryImage(bytes) : watchAvatarImage(ref, image);

/// `e-swatches` and its note: [leading] swatches (a group's "members'
/// faces"), the five colours and the upload swatch, which picks a
/// picture, crops it to 512 × 512 and uploads it (`POST /api/images`), or
/// offers to remove the one there is. The note line shows [note], the
/// upload's progress or its error. New pot, a pot's settings, New group
/// and a group's info use it.
class AvatarPicker extends ConsumerStatefulWidget {
  const AvatarPicker({
    super.key,
    required this.color,
    required this.image,
    required this.bytes,
    required this.note,
    required this.onColor,
    required this.onPicture,
    this.leading = const [],
  });

  /// The chosen colour, or null for none.
  final int? color;

  /// The uploaded picture's ID.
  final String? image;

  /// The picked picture's bytes (shown at once).
  final Uint8List? bytes;
  final String note;
  final ValueChanged<int> onColor;

  /// The uploaded picture's ID and bytes, or nulls when it is removed.
  final void Function(String? id, Uint8List? bytes) onPicture;
  final List<Widget> leading;

  @override
  ConsumerState<AvatarPicker> createState() => _AvatarPickerState();
}

class _AvatarPickerState extends ConsumerState<AvatarPicker> {
  bool _uploading = false;
  String? _uploadError;

  Future<void> _pickPicture() async {
    final l10n = AppLocalizations.of(context);
    if (widget.image != null) {
      final remove = await _sheet<bool>(
        context,
        (context) => ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              leading: const Icon(LucideIcons.image),
              title: Text(l10n.potAvatarChoose),
              onTap: () => Navigator.pop(context, false),
            ),
            ListTile(
              leading: const Icon(LucideIcons.trash2),
              title: Text(l10n.potAvatarRemove),
              onTap: () => Navigator.pop(context, true),
            ),
          ],
        ),
      );
      if (remove == null || !mounted) return;
      if (remove) {
        widget.onPicture(null, null);
        return;
      }
    }
    final Uint8List? bytes;
    try {
      bytes = await ref.read(avatarPicturePickerProvider)();
    } on Object catch (error) {
      if (mounted) setState(() => _uploadError = '$error');
      return;
    }
    final api = ref.read(apiProvider);
    if (bytes == null || api == null || !mounted) return;
    setState(() {
      _uploading = true;
      _uploadError = null;
    });
    try {
      final id = await ImagesApi(api).upload(bytes, contentType: 'image/png');
      if (!mounted) return;
      widget.onPicture(id, bytes);
      setState(() => _uploading = false);
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _uploading = false;
          _uploadError = error.message;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final picture = avatarPicture(ref, widget.image, widget.bytes);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          label: l10n.potAvatarColors,
          container: true,
          child: Padding(
            padding: const EdgeInsets.only(top: 12, bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              spacing: 10,
              children: [
                ...widget.leading,
                for (var color = 1; color <= 5; color++)
                  AvatarSwatch(
                    key: ValueKey('swatch-$color'),
                    color: colors[avatarColorToken(color)],
                    selected: widget.color == color,
                    label: l10n.potAvatarColor(color),
                    onTap: () => widget.onColor(color),
                  ),
                _UploadSwatch(
                  picture: picture,
                  uploading: _uploading,
                  label: l10n.potAvatarUpload,
                  onTap: _uploading ? null : _pickPicture,
                ),
              ],
            ),
          ),
        ),
        GroupNote(
          _uploading ? l10n.potAvatarUploading : _uploadError ?? widget.note,
          error: _uploadError != null && !_uploading,
          textAlign: TextAlign.center,
          padding: const EdgeInsets.fromLTRB(32, 4, 32, 0),
        ),
      ],
    );
  }
}

/// `e-sw`: a 32 colour circle; the chosen one has a 2 gap and a 2 ink
/// ring.
class AvatarSwatch extends StatelessWidget {
  const AvatarSwatch({
    super.key,
    required this.color,
    required this.selected,
    required this.label,
    required this.onTap,
    this.image,
    this.child,
  });

  final Color color;
  final bool selected;
  final String label;
  final VoidCallback? onTap;
  final ImageProvider? image;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 32,
          height: 32,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            image: image == null
                ? null
                : DecorationImage(image: image!, fit: BoxFit.cover),
            boxShadow: selected
                ? [
                    BoxShadow(color: colors['text.primary'], spreadRadius: 4),
                    BoxShadow(
                      color: colors['surface.grouped'],
                      spreadRadius: 2,
                    ),
                  ]
                : null,
          ),
          child: child,
        ),
      ),
    );
  }
}

class _UploadSwatch extends StatelessWidget {
  const _UploadSwatch({
    required this.picture,
    required this.uploading,
    required this.label,
    required this.onTap,
  });

  final ImageProvider? picture;
  final bool uploading;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return AvatarSwatch(
      key: const ValueKey('swatch-upload'),
      color: colors['surface.layer'],
      selected: picture != null,
      label: label,
      image: picture,
      onTap: onTap,
      child: uploading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : picture == null
          ? Icon(LucideIcons.image, size: 16, color: colors['text.secondary'])
          : null,
    );
  }
}

/// `e-preview`: the pot's avatar and one sample bubble.
class _Preview extends StatelessWidget {
  const _Preview({
    required this.avatar,
    required this.text,
    required this.note,
  });

  final Widget avatar;
  final String text;
  final String note;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final style = Theme.of(context).textTheme.bodyMedium;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors['surface.layer'],
        borderRadius: BorderRadius.circular(PircRadius.lg),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        spacing: 8,
        children: [
          avatar,
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 9),
              decoration: BoxDecoration(
                color: colors['surface.subtle'],
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomRight: Radius.circular(18),
                  bottomLeft: Radius.circular(6),
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(text, style: style),
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      note,
                      style: Theme.of(context).textTheme.labelSmall,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ② Work (E8).

/// Step ②: the intro, the work description and the responsibilities
/// (add, edit, reorder, remove).
class PotWorkForm extends StatefulWidget {
  const PotWorkForm({
    super.key,
    required this.draft,
    required this.onChanged,
    this.issues = const {},
  });

  final PotDraft draft;
  final ValueChanged<PotDraft> onChanged;
  final Set<PotIssue> issues;

  @override
  State<PotWorkForm> createState() => _PotWorkFormState();
}

class _PotWorkFormState extends State<PotWorkForm> {
  late final _intro = TextEditingController(text: widget.draft.intro);
  late final _description = TextEditingController(
    text: widget.draft.description,
  );

  @override
  void didUpdateWidget(PotWorkForm old) {
    super.didUpdateWidget(old);
    _sync(_intro, widget.draft.intro);
    _sync(_description, widget.draft.description);
  }

  @override
  void dispose() {
    _intro.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _edit(int? index) async {
    final list = widget.draft.responsibilities;
    final result = await _sheet<_ResponsibilityAction>(
      context,
      (context) => _ResponsibilitySheet(
        initial: index == null ? null : list[index],
        canMoveUp: index != null && index > 0,
        canMoveDown: index != null && index < list.length - 1,
      ),
    );
    if (result == null || !mounted) return;
    final next = [...widget.draft.responsibilities];
    switch (result) {
      case _Save(:final responsibility):
        if (index == null) {
          next.add(responsibility);
        } else {
          next[index] = responsibility;
        }
      case _Remove():
        next.removeAt(index!);
      case _Move(:final by):
        final item = next.removeAt(index!);
        next.insert(index + by, item);
    }
    widget.onChanged(widget.draft.copyWith(responsibilities: next));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final draft = widget.draft;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupLabel(l10n.potGroupIntro),
        GroupedList(
          children: [
            FormInputRow(
              field: TextField(
                key: const ValueKey('pot-intro'),
                controller: _intro,
                onChanged: (value) =>
                    widget.onChanged(widget.draft.copyWith(intro: value)),
                minLines: 1,
                maxLines: 3,
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, l10n.potIntroHint),
              ),
            ),
          ],
        ),
        ..._errors(l10n, widget.issues, const [PotIssue.introTooLong]),
        GroupNote(l10n.potIntroNote),
        GroupLabel(l10n.potGroupDescription),
        GroupedList(
          children: [
            _TextArea(
              fieldKey: const ValueKey('pot-description'),
              controller: _description,
              hint: l10n.potDescriptionHint,
              onChanged: (value) =>
                  widget.onChanged(widget.draft.copyWith(description: value)),
            ),
          ],
        ),
        ..._errors(l10n, widget.issues, const [PotIssue.descriptionTooLong]),
        GroupNote(l10n.potDescriptionNote),
        GroupLabel(l10n.potGroupResponsibilities),
        GroupedList(
          children: [
            for (final (i, item) in draft.responsibilities.indexed)
              GroupedRow(
                key: ValueKey('responsibility-$i'),
                title: item.title,
                subtitle: item.detail,
                onTap: () => _edit(i),
              ),
            _AddRow(
              key: const ValueKey('add-responsibility'),
              label: l10n.potAddResponsibility,
              onTap: () => _edit(null),
            ),
          ],
        ),
      ],
    );
  }
}

sealed class _ResponsibilityAction {
  const _ResponsibilityAction();
}

class _Save extends _ResponsibilityAction {
  const _Save(this.responsibility);
  final PotResponsibility responsibility;
}

class _Remove extends _ResponsibilityAction {
  const _Remove();
}

class _Move extends _ResponsibilityAction {
  const _Move(this.by);
  final int by;
}

class _ResponsibilitySheet extends StatefulWidget {
  const _ResponsibilitySheet({
    required this.initial,
    required this.canMoveUp,
    required this.canMoveDown,
  });

  final PotResponsibility? initial;
  final bool canMoveUp;
  final bool canMoveDown;

  @override
  State<_ResponsibilitySheet> createState() => _ResponsibilitySheetState();
}

class _ResponsibilitySheetState extends State<_ResponsibilitySheet> {
  late final _title = TextEditingController(text: widget.initial?.title);
  late final _detail = TextEditingController(text: widget.initial?.detail);

  @override
  void dispose() {
    _title.dispose();
    _detail.dispose();
    super.dispose();
  }

  InputDecoration _decoration(String hint) {
    final colors = PircColorTokens.of(context);
    return InputDecoration(
      hintText: hint,
      filled: true,
      fillColor: colors['fill.hover'],
      counterText: '',
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(PircRadius.md),
        borderSide: BorderSide.none,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final title = potTextLength(_title.text);
    final valid =
        title >= 1 && title <= 200 && potTextLength(_detail.text) <= 2000;
    final editing = widget.initial != null;
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.only(bottom: 16),
        children: [
          _SheetTitle(
            editing ? l10n.potResponsibilityEdit : l10n.potResponsibilityNew,
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              key: const ValueKey('responsibility-title'),
              controller: _title,
              autofocus: !editing,
              maxLength: 200,
              onChanged: (_) => setState(() {}),
              decoration: _decoration(l10n.potResponsibilityTitle),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: TextField(
              key: const ValueKey('responsibility-detail'),
              controller: _detail,
              maxLength: 2000,
              minLines: 1,
              maxLines: 4,
              onChanged: (_) => setState(() {}),
              decoration: _decoration(l10n.potResponsibilityDetail),
            ),
          ),
          if (editing)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    style: ghostButtonStyle(context),
                    onPressed: widget.canMoveUp
                        ? () => Navigator.pop(context, const _Move(-1))
                        : null,
                    child: Text(l10n.potMoveUp),
                  ),
                  OutlinedButton(
                    style: ghostButtonStyle(context),
                    onPressed: widget.canMoveDown
                        ? () => Navigator.pop(context, const _Move(1))
                        : null,
                    child: Text(l10n.potMoveDown),
                  ),
                  OutlinedButton(
                    style: ghostButtonStyle(context),
                    onPressed: () => Navigator.pop(context, const _Remove()),
                    child: Text(l10n.potRemove),
                  ),
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: FilledButton(
              key: const ValueKey('responsibility-save'),
              style: inkButtonStyle(context),
              onPressed: valid
                  ? () => Navigator.pop(
                      context,
                      _Save(
                        PotResponsibility(
                          title: _title.text.trim(),
                          detail: _detail.text.trim(),
                        ),
                      ),
                    )
                  : null,
              child: Text(l10n.save),
            ),
          ),
        ],
      ),
    );
  }
}

// ③ What it can do (E9).

/// Step ③: reach; what it observes (not while it only answers); pot DMs;
/// when it may start work, where, how many at once and its budget; and
/// how often it reviews itself.
class PotReachForm extends ConsumerStatefulWidget {
  const PotReachForm({
    super.key,
    required this.draft,
    required this.onChanged,
    this.issues = const {},
    this.potId,
  });

  final PotDraft draft;
  final ValueChanged<PotDraft> onChanged;
  final Set<PotIssue> issues;

  /// The pot being edited (left out of the DM pickers); null when new.
  final String? potId;

  @override
  ConsumerState<PotReachForm> createState() => _PotReachFormState();
}

String _dollars(int micros) {
  if (micros <= 0) return '';
  if (micros % 1000000 == 0) return '${micros ~/ 1000000}';
  var text = (micros / 1000000).toStringAsFixed(2);
  while (text.endsWith('0')) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

int _micros(String text) {
  final value = double.tryParse(text.trim());
  if (value == null || !value.isFinite || value <= 0) return 0;
  return (value * 1000000).round();
}

int _tokens(String text) {
  final value = int.tryParse(text.trim().replaceAll(',', ''));
  return value == null || value <= 0 ? 0 : value;
}

class _PotReachFormState extends ConsumerState<PotReachForm> {
  late final _money = TextEditingController(
    text: _dollars(widget.draft.moneyMicros),
  );
  late final _tokenField = TextEditingController(
    text: widget.draft.tokens > 0 ? '${widget.draft.tokens}' : '',
  );

  PotDraft get _draft => widget.draft;
  void _set(PotDraft draft) => widget.onChanged(draft);

  @override
  void didUpdateWidget(PotReachForm old) {
    super.didUpdateWidget(old);
    if (_micros(_money.text) != widget.draft.moneyMicros) {
      _money.text = _dollars(widget.draft.moneyMicros);
    }
    if (_tokens(_tokenField.text) != widget.draft.tokens) {
      _tokenField.text = widget.draft.tokens > 0
          ? '${widget.draft.tokens}'
          : '';
    }
  }

  @override
  void dispose() {
    _money.dispose();
    _tokenField.dispose();
    super.dispose();
  }

  bool _observes(String kind) => _draft.observe.any((s) => s.kind == kind);

  void _toggleGlobal(String kind, bool on) => _set(
    _draft.copyWith(
      observe: on
          ? [..._draft.observe, ObserveScope(kind: kind)]
          : [
              for (final scope in _draft.observe)
                if (scope.kind != kind) scope,
            ],
    ),
  );

  void _removeScope(ObserveScope removed) => _set(
    _draft.copyWith(
      observe: [
        for (final scope in _draft.observe)
          if (!(scope.kind == removed.kind && scope.ref == removed.ref)) scope,
      ],
    ),
  );

  Future<void> _addScope() async {
    final l10n = AppLocalizations.of(context);
    final workspaces =
        ref.read(workspacesProvider).value ?? const <WorkspaceInfo>[];
    final sessions = ref.read(sessionsProvider).value ?? const <Session>[];
    bool chosen(String kind, String id) =>
        _draft.observe.any((s) => s.kind == kind && s.ref == id);
    final options = <(String, List<(ObserveScope, String, String)>)>[
      (
        l10n.potObserveWorkspaces,
        [
          for (final w in workspaces)
            if (w.kind != 'chat' && !chosen('workspace', w.id))
              (
                ObserveScope(kind: 'workspace', ref: w.id),
                w.displayName,
                w.hostId,
              ),
        ],
      ),
      (
        l10n.potObserveProjects,
        [
          for (final w in workspaces)
            if (w.kind == 'chat' && !chosen('project', w.id))
              (
                ObserveScope(kind: 'project', ref: w.id),
                w.displayName,
                w.hostId,
              ),
        ],
      ),
      (
        l10n.potObserveSessions,
        [
          for (final s in sessions)
            if (!chosen('session', s.id))
              (
                ObserveScope(kind: 'session', ref: s.id),
                s.name,
                _workspaceName(workspaces, s.workspaceId),
              ),
        ],
      ),
    ];
    final picked = await _sheet<ObserveScope>(
      context,
      (context) => ListView(
        shrinkWrap: true,
        children: [
          _SheetTitle(l10n.potObserveAdd),
          if (options.every((o) => o.$2.isEmpty))
            ListTile(title: Text(l10n.potObserveNothing)),
          for (final (title, items) in options)
            if (items.isNotEmpty) ...[
              GroupLabel(title),
              for (final (scope, name, sub) in items)
                ListTile(
                  key: ValueKey('observe-${scope.kind}-${scope.ref}'),
                  title: Text(name),
                  subtitle: sub.isEmpty ? null : Text(sub),
                  onTap: () => Navigator.pop(context, scope),
                ),
            ],
        ],
      ),
    );
    if (picked != null && mounted) {
      _set(_draft.copyWith(observe: [..._draft.observe, picked]));
    }
  }

  Future<void> _addLocation() async {
    final l10n = AppLocalizations.of(context);
    final workspaces = [
      for (final w
          in ref.read(workspacesProvider).value ?? const <WorkspaceInfo>[])
        if (!_draft.workLocations.any((l) => l.workspaceId == w.id)) w,
    ];
    final picked = await _sheet<WorkspaceInfo>(
      context,
      (context) => ListView(
        shrinkWrap: true,
        children: [
          _SheetTitle(l10n.potWorkLocationAdd),
          if (workspaces.isEmpty)
            ListTile(title: Text(l10n.potWorkLocationsNone)),
          for (final w in workspaces)
            ListTile(
              key: ValueKey('location-${w.id}'),
              title: Text(w.displayName),
              subtitle: w.hostId.isEmpty ? null : Text(w.hostId),
              onTap: () => Navigator.pop(context, w),
            ),
        ],
      ),
    );
    if (picked != null && mounted) {
      _set(
        _draft.copyWith(
          workLocations: [
            ..._draft.workLocations,
            WorkLocation(workspaceId: picked.id),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final name = potNameOrThis(l10n, _draft);
    final dm = _draft.dm;
    final dmItems = [
      SegmentedItem('all', l10n.potDmAll),
      SegmentedItem('selected', l10n.potDmSelected),
      SegmentedItem('off', l10n.potDmOff),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupLabel(l10n.potGroupReach),
        Semantics(
          label: l10n.potGroupReach,
          container: true,
          child: GroupedList(
            children: [
              for (final (reach, title, detail) in [
                ('answer', l10n.potReachAnswer, l10n.potReachAnswerDetail),
                ('observe', l10n.potReachObserve, l10n.potReachObserveDetail),
                ('work', l10n.potReachWork, l10n.potReachWorkDetail(name)),
              ])
                RadioRow(
                  key: ValueKey('reach-$reach'),
                  title: title,
                  subtitle: detail,
                  selected: _draft.reach == reach,
                  onTap: () => _set(_draft.copyWith(reach: reach)),
                ),
            ],
          ),
        ),
        GroupLabel(l10n.potGroupObserve),
        if (_draft.reach == 'answer')
          GroupNote(l10n.potObserveOff, key: const ValueKey('observe-off'))
        else
          _observeGroup(l10n),
        GroupLabel(l10n.potGroupDmSend),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Segmented<String>(
            key: const ValueKey('dm-send'),
            semanticLabel: l10n.potGroupDmSend,
            strong: true,
            items: dmItems,
            selected: dm.send,
            onSelected: (value) => _set(
              _draft.copyWith(
                dm: DmRules(
                  send: value,
                  receive: dm.receive,
                  sendTo: dm.sendTo,
                  receiveFrom: dm.receiveFrom,
                ),
              ),
            ),
          ),
        ),
        if (dm.send == 'selected')
          _PotPicker(
            keyPrefix: 'dm-send',
            potId: widget.potId,
            selected: dm.sendTo,
            onChanged: (ids) => _set(
              _draft.copyWith(
                dm: DmRules(
                  send: dm.send,
                  receive: dm.receive,
                  sendTo: ids,
                  receiveFrom: dm.receiveFrom,
                ),
              ),
            ),
          ),
        GroupLabel(l10n.potGroupDmReceive),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Segmented<String>(
            key: const ValueKey('dm-receive'),
            semanticLabel: l10n.potGroupDmReceive,
            strong: true,
            items: dmItems,
            selected: dm.receive,
            onSelected: (value) => _set(
              _draft.copyWith(
                dm: DmRules(
                  send: dm.send,
                  receive: value,
                  sendTo: dm.sendTo,
                  receiveFrom: dm.receiveFrom,
                ),
              ),
            ),
          ),
        ),
        if (dm.receive == 'selected')
          _PotPicker(
            keyPrefix: 'dm-receive',
            potId: widget.potId,
            selected: dm.receiveFrom,
            onChanged: (ids) => _set(
              _draft.copyWith(
                dm: DmRules(
                  send: dm.send,
                  receive: dm.receive,
                  sendTo: dm.sendTo,
                  receiveFrom: ids,
                ),
              ),
            ),
          ),
        GroupNote(
          dm.send == 'off' && dm.receive == 'off'
              ? l10n.potDmOffNote(name)
              : l10n.potDmNote(name),
        ),
        if (_draft.mayWork) ..._workSection(l10n, name),
        // Every pot reviews itself, whatever its reach (pots.md, Autonomy).
        ..._reviewSection(l10n),
        GroupNote(
          l10n.potReachNote(name),
          padding: const EdgeInsets.fromLTRB(32, 14, 32, 0),
        ),
      ],
    );
  }

  Widget _observeGroup(AppLocalizations l10n) {
    final workspaces =
        ref.watch(workspacesProvider).value ?? const <WorkspaceInfo>[];
    final sessions = ref.watch(sessionsProvider).value ?? const <Session>[];
    String? host(String id) {
      for (final w in workspaces) {
        if (w.id == id) return w.hostId;
      }
      return null;
    }

    String sessionName(String id) {
      for (final s in sessions) {
        if (s.id == id) return s.name;
      }
      return id;
    }

    return GroupedList(
      children: [
        for (final scope in _draft.observe)
          if (scope.kind == 'workspace' ||
              scope.kind == 'project' ||
              scope.kind == 'session')
            GroupedRow(
              key: ValueKey('scope-${scope.kind}-${scope.ref}'),
              title: scope.kind == 'session'
                  ? sessionName(scope.ref)
                  : _workspaceName(workspaces, scope.ref),
              subtitle: [
                switch (scope.kind) {
                  'project' => l10n.potObserveProject,
                  'session' => l10n.potObserveSession,
                  _ => l10n.potObserveWorkspace,
                },
                if (scope.kind != 'session') ?host(scope.ref),
              ].where((part) => part.isNotEmpty).join(' · '),
              trailing: PircSwitch(
                value: true,
                semanticLabel: scope.ref,
                onChanged: (_) => _removeScope(scope),
              ),
            ),
        for (final (kind, title, detail) in [
          ('calendar', l10n.potObserveCalendar, l10n.potObserveCalendarDetail),
          (
            'schedules',
            l10n.potObserveSchedules,
            l10n.potObserveSchedulesDetail,
          ),
        ])
          GroupedRow(
            key: ValueKey('observe-$kind'),
            title: title,
            subtitle: detail,
            trailing: PircSwitch(
              value: _observes(kind),
              semanticLabel: title,
              onChanged: (on) => _toggleGlobal(kind, on),
            ),
          ),
        _AddRow(
          key: const ValueKey('observe-add'),
          label: l10n.potObserveAdd,
          onTap: _addScope,
        ),
      ],
    );
  }

  List<Widget> _reviewSection(AppLocalizations l10n) => [
    GroupLabel(l10n.potGroupReview),
    Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Segmented<int?>(
        key: const ValueKey('review'),
        semanticLabel: l10n.potGroupReview,
        strong: true,
        items: [
          SegmentedItem(reviewIntervals[0], l10n.potReviewOff),
          SegmentedItem(reviewIntervals[1], l10n.potReviewDay),
          SegmentedItem(reviewIntervals[2], l10n.potReviewTwoDays),
          SegmentedItem(reviewIntervals[3], l10n.potReviewWeek),
        ],
        selected: _draft.reviewIntervalS,
        onSelected: (value) => _set(_draft.copyWith(reviewIntervalS: value)),
      ),
    ),
    GroupNote(l10n.potReviewNote),
  ];

  List<Widget> _workSection(AppLocalizations l10n, String name) {
    final colors = PircColorTokens.of(context);
    final workspaces =
        ref.watch(workspacesProvider).value ?? const <WorkspaceInfo>[];
    String? host(String id) {
      for (final w in workspaces) {
        if (w.id == id) return w.hostId;
      }
      return null;
    }

    final count = _draft.maxConcurrentWorks;
    final moneyLocked = _draft.moneyOn && !_draft.tokensOn;
    final tokensLocked = _draft.tokensOn && !_draft.moneyOn;
    final muted = TextStyle(fontSize: 15, color: colors['text.muted']);
    return [
      GroupLabel(l10n.potGroupWork),
      GroupedList(
        children: [
          for (final (i, location) in _draft.workLocations.indexed)
            GroupedRow(
              key: ValueKey('location-row-${location.workspaceId}'),
              title: _workspaceName(workspaces, location.workspaceId),
              subtitle: host(location.workspaceId),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ModelAccess(
                    key: ValueKey('access-${location.workspaceId}'),
                    label: location.access == 'write'
                        ? l10n.potAccessWrite
                        : l10n.potAccessRead,
                    semanticLabel: l10n.potAccessLabel(
                      location.access == 'write'
                          ? l10n.potAccessWrite
                          : l10n.potAccessRead,
                    ),
                    onTap: () => _set(
                      _draft.copyWith(
                        workLocations: [
                          for (final (j, l) in _draft.workLocations.indexed)
                            j == i
                                ? WorkLocation(
                                    workspaceId: l.workspaceId,
                                    access: l.access == 'write'
                                        ? 'read'
                                        : 'write',
                                  )
                                : l,
                        ],
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: l10n.potRemoveNamed(
                      _workspaceName(workspaces, location.workspaceId),
                    ),
                    icon: Icon(
                      LucideIcons.x,
                      size: 18,
                      color: colors['text.muted'],
                    ),
                    onPressed: () => _set(
                      _draft.copyWith(
                        workLocations: [
                          for (final (j, l) in _draft.workLocations.indexed)
                            if (j != i) l,
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          _AddRow(
            key: const ValueKey('location-add'),
            label: l10n.potWorkLocationAdd,
            onTap: _addLocation,
          ),
          GroupedRow(
            key: const ValueKey('max-works'),
            title: l10n.potMaxWorks,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l10n.potMaxWorksValue(count), style: muted),
                IconButton(
                  key: const ValueKey('max-works-fewer'),
                  tooltip: l10n.potFewer,
                  icon: const Icon(LucideIcons.minus, size: 18),
                  onPressed: count > 0
                      ? () =>
                            _set(_draft.copyWith(maxConcurrentWorks: count - 1))
                      : null,
                ),
                IconButton(
                  key: const ValueKey('max-works-more'),
                  tooltip: l10n.potMore,
                  icon: const Icon(LucideIcons.plus, size: 18),
                  onPressed: count < 16
                      ? () =>
                            _set(_draft.copyWith(maxConcurrentWorks: count + 1))
                      : null,
                ),
              ],
            ),
          ),
        ],
      ),
      GroupNote(l10n.potWorkNote(name)),
      GroupLabel(l10n.potGroupBudget),
      GroupedList(
        children: [
          GroupedRow(
            title: l10n.potBudgetMoney,
            trailing: PircSwitch(
              key: const ValueKey('budget-money-switch'),
              value: _draft.moneyOn,
              semanticLabel: l10n.potBudgetMoney,
              onChanged: moneyLocked
                  ? null
                  : (on) => _set(_draft.copyWith(moneyOn: on)),
            ),
          ),
          if (_draft.moneyOn)
            FormInputRow(
              label: l10n.potBudgetDollars,
              field: TextField(
                key: const ValueKey('budget-money'),
                controller: _money,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                onChanged: (text) =>
                    _set(_draft.copyWith(moneyMicros: _micros(text))),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, '20'),
              ),
            ),
          GroupedRow(
            title: l10n.potBudgetTokens,
            trailing: PircSwitch(
              key: const ValueKey('budget-tokens-switch'),
              value: _draft.tokensOn,
              semanticLabel: l10n.potBudgetTokens,
              onChanged: tokensLocked
                  ? null
                  : (on) => _set(_draft.copyWith(tokensOn: on)),
            ),
          ),
          if (_draft.tokensOn)
            FormInputRow(
              field: TextField(
                key: const ValueKey('budget-tokens'),
                controller: _tokenField,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                onChanged: (text) =>
                    _set(_draft.copyWith(tokens: _tokens(text))),
                style: formFieldStyle(context, size: 15.5),
                decoration: plainField(context, '2000000'),
              ),
              suffix: l10n.potBudgetTokenUnit,
            ),
        ],
      ),
      ..._errors(l10n, widget.issues, const [
        PotIssue.moneyInvalid,
        PotIssue.tokensInvalid,
      ]).take(1),
      GroupNote(l10n.potBudgetNote),
    ];
  }
}

String _workspaceName(List<WorkspaceInfo> workspaces, String id) {
  for (final w in workspaces) {
    if (w.id == id) return w.displayName;
  }
  return id;
}

/// The other pots as chips, for DMs to or from "selected".
class _PotPicker extends ConsumerWidget {
  const _PotPicker({
    required this.keyPrefix,
    required this.potId,
    required this.selected,
    required this.onChanged,
  });

  final String keyPrefix;
  final String? potId;
  final List<String> selected;
  final ValueChanged<List<String>> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final pots = [
      for (final pot in ref.watch(potsProvider).value ?? const <PotSummary>[])
        if (pot.id != potId && pot.state != 'archived') pot,
    ];
    if (pots.isEmpty) {
      return GroupNote(l10n.potDmNoPots);
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final pot in pots)
            PillChip(
              key: ValueKey('$keyPrefix-${pot.id}'),
              label: pot.name,
              selected: selected.contains(pot.id),
              onTap: () => onChanged(
                selected.contains(pot.id)
                    ? [
                        for (final id in selected)
                          if (id != pot.id) id,
                      ]
                    : [...selected, pot.id],
              ),
            ),
        ],
      ),
    );
  }
}

// ④ Models (E10).

/// Step ④: the main model and fallbacks, thinking (the main model's
/// levels) and "adjust by itself"; when it may start work, the models it
/// may open work with, each "direct" or "ask you".
class PotModelsForm extends ConsumerWidget {
  const PotModelsForm({
    super.key,
    required this.draft,
    required this.onChanged,
    this.issues = const {},
  });

  final PotDraft draft;
  final ValueChanged<PotDraft> onChanged;
  final Set<PotIssue> issues;

  Future<void> _pick(
    BuildContext context,
    List<ModelInfo> models, {
    required PotModelChoice? current,
    required ValueChanged<ModelInfo> onPicked,
    VoidCallback? onRemove,
  }) async {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final picked = await _sheet<Object>(
      context,
      (context) => ListView(
        shrinkWrap: true,
        children: [
          _SheetTitle(l10n.potPickModel),
          for (final model in models)
            ListTile(
              key: ValueKey('pick-${model.provider}-${model.id}'),
              title: Text(model.name),
              subtitle: Text(providerLabel(model.provider)),
              trailing:
                  current?.provider == model.provider &&
                      current?.model == model.id
                  ? Icon(LucideIcons.check, color: colors['accent.default'])
                  : null,
              onTap: () => Navigator.pop(context, model),
            ),
          if (onRemove != null)
            ListTile(
              key: const ValueKey('remove-fallback'),
              leading: const Icon(LucideIcons.trash2),
              title: Text(l10n.potRemoveFallback),
              onTap: () => Navigator.pop(context, false),
            ),
        ],
      ),
    );
    if (picked is ModelInfo) onPicked(picked);
    if (picked == false) onRemove?.call();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final name = potNameOrThis(l10n, draft);
    final catalog = ref.watch(modelCatalogProvider);
    final models = catalog.value?.models ?? const <ModelInfo>[];
    final main = draft.main;
    final mainInfo = main == null
        ? null
        : currentModel(models, main.provider, main.model);
    final levels = thinkingLevelsOf(mainInfo);
    final level = thinkingLabel(l10n, draft.thinking);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        GroupLabel(l10n.potGroupOwnModels(name)),
        if (catalog.isLoading && models.isEmpty)
          GroupedList(children: [GroupedRow(title: l10n.potModelsLoading)])
        else
          GroupedList(
            children: [
              GroupedRow(
                key: const ValueKey('main-model'),
                title: l10n.potMainModel,
                subtitle: main == null
                    ? null
                    : modelLabel(models, main.provider, main.model),
                trailing: _chevron(context),
                onTap: models.isEmpty
                    ? null
                    : () => _pick(
                        context,
                        models,
                        current: main,
                        onPicked: (model) => onChanged(draft.withMain(model)),
                      ),
              ),
              for (final (i, fallback) in draft.fallbacks.indexed)
                GroupedRow(
                  key: ValueKey('fallback-$i'),
                  title: l10n.potFallback(i + 1),
                  subtitle: modelLabel(
                    models,
                    fallback.provider,
                    fallback.model,
                  ),
                  trailing: _chevron(context),
                  onTap: () => _pick(
                    context,
                    models,
                    current: fallback,
                    onPicked: (model) => onChanged(
                      draft.copyWith(
                        fallbacks: [
                          for (final (j, f) in draft.fallbacks.indexed)
                            j == i
                                ? PotModelChoice(
                                    provider: model.provider,
                                    model: model.id,
                                  )
                                : f,
                        ],
                      ),
                    ),
                    onRemove: () => onChanged(
                      draft.copyWith(
                        fallbacks: [
                          for (final (j, f) in draft.fallbacks.indexed)
                            if (j != i) f,
                        ],
                      ),
                    ),
                  ),
                ),
              _AddRow(
                key: const ValueKey('add-fallback'),
                label: l10n.potAddFallback,
                onTap: models.isEmpty
                    ? null
                    : () => _pick(
                        context,
                        models,
                        current: null,
                        onPicked: (model) => onChanged(
                          draft.copyWith(
                            fallbacks: [
                              ...draft.fallbacks,
                              PotModelChoice(
                                provider: model.provider,
                                model: model.id,
                              ),
                            ],
                          ),
                        ),
                      ),
              ),
            ],
          ),
        if (!catalog.isLoading && models.isEmpty)
          GroupNote(l10n.potNoModels, error: true)
        else
          ..._errors(l10n, issues, const [PotIssue.noModel]),
        GroupNote(l10n.potModelsNote),
        GroupLabel(l10n.potGroupThinking),
        if (levels.isEmpty)
          GroupedList(
            children: [
              GroupedRow(
                key: const ValueKey('thinking-none'),
                title: l10n.potThinkingNone,
                enabled: false,
              ),
            ],
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Segmented<String>(
              key: const ValueKey('thinking'),
              semanticLabel: l10n.potGroupThinking,
              strong: true,
              items: [
                for (final level in levels)
                  SegmentedItem(level, thinkingLabel(l10n, level)),
              ],
              selected: draft.thinking,
              onSelected: (value) => onChanged(draft.copyWith(thinking: value)),
            ),
          ),
        const SizedBox(height: 10),
        GroupedList(
          children: [
            GroupedRow(
              title: l10n.potThinkingAuto,
              subtitle: l10n.potThinkingAutoDetail,
              wrapSubtitle: true,
              enabled: levels.isNotEmpty,
              trailing: PircSwitch(
                key: const ValueKey('thinking-auto'),
                value: draft.thinkingAuto,
                semanticLabel: l10n.potThinkingAuto,
                onChanged: levels.isEmpty
                    ? null
                    : (on) => onChanged(draft.copyWith(thinkingAuto: on)),
              ),
            ),
          ],
        ),
        if (levels.isNotEmpty)
          GroupNote(
            draft.thinkingAuto
                ? l10n.potThinkingAutoOn(level)
                : l10n.potThinkingAutoOff(level),
          ),
        GroupLabel(l10n.potGroupWorkModels),
        if (draft.mayWork) ...[
          GroupedList(
            children: [
              for (final model in models)
                _WorkModelRow(
                  key: ValueKey('work-model-${model.provider}-${model.id}'),
                  model: model,
                  chosen: _workModel(model),
                  onChanged: (mode) => onChanged(
                    draft.copyWith(
                      workModels: mode == null
                          ? [
                              for (final w in draft.workModels)
                                if (!(w.provider == model.provider &&
                                    w.model == model.id))
                                  w,
                            ]
                          : _workModel(model) == null
                          ? [
                              ...draft.workModels,
                              PotWorkModel(
                                provider: model.provider,
                                model: model.id,
                                mode: mode,
                              ),
                            ]
                          : [
                              for (final w in draft.workModels)
                                w.provider == model.provider &&
                                        w.model == model.id
                                    ? PotWorkModel(
                                        provider: w.provider,
                                        model: w.model,
                                        mode: mode,
                                      )
                                    : w,
                            ],
                    ),
                  ),
                ),
            ],
          ),
          GroupNote(l10n.potWorkModelsNote(name)),
        ] else
          Container(
            key: const ValueKey('work-models-off'),
            margin: const EdgeInsets.symmetric(horizontal: 16),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors['surface.layer'],
              borderRadius: BorderRadius.circular(PircRadius.md),
            ),
            child: Text(
              l10n.potWorkModelsOff(reachLabel(l10n, draft.reach), name),
              style: TextStyle(
                fontSize: 13.5,
                height: 20 / 13.5,
                color: colors['text.secondary'],
              ),
            ),
          ),
      ],
    );
  }

  PotWorkModel? _workModel(ModelInfo model) {
    for (final w in draft.workModels) {
      if (w.provider == model.provider && w.model == model.id) return w;
    }
    return null;
  }
}

/// A model a pot may open work with: the check, "Provider · Name" and,
/// when chosen, its `ModelAccess` (direct / ask you).
class _WorkModelRow extends StatelessWidget {
  const _WorkModelRow({
    super.key,
    required this.model,
    required this.chosen,
    required this.onChanged,
  });

  final ModelInfo model;
  final PotWorkModel? chosen;

  /// `direct`, `ask`, or null to leave it out.
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final chosen = this.chosen;
    final title = '${providerLabel(model.provider)} · ${model.name}';
    final mode = chosen?.mode == 'ask' ? l10n.potModeAsk : l10n.potModeDirect;
    return GroupedRow(
      title: title,
      onTap: () => onChanged(chosen == null ? 'direct' : null),
      leading: Semantics(
        checked: chosen != null,
        label: title,
        excludeSemantics: true,
        child: Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: chosen != null ? colors['action.primary'] : null,
            border: chosen != null
                ? null
                : Border.all(color: colors['line.strong'], width: 1.5),
          ),
          child: chosen != null
              ? Icon(
                  LucideIcons.check,
                  size: 13,
                  color: colors['action.onPrimary'],
                )
              : null,
        ),
      ),
      trailing: chosen == null
          ? null
          : ModelAccess(
              label: mode,
              semanticLabel: l10n.potModeLabel(mode),
              onTap: () => onChanged(chosen.mode == 'ask' ? 'direct' : 'ask'),
            ),
    );
  }
}
