import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'new_pot_screen.dart';
import 'pot_draft.dart';
import 'pot_form.dart';
import 'pot_pause.dart';
import 'thread_data.dart';

/// The `section` names of [potSettingsLocation], by step.
const potSettingsSections = ['look', 'work', 'reach', 'models'];

/// A pot's settings (E24): the four New pot sections on one page, each
/// saved on its own with the pot's revision (step ③ saves the permissions
/// and the review interval together), then Pause or Resume, Hand over…
/// and Archive or delete…. A 409 reads the pot again and keeps the
/// user's unsaved edit; sections the user has not touched follow the pot
/// as it changes.
class PotSettingsScreen extends ConsumerStatefulWidget {
  const PotSettingsScreen({super.key, required this.potId, this.section});

  final String potId;

  /// One of [potSettingsSections] to scroll to.
  final String? section;

  @override
  ConsumerState<PotSettingsScreen> createState() => _PotSettingsScreenState();
}

class _PotSettingsScreenState extends ConsumerState<PotSettingsScreen> {
  /// The pot as last read.
  Pot? _pot;

  /// The revision the unsaved edits are based on. It stays behind [_pot]
  /// when the pot changed under a section the user is editing, so saving
  /// that section is answered 409.
  int _revision = 0;
  PotDraft? _draft;
  Map<PersonalityTemplate, String> _templates = const {};

  /// Sections whose problems are shown (Save was pressed there).
  final _shown = <int>{};
  final _busy = <int>{};
  final _errors = <int, String>{};
  final _conflicts = <int>{};
  final _saved = <int>{};

  /// Edited sections the pot changed under since the edit began; a 409's
  /// reread says so on each of them.
  final _stale = <int>{};
  final _sectionKeys = [for (var i = 0; i < PotStep.count; i++) GlobalKey()];
  bool _scrolled = false;

  PotDraft _base(Pot pot) => PotDraft.fromPot(pot, templates: _templates);

  /// Takes [fresh] in: untouched sections follow it, edited ones keep the
  /// user's values. The revision moves on unless the pot changed under an
  /// edited section; [force] (a 409's reread, or the answer to a save of
  /// section [saved]) moves it anyway and returns the edited sections the
  /// pot changed under.
  Set<int> _adopt(Pot fresh, {bool force = false, int? saved}) {
    final old = _pot, draft = _draft;
    if (old == null || draft == null) {
      _pot = fresh;
      _revision = fresh.revision;
      _draft = _base(fresh);
      return const {};
    }
    if (!force && fresh.revision < old.revision) return const {};
    final oldBase = _base(old), next = _base(fresh);
    var merged = next;
    for (var step = 0; step < PotStep.count; step++) {
      if (!draft.sameSection(step, oldBase)) {
        merged = merged.withSectionFrom(step, draft);
        if (step != saved && !oldBase.sameSection(step, next)) {
          _stale.add(step);
        }
      } else {
        _stale.remove(step);
      }
    }
    _stale.remove(saved);
    _pot = fresh;
    _draft = merged;
    if (force) {
      _revision = fresh.revision;
      final stale = {..._stale};
      _stale.clear();
      return stale;
    }
    if (_stale.isEmpty && _revision == old.revision) {
      _revision = fresh.revision;
    }
    return const {};
  }

  bool _dirty(int step) => !_draft!.sameSection(step, _base(_pot!));

  void _update(int step, PotDraft draft) => setState(() {
    _draft = draft;
    _saved.remove(step);
  });

  Future<void> _save(int step) async {
    final draft = _draft;
    final api = ref.read(apiProvider);
    if (draft == null || api == null || _busy.contains(step)) return;
    if (draft.issues(step).isNotEmpty) {
      setState(() => _shown.add(step));
      return;
    }
    setState(() {
      _busy.add(step);
      _errors.remove(step);
      _conflicts.remove(step);
    });
    final pots = PotsApi(api);
    try {
      final pot = await pots.update(
        widget.potId,
        revision: _revision,
        profile: step == PotStep.look ? draft.profile : null,
        work: step == PotStep.work ? draft.work : null,
        permissions: step == PotStep.reach ? draft.permissions : null,
        autonomy: step == PotStep.reach ? draft.autonomy : null,
        models: step == PotStep.models ? draft.models : null,
      );
      if (!mounted) return;
      setState(() {
        _busy.remove(step);
        _shown.remove(step);
        _saved.add(step);
        // The Gateway took this revision: move on with the edits of the
        // other sections.
        _conflicts.addAll(_adopt(pot, force: true, saved: step));
      });
      ref.invalidate(potProvider(widget.potId));
      ref.invalidate(potsProvider);
    } on ApiError catch (error) {
      if (error.status == 409 && error.code == 'revision_conflict') {
        await _reload(pots, step);
      } else if (mounted) {
        setState(() {
          _busy.remove(step);
          _errors[step] = error.message;
        });
      }
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy.remove(step);
          _errors[step] = error.message;
        });
      }
    }
  }

  /// After a 409: reads the pot again, keeps the edit and says so.
  Future<void> _reload(PotsApi pots, int step) async {
    try {
      final fresh = await pots.read(widget.potId);
      if (!mounted) return;
      setState(() {
        _busy.remove(step);
        _conflicts
          ..add(step)
          ..addAll(_adopt(fresh, force: true));
      });
    } on PircException catch (error) {
      if (mounted) {
        setState(() {
          _busy.remove(step);
          _errors[step] = error.message;
        });
      }
    }
  }

  void _scrollToSection() {
    if (_scrolled) return;
    _scrolled = true;
    final index = potSettingsSections.indexOf(widget.section ?? '');
    if (index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final target = _sectionKeys[index].currentContext;
      if (target != null && target.mounted) {
        Scrollable.ensureVisible(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    _templates = templateTexts(l10n);
    ref.listen(potProvider(widget.potId), (_, next) {
      final pot = next.value;
      if (pot != null && _pot != null) setState(() => _adopt(pot));
    });
    final value = ref.watch(potProvider(widget.potId));
    if (_pot == null && value.value != null) _adopt(value.value!);
    final pot = _pot;
    final draft = _draft;
    final name = pot?.name ?? '';

    Widget narrow(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );

    final Widget body;
    if (pot == null || draft == null) {
      body = value.hasError
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                spacing: 8,
                children: [
                  Text(l10n.listFailed),
                  OutlinedButton(
                    onPressed: () => ref.invalidate(potProvider(widget.potId)),
                    child: Text(l10n.retry),
                  ),
                ],
              ),
            )
          : const Center(child: CircularProgressIndicator());
    } else {
      _scrollToSection();
      final paused = pot.state == 'paused';
      Set<PotIssue> issues(int step) =>
          _shown.contains(step) ? draft.issues(step) : const {};
      body = SingleChildScrollView(
        key: const ValueKey('settings-scroll'),
        padding: const EdgeInsets.only(bottom: 24),
        child: narrow(
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var step = 0; step < PotStep.count; step++)
                _Section(
                  key: _sectionKeys[step],
                  step: step,
                  dirty: _dirty(step),
                  busy: _busy.contains(step),
                  saved: _saved.contains(step),
                  conflict: _conflicts.contains(step)
                      ? l10n.potSettingsConflict(name)
                      : null,
                  error: _errors[step],
                  onSave: () => _save(step),
                  child: switch (step) {
                    PotStep.look => PotLookForm(
                      key: const ValueKey('pot-step-look'),
                      draft: draft,
                      onChanged: (d) => _update(step, d),
                      issues: issues(step),
                    ),
                    PotStep.work => PotWorkForm(
                      key: const ValueKey('pot-step-work'),
                      draft: draft,
                      onChanged: (d) => _update(step, d),
                      issues: issues(step),
                    ),
                    PotStep.reach => PotReachForm(
                      key: const ValueKey('pot-step-reach'),
                      draft: draft,
                      onChanged: (d) => _update(step, d),
                      issues: issues(step),
                      potId: widget.potId,
                    ),
                    _ => PotModelsForm(
                      key: const ValueKey('pot-step-models'),
                      draft: draft,
                      onChanged: (d) => _update(step, d),
                      issues: issues(step),
                    ),
                  },
                ),
              GroupLabel(l10n.potSettingsOther),
              GroupedList(
                children: [
                  GroupedRow(
                    key: const ValueKey('settings-pause'),
                    title: paused
                        ? l10n.potSettingsResume
                        : l10n.potSettingsPause,
                    enabled: pot.state != 'archived',
                    onTap: () => paused
                        ? resumePot(context, ref, widget.potId)
                        : showPotPauseSheet(context, widget.potId),
                  ),
                  GroupedRow(
                    key: const ValueKey('settings-handover'),
                    title: l10n.potSettingsHandOver,
                    enabled: pot.state != 'archived',
                    onTap: () =>
                        context.go(chatLocation(handoverNewKey(widget.potId))),
                  ),
                  GroupedRow(
                    key: const ValueKey('settings-retire'),
                    title: l10n.potSettingsRetire,
                    titleColor: colors['status.danger'],
                    onTap: () =>
                        context.go(chatLocation(retireKey(widget.potId))),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      key: const ValueKey('pot-settings'),
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.potSettingsTitle(name),
              subtitle: l10n.potSettingsSubtitle,
              leading: IconButton(
                tooltip: l10n.back,
                color: colors['text.secondary'],
                onPressed: () => context.go(potProfileLocation(widget.potId)),
                icon: const Icon(
                  LucideIcons.chevronLeft,
                  size: PircSize.iconBar,
                ),
              ),
            ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}

/// One of the four sections: its title, the form, what happened to the
/// last save and its own Save button.
class _Section extends StatelessWidget {
  const _Section({
    super.key,
    required this.step,
    required this.dirty,
    required this.busy,
    required this.saved,
    required this.onSave,
    required this.child,
    this.conflict,
    this.error,
  });

  final int step;
  final bool dirty;
  final bool busy;
  final bool saved;
  final String? conflict;
  final String? error;
  final VoidCallback onSave;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    final title = switch (step) {
      PotStep.look => l10n.newPotStepLook,
      PotStep.work => l10n.newPotStepWork,
      PotStep.reach => l10n.newPotStepReach,
      _ => l10n.newPotStepModels,
    };
    final name = potSettingsSections[step];
    return Column(
      key: ValueKey('section-$name'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(16, step == 0 ? 8 : 32, 16, 0),
          child: Semantics(
            header: true,
            child: Text(
              '${'①②③④'[step]} $title',
              style: TextStyle(
                fontSize: 17,
                height: 24 / 17,
                fontWeight: FontWeight.w600,
                color: colors['text.primary'],
              ),
            ),
          ),
        ),
        child,
        if (conflict != null)
          Container(
            key: ValueKey('conflict-$name'),
            margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors['status.warningSoft'],
              borderRadius: BorderRadius.circular(PircRadius.md),
            ),
            child: Text(
              conflict!,
              style: TextStyle(
                fontSize: 13.5,
                height: 20 / 13.5,
                color: colors['text.warning'],
              ),
            ),
          ),
        if (error != null)
          GroupNote(error!, error: true, key: ValueKey('error-$name')),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            spacing: 12,
            children: [
              if (saved && !dirty)
                Text(
                  l10n.potSettingsSaved,
                  key: ValueKey('saved-$name'),
                  style: TextStyle(fontSize: 13.5, color: colors['text.muted']),
                ),
              FilledButton(
                key: ValueKey('save-$name'),
                style: inkButtonStyle(context),
                onPressed: dirty && !busy ? onSave : null,
                child: busy
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: colors['action.onPrimary'],
                        ),
                      )
                    : Text(l10n.potSettingsSave),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
