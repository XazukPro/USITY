import 'package:flutter/material.dart';

import '../theme/tokens.dart';

class CatalogCard extends StatelessWidget {
  const CatalogCard({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.iconColor,
    required this.tint,
    required this.trailing,
    required this.onTap,
    this.done = false,
    this.subtitleColor,
    this.warning,
  });
  final String title, subtitle;
  final String? warning;
  final IconData icon;
  final Color iconColor, tint;
  final Color? subtitleColor;
  final bool done;
  final Widget trailing;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context),
        dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.only(bottom: Metrics.space2),
      child: Material(
        color: done ? (dark ? p.bg : p.surfaceMuted) : p.surface,
        elevation: dark || done ? 0 : 1,
        shadowColor: p.border,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Metrics.space5),
          side: dark ? BorderSide(color: p.border) : BorderSide.none,
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              vertical: Metrics.space3,
              horizontal: Metrics.space4,
            ),
            child: Row(
              children: [
                Opacity(
                  opacity: done ? 0.6 : 1,
                  child: Container(
                    width: Metrics.hitMin,
                    height: Metrics.hitMin,
                    decoration: BoxDecoration(
                      color: tint,
                      borderRadius: BorderRadius.circular(Metrics.radiusMd),
                    ),
                    child: Icon(icon, color: iconColor, size: Metrics.space5),
                  ),
                ),
                const SizedBox(width: Metrics.space3),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TypeScale.bodyStrong.copyWith(
                          color: done ? p.inkMuted : p.ink,
                          decoration: done ? TextDecoration.lineThrough : null,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TypeScale.caption.copyWith(
                          color: done
                              ? p.inkMuted
                              : subtitleColor ?? p.inkMuted,
                        ),
                      ),
                      if (warning != null && !done)
                        Text(
                          warning!,
                          style: TypeScale.caption.copyWith(
                            color: p.dangerInk,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                    ],
                  ),
                ),
                trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class SectionCaption extends StatelessWidget {
  const SectionCaption(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      Metrics.space1,
      Metrics.space3,
      0,
      Metrics.space2,
    ),
    child: Text(
      text,
      style: TypeScale.callout.copyWith(
        fontWeight: FontWeight.w600,
        color: Palette.of(context).inkMuted,
      ),
    ),
  );
}
