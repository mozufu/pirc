import 'package:flutter/material.dart';

import '../theme.dart';
import '../tokens.g.dart';

/// The bar at the top while the Gateway cannot be reached or the app is
/// reconnecting (C § states). It never offers to resend anything.
class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({
    super.key,
    required this.text,
    this.reconnecting = false,
  });

  /// "Offline. What you see may be out of date." or "Reconnecting…".
  final String text;
  final bool reconnecting;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: Material(
        color: colors['status.warningSoft'],
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: PircSpacing.gutterPhone,
              vertical: PircSpacing.stackSm,
            ),
            child: Row(
              children: [
                if (reconnecting)
                  SizedBox.square(
                    dimension: PircSize.iconInline,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: colors['text.warning'],
                    ),
                  )
                else
                  Icon(
                    Icons.cloud_off_outlined,
                    size: PircSize.iconInline,
                    color: colors['text.warning'],
                  ),
                const SizedBox(width: PircSpacing.stackSm),
                Expanded(
                  child: Text(
                    text,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: colors['text.warning'],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// A whole page while the app reconnects and reads the latest state
/// (`c-loading`). It shows no buttons: nothing can be acted on until the
/// state is known.
class LoadingOverlay extends StatelessWidget {
  const LoadingOverlay({super.key, required this.title, this.note});

  final String title;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    return ColoredBox(
      color: colors['surface.page'],
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(PircSpacing.stackXl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox.square(
                dimension: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: colors['accent.default'],
                ),
              ),
              const SizedBox(height: PircSpacing.stackLg),
              Text(title, style: text.titleSmall, textAlign: TextAlign.center),
              if (note != null) ...[
                const SizedBox(height: PircSpacing.stackXs),
                Text(note!, style: text.bodySmall, textAlign: TextAlign.center),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// A page that blocks the app until the user acts outside it (update the
/// app, sign in again).
class BlockingPage extends StatelessWidget {
  const BlockingPage({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final IconData icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final text = Theme.of(context).textTheme;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(PircSpacing.stackXl),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 40, color: colors['text.secondary']),
                  const SizedBox(height: PircSpacing.stackLg),
                  Text(
                    title,
                    style: text.titleLarge,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: PircSpacing.stackSm),
                  Text(
                    body,
                    style: text.bodySmall,
                    textAlign: TextAlign.center,
                  ),
                  if (action != null) ...[
                    const SizedBox(height: PircSpacing.stackXl),
                    action!,
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
