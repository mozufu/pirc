import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:pirc_client/pirc_client.dart';
import 'package:pirc_ui/pirc_ui.dart';

import '../../l10n/app_localizations.dart';
import '../connection/data.dart';
import '../work/composer/model_sheet.dart';
import '../work/work_data.dart';
import 'chat_data.dart';
import 'pot_draft.dart';
import 'pot_form.dart';

/// New pot (E7–E10): the four sections one at a time with Back / Next;
/// the last button creates the pot with one request and opens its
/// conversation. A refused request shows its message on the step it
/// concerns; the draft is kept whole while moving between steps.
class NewPotScreen extends ConsumerStatefulWidget {
  const NewPotScreen({super.key, this.showBack = true});

  /// Shows Cancel on step ① (the content pane hides it on desktop, where
  /// the list stays beside it).
  final bool showBack;

  @override
  ConsumerState<NewPotScreen> createState() => _NewPotScreenState();
}

class _NewPotScreenState extends ConsumerState<NewPotScreen> {
  PotDraft? _draft;
  int _step = PotStep.look;

  /// Steps whose problems are shown (Next was pressed there).
  final _shown = <int>{};

  /// The Gateway's message for a step, after a refused create.
  final _errors = <int, String>{};
  bool _busy = false;
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _update(PotDraft draft) => setState(() => _draft = draft);

  void _go(int step) {
    setState(() => _step = step);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _back() {
    if (_step > PotStep.look) {
      _go(_step - 1);
    } else {
      context.go('/chat');
    }
  }

  void _next(PotDraft draft) {
    if (draft.issues(_step).isNotEmpty) {
      setState(() => _shown.add(_step));
      return;
    }
    if (_step < PotStep.models) {
      _go(_step + 1);
    } else {
      _create(draft);
    }
  }

  Future<void> _create(PotDraft draft) async {
    for (var step = 0; step < PotStep.count; step++) {
      if (draft.issues(step).isNotEmpty) {
        _shown.add(step);
        return _go(step);
      }
    }
    final api = ref.read(apiProvider);
    if (api == null) return;
    setState(() {
      _busy = true;
      _errors.clear();
    });
    try {
      final pot = await PotsApi(api).create(draft.toInput());
      if (!mounted) return;
      ref.invalidate(potsProvider);
      context.go(chatLocation(potChatKey(pot.id)));
    } on PircException catch (error) {
      if (!mounted) return;
      final step = error is ApiError ? potErrorStep(error) ?? _step : _step;
      setState(() {
        _busy = false;
        _errors[step] = error.message;
      });
      if (step != _step) _go(step);
    }
  }

  PotDraft _initial(AppLocalizations l10n) => PotDraft(
    template: PersonalityTemplate.rigorous,
    personality: templateText(l10n, PersonalityTemplate.rigorous),
  );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final colors = PircColorTokens.of(context);
    var draft = _draft ??= _initial(l10n);
    final catalog = ref.watch(modelCatalogProvider).value;
    if (catalog != null && draft.main == null) {
      // The Gateway's default model, once the list arrives.
      draft = _draft = draft.withDefaultModel(catalog);
    }
    final issues = _shown.contains(_step) ? draft.issues(_step) : <PotIssue>{};
    final section = switch (_step) {
      PotStep.look => PotLookForm(
        key: const ValueKey('pot-step-look'),
        draft: draft,
        onChanged: _update,
        issues: issues,
      ),
      PotStep.work => PotWorkForm(
        key: const ValueKey('pot-step-work'),
        draft: draft,
        onChanged: _update,
        issues: issues,
      ),
      PotStep.reach => PotReachForm(
        key: const ValueKey('pot-step-reach'),
        draft: draft,
        onChanged: _update,
        issues: issues,
      ),
      _ => PotModelsForm(
        key: const ValueKey('pot-step-models'),
        draft: draft,
        onChanged: _update,
        issues: issues,
      ),
    };
    final stepTitle = switch (_step) {
      PotStep.look => l10n.newPotStepLook,
      PotStep.work => l10n.newPotStepWork,
      PotStep.reach => l10n.newPotStepReach,
      _ => l10n.newPotStepModels,
    };
    final error = _errors[_step];
    final last = _step == PotStep.models;
    final name = draft.name.trim();
    Widget narrow(Widget child) => Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
    return Scaffold(
      backgroundColor: colors['surface.grouped'],
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            PotTopBar(
              title: l10n.newPotTitle,
              subtitle: l10n.newPotStep(_step + 1, stepTitle),
              leading: _step > PotStep.look
                  ? IconButton(
                      key: const ValueKey('pot-back'),
                      tooltip: l10n.back,
                      onPressed: _busy ? null : _back,
                      color: colors['text.secondary'],
                      icon: const Icon(
                        LucideIcons.chevronLeft,
                        size: PircSize.iconBar,
                      ),
                    )
                  : widget.showBack
                  ? TextButton(
                      key: const ValueKey('pot-cancel'),
                      onPressed: _back,
                      style: TextButton.styleFrom(
                        foregroundColor: colors['text.primary'],
                        minimumSize: const Size(0, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                        shape: const StadiumBorder(),
                        textStyle: Theme.of(
                          context,
                        ).textTheme.labelLarge?.copyWith(fontSize: 14),
                      ),
                      child: Text(l10n.cancel),
                    )
                  : null,
            ),
            Expanded(
              child: SingleChildScrollView(
                key: const ValueKey('pot-scroll'),
                controller: _scroll,
                padding: const EdgeInsets.only(bottom: 16),
                child: narrow(
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (error != null)
                        Container(
                          key: const ValueKey('pot-error'),
                          margin: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            color: colors['status.dangerSoft'],
                            borderRadius: BorderRadius.circular(PircRadius.md),
                          ),
                          child: Text(
                            error,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 20 / 13.5,
                              color: colors['status.danger'],
                            ),
                          ),
                        ),
                      section,
                    ],
                  ),
                ),
              ),
            ),
            narrow(
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
                child: FilledButton(
                  key: const ValueKey('pot-next'),
                  style: inkButtonStyle(context),
                  onPressed: _busy ? null : () => _next(draft),
                  child: _busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: colors['action.onPrimary'],
                          ),
                        )
                      : Text(
                          !last
                              ? l10n.newPotNext
                              : name.isEmpty
                              ? l10n.newPotCreatePlain
                              : l10n.newPotCreate(name),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// `c-top`: 56 high, the leading button at the left, the centred title
/// (16/600) with its line (12 muted), and an optional trailing button.
/// New pot, the pot's profile and its settings use it.
class PotTopBar extends StatelessWidget {
  const PotTopBar({
    super.key,
    this.title = '',
    this.subtitle = '',
    this.leading,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final Widget? leading;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final text = Theme.of(context).textTheme;
    return SizedBox(
      height: PircSize.topBar,
      child: Stack(
        children: [
          Positioned(
            left: 100,
            right: 100,
            top: 4,
            height: 48,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.titleSmall,
                ),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: text.labelSmall?.copyWith(
                    fontSize: 12,
                    height: 16 / 12,
                  ),
                ),
              ],
            ),
          ),
          if (leading != null)
            Positioned(
              left: 6,
              top: 0,
              bottom: 0,
              child: Center(child: leading),
            ),
          if (trailing != null)
            Positioned(
              right: 6,
              top: 0,
              bottom: 0,
              child: Center(child: trailing),
            ),
        ],
      ),
    );
  }
}
