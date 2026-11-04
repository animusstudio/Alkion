import 'package:flutter/material.dart';

import '../theme/alkion_icon.dart';
import '../catalog/catalog.dart';
import '../catalog/catalog_artwork.dart';
import '../catalog/catalog_media.dart';
import 'catalog_media_widgets.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/motion.dart';
import '../theme/typography.dart';
import '../widgets/w_action_sheet.dart';

Future<String?> showCatalogChoiceDetails(
  BuildContext context, {
  required String title,
  required CatalogIndex index,
  required CatalogVariant? variant,
  required List<String> metrics,
  required List<WSheetAction<String>> actions,
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
    final media = catalogMediaForVariant(variant);
    final artwork = catalogArtworkForVariant(variant);
    String names(Set<String> keys) => index.browseGroups
        .where((group) => keys.contains(group.key))
        .map(index.groupLabel)
        .join(' · ');
    Widget fact(String heading, String value) => Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(heading, style: WorkoutType.body(size: 13, color: t.dim)),
          const SizedBox(height: 8),
          Text(value, style: WorkoutType.body(size: 16, color: t.text)),
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
                    if (media != null)
                      CatalogOptionalMovementFrames(media: media),
                    if (variant != null)
                      fact(
                        l.catalogEquipment,
                        labels.equipment(variant.equipmentKind),
                      ),
                    if (membership?.status == 'reviewed') ...[
                      if (membership!.targetGroups.isNotEmpty)
                        fact(
                          l.catalogTargetMatches,
                          names(membership.targetGroups),
                        ),
                      if (membership.secondaryGroups.isNotEmpty)
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
                      Semantics(
                        selected: action.selected,
                        child: TextButton(
                          onPressed: action.enabled
                              ? () => Navigator.pop(context, action.value)
                              : null,
                          style: TextButton.styleFrom(
                            alignment: Alignment.centerLeft,
                            minimumSize: const Size(48, 48),
                          ),
                          child: Row(
                            children: [
                              AlkionIcon(
                                action.selected
                                    ? AlkionGlyph.check
                                    : switch (action.value) {
                                        'favorite' => AlkionGlyph.favorite,
                                        'again' => AlkionGlyph.add,
                                        'remove' => AlkionGlyph.minus,
                                        'edit' => AlkionGlyph.edit,
                                        _ => AlkionGlyph.info,
                                      },
                                size: 20,
                              ),
                              const SizedBox(width: 12),
                              Expanded(child: Text(action.label)),
                            ],
                          ),
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
                    const SizedBox(height: 16),
                    if (membership?.status == 'reviewed') ...[
                      const SizedBox(height: 16),
                      Text(
                        labels.targetExplanation,
                        style: WorkoutType.body(size: 14, color: t.dim),
                      ),
                    ],
                    Text(
                      variant?.muscleCoverage == 'partial'
                          ? labels.partialMuscles
                          : labels.unknownMuscles,
                      style: WorkoutType.body(size: 14, color: t.dim),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      l.catalogBrowseOnlyNotice,
                      style: WorkoutType.body(size: 13, color: t.dim),
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
