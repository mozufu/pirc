import 'package:flutter/material.dart';

import '../theme.dart';

/// The four avatar sizes of `e-av` (E spec § 10): 28, 36, 48 and 88.
enum AvatarSize {
  sm(28, 12),
  md(36, 14),
  standard(48, 18),
  lg(88, 34);

  const AvatarSize(this.diameter, this.fontSize);
  final double diameter;
  final double fontSize;

  /// Only `.e-av.md` uses the smaller "working" pill; `sm` keeps the
  /// 16 px one.
  bool get small => this == md;
}

/// What the dot on an avatar says (E spec § 3). Available shows nothing.
enum AvatarStatus {
  none,

  /// "Working": a green capsule with three dots that pulse gently (still
  /// when the system asks for less motion).
  working,

  /// "Unavailable": a grey dot.
  unavailable,
}

/// The colour token of avatar colour [color] (1–5); anything else is 1.
String avatarColorToken(int color) =>
    'avatar.${color >= 1 && color <= 5 ? color : 1}';

/// The letter an avatar shows: the first character of [name].
String avatarInitial(String name) {
  final trimmed = name.trim();
  return trimmed.isEmpty ? '' : trimmed.characters.first.toUpperCase();
}

/// `e-av`: a round avatar in one of the five identity colours (never a
/// status colour) with the name's first letter, or the uploaded [image].
/// The colour stays underneath while the image loads or when it fails.
/// `me` uses the neutral fill for the user.
class Avatar extends StatelessWidget {
  const Avatar({
    super.key,
    required this.name,
    this.color = 1,
    this.size = AvatarSize.standard,
    this.status = AvatarStatus.none,
    this.statusLabel,
    this.me = false,
    this.image,
    this.ring,
  }) : diameter = null,
       fontSize = null;

  /// An avatar at a size outside the four presets (group avatars, chips).
  const Avatar.custom({
    super.key,
    required this.name,
    required double this.diameter,
    required double this.fontSize,
    this.color = 1,
    this.me = false,
    this.image,
    this.ring,
  }) : size = AvatarSize.standard,
       status = AvatarStatus.none,
       statusLabel = null;

  final String name;

  /// 1–5 (`avatar.1`–`avatar.5`).
  final int color;
  final AvatarSize size;
  final AvatarStatus status;

  /// Read by screen readers for [status] ("Working", "Unavailable").
  final String? statusLabel;

  /// The user's own avatar: neutral fill, secondary text.
  final bool me;
  final ImageProvider? image;

  /// The colour of the ring that separates the status dot (and, in a group
  /// avatar, the avatar) from what is behind: the page colour by default,
  /// `surface.grouped` on grouped pages.
  final Color? ring;

  /// A size outside the presets ([Avatar.custom]); null uses [size].
  final double? diameter;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final diameter = this.diameter ?? size.diameter;
    final background = me
        ? colors['fill.hoverStrong']
        : colors[avatarColorToken(color)];
    final ink = me ? colors['text.secondary'] : colors['avatar.ink'];
    Widget disc = Container(
      width: diameter,
      height: diameter,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: background, shape: BoxShape.circle),
      child: Text(
        avatarInitial(name),
        textScaler: TextScaler.noScaling,
        style: TextStyle(
          fontSize: fontSize ?? size.fontSize,
          height: 1,
          fontWeight: FontWeight.w600,
          color: ink,
        ),
      ),
    );
    if (image != null) {
      disc = Stack(
        children: [
          disc,
          ClipOval(
            child: Image(
              image: image!,
              width: diameter,
              height: diameter,
              fit: BoxFit.cover,
              // The colour shows while it loads and when it fails.
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
          ),
        ],
      );
    }
    final ringColor = ring ?? colors['surface.page'];
    final badge = switch (status) {
      AvatarStatus.none => null,
      AvatarStatus.working => _WorkingPill(small: size.small, ring: ringColor),
      AvatarStatus.unavailable => _OffDot(ring: ringColor),
    };
    return Semantics(
      image: true,
      label: [name, if (badge != null) ?statusLabel].join(', '),
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: diameter,
        child: badge == null
            ? disc
            : Stack(
                clipBehavior: Clip.none,
                children: [
                  disc,
                  Positioned(
                    right: status == AvatarStatus.working
                        ? (size.small ? -7 : -8)
                        : 0,
                    bottom: status == AvatarStatus.working ? -2 : 0,
                    child: badge,
                  ),
                ],
              ),
      ),
    );
  }
}

/// `.st.off`: a 12 grey dot with a 2.5 ring.
class _OffDot extends StatelessWidget {
  const _OffDot({required this.ring});
  final Color ring;

  @override
  Widget build(BuildContext context) => Container(
    width: 12,
    height: 12,
    decoration: BoxDecoration(
      color: PircColorTokens.of(context)['text.faint'],
      shape: BoxShape.circle,
      boxShadow: [BoxShadow(color: ring, spreadRadius: 2.5)],
    ),
  );
}

/// `.st.work`: a green capsule (16 high, 14 on small avatars) with three
/// dots pulsing 0.45 → 1 → 0.45 over 1.2 s, each 0.15 s after the last.
class _WorkingPill extends StatefulWidget {
  const _WorkingPill({required this.small, required this.ring});
  final bool small;
  final Color ring;

  @override
  State<_WorkingPill> createState() => _WorkingPillState();
}

class _WorkingPillState extends State<_WorkingPill>
    with SingleTickerProviderStateMixin {
  late final _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _pulse.stop();
    } else if (!_pulse.isAnimating) {
      _pulse.repeat();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  /// The `e-dots` keyframes at [t] (0–1): 0.45, 1 at 30 %, 0.45 from 60 %.
  static double _opacity(double t) {
    final eased = Curves.easeInOut;
    if (t < 0.3) return 0.45 + 0.55 * eased.transform(t / 0.3);
    if (t < 0.6) return 1 - 0.55 * eased.transform((t - 0.3) / 0.3);
    return 0.45;
  }

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    final still = MediaQuery.disableAnimationsOf(context);
    final small = widget.small;
    final dot = small ? 3.5 : 4.0;
    return Container(
      height: small ? 14 : 16,
      padding: EdgeInsets.symmetric(horizontal: small ? 3.5 : 4),
      decoration: BoxDecoration(
        color: colors['status.working'],
        borderRadius: BorderRadius.circular(small ? 7 : 8),
        boxShadow: [BoxShadow(color: widget.ring, spreadRadius: 2.5)],
      ),
      child: AnimatedBuilder(
        animation: _pulse,
        builder: (context, _) => Row(
          mainAxisSize: MainAxisSize.min,
          spacing: small ? 2 : 2.5,
          children: [
            for (var i = 0; i < 3; i++)
              Opacity(
                opacity: still ? 1 : _opacity((_pulse.value - i * 0.125) % 1.0),
                child: Container(
                  width: dot,
                  height: dot,
                  decoration: BoxDecoration(
                    color: colors['status.workingDot'],
                    shape: BoxShape.circle,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// One member of a [GroupAvatar].
@immutable
class AvatarFace {
  const AvatarFace(this.name, {this.color = 1, this.image, this.me = false});
  final String name;
  final int color;
  final ImageProvider? image;
  final bool me;
}

/// `e-avg`: two member avatars stacked in a 48 square (32 each, the first
/// top left, the second bottom right on top), each ringed in the page
/// colour. [small] is the 32 square with 22 avatars; [dimension],
/// [faceDiameter] and [fontSize] give other sizes (a 36 header with 24
/// faces, an 88 profile with 58).
class GroupAvatar extends StatelessWidget {
  const GroupAvatar({
    super.key,
    required this.first,
    required this.second,
    this.small = false,
    this.ring,
    this.semanticLabel,
    this.dimension,
    this.faceDiameter,
    this.fontSize,
  });

  final AvatarFace first;
  final AvatarFace second;
  final bool small;
  final Color? ring;
  final String? semanticLabel;
  final double? dimension;
  final double? faceDiameter;
  final double? fontSize;

  @override
  Widget build(BuildContext context) {
    final ringColor = ring ?? PircColorTokens.of(context)['surface.page'];
    final box = dimension ?? (small ? 32.0 : 48.0);
    final face = faceDiameter ?? (small ? 22.0 : 32.0);
    Widget member(AvatarFace f) => DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        boxShadow: [BoxShadow(color: ringColor, spreadRadius: 2)],
      ),
      child: Avatar.custom(
        name: f.name,
        color: f.color,
        image: f.image,
        me: f.me,
        diameter: face,
        fontSize: fontSize ?? (small ? 10 : 13),
      ),
    );
    return Semantics(
      image: true,
      label: semanticLabel ?? '${first.name}, ${second.name}',
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: box,
        child: Stack(
          children: [
            Positioned(left: 0, top: 0, child: member(first)),
            Positioned(right: 0, bottom: 0, child: member(second)),
          ],
        ),
      ),
    );
  }
}
