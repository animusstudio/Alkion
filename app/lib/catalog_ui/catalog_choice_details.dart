import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../catalog/catalog.dart';
import '../catalog/catalog_artwork.dart';
import 'catalog_media_widgets.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';

/// The details header star toggles in place; the sheet stays open and reads
/// the saved state back from [listenable] after each change.
class CatalogDetailsFavorite {
  const CatalogDetailsFavorite({
    required this.listenable,
    required this.isSaved,
    required this.onToggle,
  });

  final Listenable listenable;
  final bool Function() isSaved;
  final VoidCallback onToggle;
}

/// Popping actions only (edit, add again, remove). The favourite star and the
/// muscle evidence button act over the open sheet without closing it.
Future<String?> showCatalogChoiceDetails(
  BuildContext context, {
  required String title,
  required CatalogIndex index,
  required CatalogVariant? variant,
  required List<String> metrics,
  required List<WSheetAction<String>> actions,
  CatalogDetailsFavorite? favorite,
}) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  sheetAnimationStyle: Motion.sheet(context),
  useSafeArea: true,
  backgroundColor: context.tokens.surface,
  barrierColor: context.tokens.overlay,
  builder: (context) {
    final l = AppLocalizations.of(context);
    final labels = CatalogLabels(Localizations.localeOf(context).languageCode);
    final t = context.tokens;
    final membership = index.bundle.browse?.variants[variant?.id];
    final reviewed = membership?.status == 'reviewed';
    final showsTarget = reviewed && membership!.targetGroups.isNotEmpty;
    final artwork = catalogArtworkForVariant(variant);
    String names(Set<String> keys) => index.browseGroups
        .where((group) => keys.contains(group.key))
        .map(index.groupLabel)
        .join(' · ');
    // The evidence dialog opens over the sheet, which stays open beneath it.
    Future<void> evidence() => showWDialog<void>(
      context,
      title: l.catalogMuscleEvidence,
      message: [
        if (showsTarget) labels.targetExplanation,
        variant?.muscleCoverage == 'partial'
            ? labels.partialMuscles
            : labels.unknownMuscles,
        l.catalogBrowseOnlyNotice,
      ].join('\n\n'),
      actions: [WDialogAction(label: l.commonOk, value: null)],
    );
    final info = IconButton(
      key: const Key('catalog-details-muscle-info'),
      tooltip: l.catalogMuscleEvidence,
      onPressed: evidence,
      icon: AlkionIcon(AlkionGlyph.info, size: 20, color: t.dim),
    );
    Widget fact(String heading, String value, {Widget? trailing}) => Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: WorkoutType.body(size: 13, color: t.dim)),
          const SizedBox(height: 8),
          if (trailing == null)
            Text(value, style: WorkoutType.body(size: 16, color: t.text))
          else
            Row(
              children: [
                Flexible(
                  child: Text(
                    value,
                    style: WorkoutType.body(size: 16, color: t.text),
                  ),
                ),
                trailing,
              ],
            ),
        ],
      ),
    );
    return SafeArea(
      top: false,
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .86,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      l.catalogDetails,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                  ),
                  if (favorite != null)
                    ListenableBuilder(
                      listenable: favorite.listenable,
                      builder: (context, _) => IconButton(
                        key: const Key('catalog-details-favorite'),
                        tooltip: l.catalogFavorite,
                        isSelected: favorite.isSaved(),
                        onPressed: favorite.onToggle,
                        icon: const AlkionIcon(AlkionGlyph.favorite),
                        selectedIcon: AlkionIcon(
                          AlkionGlyph.favoriteFilled,
                          color: t.accentText,
                        ),
                      ),
                    ),
                  IconButton(
                    tooltip: l.commonDone,
                    onPressed: () => Navigator.pop(context),
                    icon: const AlkionIcon(AlkionGlyph.close),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      title,
                      style: WorkoutType.display(size: 22, color: t.text),
                    ),
                    if (artwork != null)
                      CatalogArtworkDetails(artwork: artwork),
                    if (variant != null)
                      fact(
                        l.catalogEquipment,
                        labels.equipment(variant.equipmentKind),
                      ),
                    if (showsTarget)
                      fact(
                        l.catalogTargetMatches,
                        names(membership.targetGroups),
                        trailing: info,
                      )
                    else
                      // Without a reviewed target line, the evidence button
                      // stands under its own heading where muscles would be.
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Row(
                          children: [
                            Flexible(
                              child: Text(
                                l.catalogMuscleEvidence,
                                style: WorkoutType.body(size: 13, color: t.dim),
                              ),
                            ),
                            info,
                          ],
                        ),
                      ),
                    if (reviewed) ...[
                      if (membership!.secondaryGroups.isNotEmpty)
                        fact(
                          l.catalogSecondaryMatches,
                          names(membership.secondaryGroups),
                        ),
                      if (membership.activityGroups.isNotEmpty)
                        fact(
                          l.catalogActivities,
                          names(membership.activityGroups),
                        ),
                    ],
                    const SizedBox(height: 16),
                    for (final action in actions)
                      TextButton(
                        onPressed: action.enabled
                            ? () => Navigator.pop(context, action.value)
                            : null,
                        style: TextButton.styleFrom(
                          alignment: Alignment.centerLeft,
                          minimumSize: const Size(48, 48),
                        ),
                        child: Row(
                          children: [
                            AlkionIcon(switch (action.value) {
                              'again' => AlkionGlyph.add,
                              'remove' => AlkionGlyph.minus,
                              'edit' => AlkionGlyph.edit,
                              _ => AlkionGlyph.chevronRight,
                            }, size: 20),
                            const SizedBox(width: 12),
                            Expanded(child: Text(action.label)),
                          ],
                        ),
                      ),
                    const Divider(height: 24),
                    if (variant != null) ...[
                      if (variant.facets.isNotEmpty)
                        fact(
                          labels.setup,
                          variant.facets.entries
                              .map(
                                (entry) => labels.facet(entry.key, entry.value),
                              )
                              .toSet()
                              .join(' · '),
                        ),
                    ],
                    for (final metric in metrics)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(
                          metric,
                          style: WorkoutType.body(size: 14, color: t.dim),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  },
);
