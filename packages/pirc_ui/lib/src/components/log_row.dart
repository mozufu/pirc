import 'package:flutter/material.dart';

import '../theme.dart';

/// The look of a [LogTag].
enum LogTagTone {
  plain,

  /// Something waits for the user (`status.warningSoft`).
  attention,

  /// A private message between pots (`fill.hoverStrong`).
  direct,
}

/// `e-tag`: a small pill (20 high, 11.5/500) naming a kind of activity or a
/// kind of held item.
class LogTag extends StatelessWidget {
  const LogTag(this.label, {super.key, this.tone = LogTagTone.plain});

  final String label;
  final LogTagTone tone;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return Container(
      height: 20,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: switch (tone) {
          LogTagTone.plain => colors['fill.hover'],
          LogTagTone.attention => colors['status.warningSoft'],
          LogTagTone.direct => colors['fill.hoverStrong'],
        },
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        maxLines: 1,
        style: TextStyle(
          fontSize: 11.5,
          height: 1,
          fontWeight: FontWeight.w500,
          color: tone == LogTagTone.attention
              ? colors['text.warning']
              : colors['text.secondary'],
        ),
      ),
    );
  }
}

/// `e-log`: one activity row. The [avatar] (28), then line 1: who (600),
/// [target] ("→ Check the nightly test") and the [time]; line 2: the
/// [tag] and the [quote] (13.5, at most two lines).
class LogRow extends StatelessWidget {
  const LogRow({
    super.key,
    required this.avatar,
    required this.who,
    this.target,
    required this.time,
    required this.tag,
    this.quote,
    this.onTap,
  });

  final Widget avatar;
  final String who;
  final String? target;
  final String time;
  final LogTag tag;
  final String? quote;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = PircColorTokens.of(context);
    return InkWell(
      onTap: onTap,
      hoverColor: colors['fill.hover'],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          spacing: 10,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: avatar),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 3,
                children: [
                  Row(
                    spacing: 6,
                    children: [
                      Text(
                        who,
                        style: TextStyle(
                          fontSize: 14,
                          height: 20 / 14,
                          fontWeight: FontWeight.w600,
                          color: colors['text.primary'],
                        ),
                      ),
                      Expanded(
                        child: Text(
                          target ?? '',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 14,
                            height: 20 / 14,
                            color: colors['text.primary'],
                          ),
                        ),
                      ),
                      Text(
                        time,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors['text.muted'],
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 6,
                    children: [
                      tag,
                      if (quote != null)
                        Expanded(
                          child: Text(
                            quote!,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              height: 20 / 13.5,
                              color: colors['text.secondary'],
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
