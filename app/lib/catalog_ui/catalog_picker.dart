import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_action_sheet.dart';
import '../widgets/w_dialog.dart';
import 'catalog_trial_scope.dart';

/// The explicit Close/Back paths protect pending occurrences. Modal drag and
/// barrier dismissal are disabled so neither can bypass the same decision.
Future<List<CatalogChoice>?> showCatalogPicker(
  BuildContext context, {
  required CatalogTrialState state,
  bool multiple = false,
  String? familyId,
  CatalogChoice? currentChoice,
  bool setupIntent = false,
  Set<String> inDayChoiceKeys = const {},
}) => showModalBottomSheet<List<CatalogChoice>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  isDismissible: false,
  enableDrag: false,
  backgroundColor: context.tokens.surface,
  barrierColor: context.tokens.overlay,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (_) => CatalogPicker(
    state: state,
    multiple: multiple,
    familyId: familyId,
    currentChoice: currentChoice,
    setupIntent: setupIntent,
    inDayChoiceKeys: inDayChoiceKeys,
  ),
);

enum _CatalogView { home, all, recent, favorites }

class CatalogPicker extends StatefulWidget {
  const CatalogPicker({
    super.key,
    required this.state,
    this.multiple = false,
    this.familyId,
    this.currentChoice,
    this.setupIntent = false,
    this.inDayChoiceKeys = const {},
  });
  final CatalogTrialState state;
  final bool multiple, setupIntent;
  final String? familyId;
  final CatalogChoice? currentChoice;
  final Set<String> inDayChoiceKeys;
  @override
  State<CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<CatalogPicker> {
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  final _selected = <CatalogChoice>[];
  final _scroll = ScrollController();
  String? _group, _equipment;
  CatalogHit? _navigation;
  late _CatalogView _view;
  bool _secondary = false, _basketExpanded = false;
  bool _allowPop = false, _confirming = false;
  String get _locale => Localizations.localeOf(context).languageCode;

  @override
  void initState() {
    super.initState();
    _view = widget.familyId == null ? _CatalogView.home : _CatalogView.all;
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _pop([List<CatalogChoice>? choices]) {
    setState(() => _allowPop = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop(choices);
    });
  }

  Future<void> _dismiss() async {
    if (_confirming || _allowPop) return;
    if (_selected.isNotEmpty) {
      _confirming = true;
      final l = AppLocalizations.of(context);
      final discard = await showWConfirm(
        context,
        title: l.catalogDiscardTitle,
        message: l.catalogDiscardBody,
        cancelLabel: l.catalogKeepSelection,
        confirmLabel: l.catalogDiscardSelection,
        destructive: true,
      );
      _confirming = false;
      if (!mounted || discard != true) return;
    }
    _pop();
  }

  Future<void> _back() async {
    if (MediaQuery.viewInsetsOf(context).bottom > 0) {
      _searchFocus.unfocus();
      FocusManager.instance.primaryFocus?.unfocus();
      return;
    }
    if (_navigation != null) {
      setState(() => _navigation = null);
    } else if (_group != null) {
      setState(() {
        _group = null;
        _view = _CatalogView.home;
      });
    } else {
      await _dismiss();
    }
  }

  void _choose(CatalogChoice choice, {bool again = false}) {
    if (!widget.multiple) {
      widget.state.remember(choice);
      _pop([choice]);
      return;
    }
    setState(() {
      final last = _selected.lastIndexWhere((c) => c.key == choice.key);
      if (!again && last >= 0) {
        _selected.removeAt(last);
      } else {
        _selected.add(choice);
        widget.state.remember(choice);
      }
    });
  }

  Future<void> _details(CatalogChoice choice) async {
    final l = AppLocalizations.of(context);
    final result = await showWActionSheet<String>(
      context,
      title: widget.state.identifyingLabel(choice, _locale),
      actions: [
        WSheetAction(
          label: l.catalogFavorite,
          value: 'favorite',
          selected: widget.state.favorites.contains(choice.key),
        ),
        if (widget.multiple) ...[
          WSheetAction(label: l.catalogAddAgain, value: 'again'),
          if (_selected.any((c) => c.key == choice.key))
            WSheetAction(label: l.commonRemove, value: 'remove'),
        ],
        WSheetAction(label: l.catalogMuscleEvidence, value: 'muscles'),
      ],
    );
    if (!mounted) return;
    if (result == 'favorite') {
      setState(() => widget.state.toggleFavorite(choice));
    } else if (result == 'again') {
      _choose(choice, again: true);
    } else if (result == 'remove') {
      setState(() {
        _selected.removeAt(
          _selected.lastIndexWhere((c) => c.key == choice.key),
        );
      });
    } else if (result == 'muscles') {
      final labels = CatalogLabels(_locale);
      final coverage =
          widget.state.bundle.variants[choice.variantId]?.muscleCoverage ==
              'partial'
          ? labels.partialMuscles
          : labels.unknownMuscles;
      await showWDialog<void>(
        context,
        title: l.catalogMuscleEvidence,
        message: '$coverage\n\n${l.catalogBrowseOnlyNotice}',
        actions: [WDialogAction(label: l.commonOk, value: null)],
      );
    }
  }

  Future<void> _create() async {
    final choice = await showModalBottomSheet<CatalogChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: context.tokens.surface,
      builder: (_) =>
          _CustomExerciseForm(query: _search.text, state: widget.state),
    );
    if (mounted && choice != null) _choose(choice, again: true);
  }

  void _openGroup(String group, {bool replaceQuery = false}) {
    setState(() {
      _group = group;
      _navigation = null;
      _view = _CatalogView.all;
      if (replaceQuery) _search.clear();
    });
    _searchFocus.unfocus();
  }

  Future<void> _pickGroup() async {
    final index = widget.state.index(_locale);
    final selected = await showWActionSheet<String>(
      context,
      title: AppLocalizations.of(context).catalogBrowseMuscles,
      actions: [
        for (final group in index.browseGroups)
          WSheetAction(
            label: index.groupLabel(group),
            value: group.key,
            selected: _group == group.key,
          ),
        WSheetAction(
          label: AppLocalizations.of(context).catalogUnclassified,
          value: CatalogFilter.unclassified,
          selected: _group == CatalogFilter.unclassified,
        ),
      ],
    );
    if (mounted && selected != null) _openGroup(selected);
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.fromLTRB(0, 20, 0, 8),
    child: Text(
      label,
      style: WorkoutType.body(size: 14, color: context.tokens.dim),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), state = widget.state;
    final index = state.index(_locale), labels = CatalogLabels(_locale);
    final family =
        widget.familyId ??
        (_navigation?.kind == 'family' ? _navigation!.id : null);
    final filter = CatalogFilter(
      familyIds: family == null ? [] : [family],
      equipmentKinds: _equipment == null ? [] : [_equipment!],
      groupKey: _group,
      includeSecondary: _secondary,
    );
    final result = index.search(_search.text, filter: filter);
    bool withinNavigation(String id) =>
        _navigation == null ||
        state.bundle.targetMatches(
          _navigation!.kind,
          _navigation!.id,
          state.bundle.variants[id]!,
        );
    bool admitted(CatalogChoice choice) => choice.variantId == null
        ? index.matchesCustomName(
            choice.customName!,
            query: _search.text,
            filter: filter,
            personalGroups: choice.personalGroups,
          )
        : result.admitsVariant(choice.variantId!) &&
              withinNavigation(choice.variantId!);
    final recent = state.recents.where(admitted).toList();
    final favorites = state.choices.values
        .where((c) => state.favorites.contains(c.key) && admitted(c))
        .toList();
    final custom = state.choices.values
        .where((c) => c.variantId == null && admitted(c))
        .toList();
    final home =
        _view == _CatalogView.home &&
        _search.text.isEmpty &&
        _group == null &&
        _equipment == null &&
        _navigation == null &&
        widget.familyId == null;
    final equipment = <String>{
      ...index.availableEquipment(_search.text, filter: filter),
      if (_equipment != null) _equipment!,
    }.toList();
    // A collection drill-down retains its own selector as well as all current
    // constraints. It never uses the old query's cached admitted-child list.
    if (_navigation != null && _navigation!.kind != 'family') {
      final available = index.search(
        _search.text,
        filter: filter.copyWith(equipmentKinds: const []),
      );
      final kinds = {...available.variantIds, ...available.secondaryVariantIds}
          .where(withinNavigation)
          .map((id) => state.bundle.variants[id]!.equipmentKind)
          .toSet();
      equipment.removeWhere(
        (kind) => kind != _equipment && !kinds.contains(kind),
      );
    }
    final group = state.bundle.browse?.groups[_group];
    final groupLabel = _group == CatalogFilter.unclassified
        ? l.catalogUnclassified
        : group == null
        ? null
        : index.groupLabel(group);
    final direct = _navigation != null || widget.familyId != null;
    List<CatalogVariant> variants(Set<String> ids) {
      final values = ids
          .where(withinNavigation)
          .map((id) => state.bundle.variants[id]!)
          .toList();
      values.sort((a, b) => index.compareVariants(a.id, b.id));
      return values;
    }

    final primaryVariants = variants(result.variantIds);
    final secondaryVariants = variants(result.secondaryVariantIds);
    List<CatalogVariant> suggestedVariants(List<CatalogHit> hits) => variants({
      for (final hit in hits)
        if (hit.variantId != null)
          hit.variantId!
        else
          ...?hit.admittedVariantIds,
    });
    final primarySuggestions = suggestedVariants(result.suggested);
    final secondarySuggestions = suggestedVariants(result.secondarySuggested);
    final visibleSiblings = <String, CatalogVariant>{
      for (final v in [
        ...primaryVariants,
        ...secondaryVariants,
        ...primarySuggestions,
        ...secondarySuggestions,
      ])
        v.id: v,
    }.values.toList();
    final selectedCount = _selected.length;
    final browseUnavailable =
        state.bundle.browse == null || result.scopeUnavailableReason != null;
    final activeView =
        _view == _CatalogView.favorites || _view == _CatalogView.recent;
    final viewChoices = _view == _CatalogView.favorites ? favorites : recent;
    final primaryViewChoices = viewChoices
        .where((c) => !result.secondaryVariantIds.contains(c.variantId))
        .toList();
    final primaryViewVariants = primaryViewChoices
        .where((c) => c.variantId != null)
        .toList();
    final primaryViewCustom = primaryViewChoices
        .where((c) => c.variantId == null)
        .toList();
    final secondaryViewChoices = viewChoices
        .where((c) => result.secondaryVariantIds.contains(c.variantId))
        .toList();
    final displayedSiblings = home
        ? recent
              .map((c) => state.bundle.variants[c.variantId])
              .whereType<CatalogVariant>()
              .toList()
        : activeView
        ? viewChoices
              .map((c) => state.bundle.variants[c.variantId])
              .whereType<CatalogVariant>()
              .toList()
        : direct
        ? visibleSiblings
        : [
                ...result.rows,
                ...result.suggested,
                ...result.secondaryRows,
                ...result.secondarySuggested,
              ]
              .map((h) => state.bundle.variants[h.variantId])
              .whereType<CatalogVariant>()
              .toList();

    Widget choiceRow(CatalogChoice choice, {List<CatalogVariant>? siblings}) {
      final count = _selected.where((c) => c.key == choice.key).length;
      final variant = state.bundle.variants[choice.variantId];
      final distinction = choice.setupId == 'default' && variant != null
          ? labels.distinction(
              variant,
              (siblings ?? displayedSiblings).where(
                (v) => v.familyId == variant.familyId,
              ),
            )
          : state.distinction(choice, _locale);
      final subtitle = <String>[
        if (distinction.isNotEmpty) distinction,
        if (widget.currentChoice?.key == choice.key) l.catalogCurrent,
        if (widget.inDayChoiceKeys.contains(choice.key)) l.catalogInDay,
      ].join(' · ');
      return CatalogPickerRow(
        key: ValueKey(choice.key),
        label: state.label(choice, _locale),
        subtitle: subtitle,
        selected: count > 0,
        count: count,
        onTap: () => _choose(choice),
        menuLabel: l.catalogDetails,
        onMenu: () => _details(choice),
      );
    }

    Widget hitRow(CatalogHit hit) => hit.isNavigation
        ? CatalogPickerRow(
            key: ValueKey('catalog-navigation-${hit.kind}-${hit.id}'),
            label: hit.label,
            subtitle: l.catalogMatchingExecutions(
              hit.admittedVariantIds?.length ?? 0,
            ),
            onTap: () => setState(() {
              _navigation = hit;
              _view = _CatalogView.all;
            }),
          )
        : choiceRow(CatalogChoice.variant(hit.id));

    Widget empty(String text) => Padding(
      key: const Key('catalog-empty'),
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            text,
            style: WorkoutType.body(size: 15, color: context.tokens.dim),
          ),
          if (_locale == 'de' || _locale == 'es') ...[
            const SizedBox(height: 8),
            Text(
              l.catalogMissingVocabulary,
              style: WorkoutType.body(size: 14, color: context.tokens.dim),
            ),
          ],
          Wrap(
            spacing: 8,
            children: [
              if (_search.text.isNotEmpty)
                TextButton(
                  onPressed: () => setState(_search.clear),
                  child: Text(l.catalogClearSearch),
                ),
              if (_group != null)
                TextButton(
                  onPressed: () => setState(() => _group = null),
                  child: Text(l.catalogClearGroup),
                ),
              if (_equipment != null)
                TextButton(
                  onPressed: () => setState(() => _equipment = null),
                  child: Text(l.catalogClearEquipment),
                ),
              if (_navigation != null)
                TextButton(
                  onPressed: () => setState(() => _navigation = null),
                  child: Text(l.catalogClearFamily),
                ),
              if (_view == _CatalogView.favorites)
                TextButton(
                  onPressed: () => setState(() => _view = _CatalogView.all),
                  child: Text(l.catalogClearFavorites),
                ),
            ],
          ),
        ],
      ),
    );

    return PopScope<List<CatalogChoice>>(
      canPop: _allowPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .94,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
                child: Row(
                  children: [
                    if (_navigation != null || _group != null)
                      IconButton(
                        key: const Key('catalog-back'),
                        tooltip: MaterialLocalizations.of(
                          context,
                        ).backButtonTooltip,
                        onPressed: _back,
                        icon: const Icon(Icons.arrow_back),
                      ),
                    Expanded(
                      child: FitLabel(
                        widget.setupIntent
                            ? l.catalogChangeSetup
                            : _navigation?.label ??
                                  (widget.familyId == null
                                      ? l.exerciseSheetTitle
                                      : index.labelFor(
                                          'family',
                                          widget.familyId!,
                                        )),
                        maxLines: 2,
                        style: WorkoutType.display(
                          size: 22,
                          color: context.tokens.text,
                        ),
                      ),
                    ),
                    IconButton(
                      key: const Key('catalog-close'),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      onPressed: _dismiss,
                      icon: const Icon(Icons.close),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  children: [
                    if (widget.setupIntent && widget.currentChoice != null) ...[
                      Text(
                        l.catalogCurrentSetup(
                          state.identifyingLabel(
                            widget.currentChoice!,
                            _locale,
                          ),
                        ),
                        style: WorkoutType.body(
                          size: 15,
                          color: context.tokens.text,
                        ),
                      ),
                      if (widget.currentChoice!.nickname?.isNotEmpty == true)
                        Text(
                          widget.currentChoice!.nickname!,
                          style: WorkoutType.body(
                            size: 14,
                            color: context.tokens.dim,
                          ),
                        ),
                      const SizedBox(height: 8),
                      Text(
                        l.catalogNewSetNotice,
                        style: WorkoutType.body(
                          size: 14,
                          color: context.tokens.dim,
                        ),
                      ),
                      const SizedBox(height: 12),
                    ],
                    TextField(
                      key: const Key('catalog-search'),
                      controller: _search,
                      focusNode: _searchFocus,
                      decoration: InputDecoration(
                        hintText: l.exerciseSheetSearchHint,
                        prefixIcon: const Icon(Icons.search),
                        suffixIcon: _search.text.isEmpty
                            ? null
                            : IconButton(
                                tooltip: l.catalogClearSearch,
                                onPressed: () => setState(_search.clear),
                                icon: const Icon(Icons.close),
                              ),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        key: const Key('catalog-create'),
                        onPressed: _create,
                        icon: const Icon(Icons.add),
                        label: Text(l.catalogCreate),
                        style: TextButton.styleFrom(
                          minimumSize: const Size(48, 48),
                        ),
                      ),
                    ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      children: [
                        FilterChip(
                          label: Text(l.catalogRecent),
                          selected: _view == _CatalogView.recent,
                          onSelected: (v) => setState(() {
                            _view = v ? _CatalogView.recent : _CatalogView.all;
                          }),
                        ),
                        FilterChip(
                          label: Text(l.catalogFavorites),
                          selected: _view == _CatalogView.favorites,
                          onSelected: (v) => setState(() {
                            _view = v
                                ? _CatalogView.favorites
                                : _CatalogView.all;
                          }),
                        ),
                        ActionChip(
                          key: const Key('catalog-all'),
                          label: Text(l.catalogAllAZ),
                          onPressed: () => setState(() {
                            _view = _CatalogView.all;
                          }),
                        ),
                        if (!home && !browseUnavailable)
                          ActionChip(
                            key: const Key('catalog-browse-muscles'),
                            label: Text(l.catalogBrowseMuscles),
                            onPressed: _pickGroup,
                          ),
                        if (groupLabel != null)
                          InputChip(
                            key: const Key('catalog-group-scope'),
                            label: Text(groupLabel),
                            onDeleted: () => setState(() => _group = null),
                            deleteButtonTooltipMessage: l.catalogClearGroup,
                          ),
                        if (_navigation != null && widget.familyId == null)
                          InputChip(
                            label: Text(_navigation!.label),
                            onDeleted: () => setState(() => _navigation = null),
                            deleteButtonTooltipMessage: l.catalogClearFamily,
                          ),
                      ],
                    ),
                    if (!home || _equipment != null) ...[
                      if (equipment.length > 1 || _equipment != null) ...[
                        _heading(l.catalogEquipment),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final kind in equipment)
                              FilterChip(
                                label: Text(labels.equipment(kind)),
                                selected: _equipment == kind,
                                onSelected: (v) => setState(
                                  () => _equipment = v ? kind : null,
                                ),
                              ),
                          ],
                        ),
                      ],
                      if (group?.kind == 'muscle')
                        SwitchListTile.adaptive(
                          key: const Key('catalog-secondary'),
                          contentPadding: EdgeInsets.zero,
                          title: Text(l.catalogIncludeSecondary),
                          value: _secondary,
                          onChanged: (v) => setState(() => _secondary = v),
                        ),
                    ],
                    if (browseUnavailable)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                        child: Text(
                          l.catalogBrowseUnavailable,
                          key: const Key('catalog-browse-unavailable'),
                          style: WorkoutType.body(
                            size: 14,
                            color: context.tokens.dim,
                          ),
                        ),
                      ),
                    if (result.groupActions.isNotEmpty) ...[
                      for (final action in result.groupActions)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          child: OutlinedButton.icon(
                            key: ValueKey(
                              'catalog-group-action-${action.groupKey}',
                            ),
                            onPressed: () =>
                                _openGroup(action.groupKey, replaceQuery: true),
                            icon: const Icon(Icons.arrow_forward),
                            label: Text(l.catalogBrowseGroup(action.label)),
                          ),
                        ),
                    ],
                    if (home) ...[
                      if (equipment.isNotEmpty)
                        ExpansionTile(
                          key: const Key('catalog-global-equipment'),
                          tilePadding: EdgeInsets.zero,
                          title: Text(l.catalogEquipment),
                          children: [
                            Wrap(
                              spacing: 8,
                              runSpacing: 4,
                              children: [
                                for (final kind in equipment)
                                  FilterChip(
                                    label: Text(labels.equipment(kind)),
                                    selected: _equipment == kind,
                                    onSelected: (v) => setState(
                                      () => _equipment = v ? kind : null,
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      if (recent.isNotEmpty) ...[
                        _heading(l.catalogRecent),
                        ...recent.map((c) => choiceRow(c)),
                      ],
                      _heading(l.catalogBrowseMuscles),
                      Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final g in index.browseGroups.where(
                            (g) => g.kind == 'muscle',
                          ))
                            ActionChip(
                              key: ValueKey('catalog-group-${g.key}'),
                              label: Text(index.groupLabel(g)),
                              onPressed: () => _openGroup(g.key),
                            ),
                        ],
                      ),
                      if (!browseUnavailable) ...[
                        _heading(l.catalogActivities),
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final g in index.browseGroups.where(
                              (g) => g.kind == 'activity',
                            ))
                              ActionChip(
                                key: ValueKey('catalog-group-${g.key}'),
                                label: Text(index.groupLabel(g)),
                                onPressed: () => _openGroup(g.key),
                              ),
                            ActionChip(
                              key: const Key('catalog-group-unclassified'),
                              label: Text(l.catalogUnclassified),
                              onPressed: () =>
                                  _openGroup(CatalogFilter.unclassified),
                            ),
                          ],
                        ),
                      ],
                    ] else if (activeView) ...[
                      _heading(
                        _view == _CatalogView.favorites
                            ? l.catalogFavorites
                            : l.catalogRecent,
                      ),
                      if (viewChoices.isEmpty)
                        empty(
                          _view == _CatalogView.favorites
                              ? l.catalogNoFavorites
                              : l.catalogNoRecents,
                        )
                      else ...[
                        if (group?.kind == 'muscle' &&
                            primaryViewVariants.isNotEmpty)
                          _heading(l.catalogTargetMatches),
                        ...primaryViewVariants.map((c) => choiceRow(c)),
                        if (primaryViewCustom.isNotEmpty) ...[
                          _heading(l.catalogPersonalExercises),
                          ...primaryViewCustom.map((c) => choiceRow(c)),
                        ],
                        if (secondaryViewChoices.isNotEmpty) ...[
                          _heading(l.catalogSecondaryMatches),
                          ...secondaryViewChoices.map((c) => choiceRow(c)),
                        ],
                      ],
                    ] else ...[
                      if (group?.kind == 'muscle')
                        _heading(l.catalogTargetMatches),
                      if (direct)
                        ...primaryVariants.map(
                          (v) => choiceRow(
                            CatalogChoice.variant(v.id),
                            siblings: visibleSiblings,
                          ),
                        )
                      else
                        ...result.rows.map(hitRow),
                      if (result.suggested.isNotEmpty) ...[
                        _heading(l.catalogSuggested),
                        if (direct)
                          ...primarySuggestions.map(
                            (v) => choiceRow(
                              CatalogChoice.variant(v.id),
                              siblings: visibleSiblings,
                            ),
                          )
                        else
                          ...result.suggested.map(hitRow),
                      ],
                      if (custom.isNotEmpty) ...[
                        _heading(l.catalogPersonalExercises),
                        ...custom.map((c) => choiceRow(c)),
                      ],
                      if (result.secondaryRows.isNotEmpty ||
                          result.secondarySuggested.isNotEmpty) ...[
                        _heading(l.catalogSecondaryMatches),
                        if (direct)
                          ...secondaryVariants.map(
                            (v) => choiceRow(
                              CatalogChoice.variant(v.id),
                              siblings: visibleSiblings,
                            ),
                          )
                        else
                          ...result.secondaryRows.map(hitRow),
                        if (result.secondarySuggested.isNotEmpty) ...[
                          _heading(l.catalogSuggested),
                          if (direct)
                            ...secondarySuggestions.map(
                              (v) => choiceRow(
                                CatalogChoice.variant(v.id),
                                siblings: visibleSiblings,
                              ),
                            )
                          else
                            ...result.secondarySuggested.map(hitRow),
                        ],
                      ],
                      if (primaryVariants.isEmpty &&
                          secondaryVariants.isEmpty &&
                          primarySuggestions.isEmpty &&
                          secondarySuggestions.isEmpty &&
                          custom.isEmpty)
                        empty(l.catalogNoResults),
                    ],
                  ],
                ),
              ),
              if (widget.multiple)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (selectedCount > 0) ...[
                          TextButton(
                            key: const Key('catalog-basket-toggle'),
                            onPressed: () => setState(
                              () => _basketExpanded = !_basketExpanded,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(l.catalogBasket(selectedCount)),
                                ),
                                Icon(
                                  _basketExpanded
                                      ? Icons.expand_less
                                      : Icons.expand_more,
                                ),
                              ],
                            ),
                          ),
                          if (_basketExpanded)
                            ConstrainedBox(
                              constraints: BoxConstraints(
                                maxHeight:
                                    ((MediaQuery.sizeOf(context).height * .94 -
                                                MediaQuery.viewInsetsOf(
                                                  context,
                                                ).bottom) *
                                            .22)
                                        .clamp(
                                          48.0,
                                          MediaQuery.sizeOf(context).height *
                                              .22,
                                        ),
                              ),
                              child: ListView(
                                key: const Key('catalog-basket-list'),
                                shrinkWrap: true,
                                children: [
                                  for (var i = 0; i < _selected.length; i++)
                                    Row(
                                      key: ValueKey('catalog-basket-$i'),
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            right: 8,
                                          ),
                                          child: Text(
                                            '${i + 1}',
                                            style: WorkoutType.mono(
                                              size: 14,
                                              color: context.tokens.dim,
                                            ),
                                          ),
                                        ),
                                        Expanded(
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                state.identifyingLabel(
                                                  _selected[i],
                                                  _locale,
                                                ),
                                                style: WorkoutType.body(
                                                  size: 14,
                                                  color: context.tokens.text,
                                                ),
                                              ),
                                              if (_selected[i]
                                                      .nickname
                                                      ?.isNotEmpty ==
                                                  true)
                                                Text(
                                                  _selected[i].nickname!,
                                                  style: WorkoutType.body(
                                                    size: 13,
                                                    color: context.tokens.dim,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                        IconButton(
                                          key: ValueKey(
                                            'catalog-basket-remove-$i',
                                          ),
                                          tooltip: l.catalogRemoveOccurrence(
                                            state.identifyingLabel(
                                              _selected[i],
                                              _locale,
                                            ),
                                            i + 1,
                                          ),
                                          onPressed: () => setState(
                                            () => _selected.removeAt(i),
                                          ),
                                          icon: const Icon(Icons.close),
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                            ),
                        ],
                        FilledButton(
                          key: const Key('catalog-add-selected'),
                          onPressed: _selected.isEmpty
                              ? null
                              : () => _pop(List<CatalogChoice>.of(_selected)),
                          child: Text(
                            '${l.catalogAddSelected} · $selectedCount',
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class CatalogPickerRow extends StatelessWidget {
  const CatalogPickerRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.onMenu,
    this.menuLabel,
    this.selected = false,
    this.count = 0,
  });
  final String label, subtitle;
  final VoidCallback onTap;
  final VoidCallback? onMenu;
  final String? menuLabel;
  final bool selected;
  final int count;
  @override
  Widget build(BuildContext context) => Material(
    color: context.tokens.surface,
    child: Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            selected: selected,
            label: [label, if (subtitle.isNotEmpty) subtitle].join(', '),
            value: selected
                ? AppLocalizations.of(context).catalogSelectedCount(count)
                : null,
            onTap: onTap,
            excludeSemantics: true,
            child: InkWell(
              onTap: onTap,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            FitLabel(
                              label,
                              maxLines: 3,
                              style: WorkoutType.body(
                                size: 16,
                                color: context.tokens.text,
                              ),
                            ),
                            if (subtitle.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: FitLabel(
                                  subtitle,
                                  maxLines: 3,
                                  style: WorkoutType.body(
                                    size: 13,
                                    color: context.tokens.dim,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      if (selected)
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: count > 1
                              ? Text(
                                  '$count',
                                  style: WorkoutType.mono(
                                    size: 16,
                                    color: context.tokens.accentText,
                                  ),
                                )
                              : Icon(
                                  Icons.check,
                                  color: context.tokens.accentText,
                                ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
        if (onMenu != null)
          IconButton(
            onPressed: onMenu,
            tooltip: menuLabel,
            icon: const Icon(Icons.more_horiz),
          ),
      ],
    ),
  );
}

class _CustomExerciseForm extends StatefulWidget {
  const _CustomExerciseForm({required this.query, required this.state});
  final String query;
  final CatalogTrialState state;
  @override
  State<_CustomExerciseForm> createState() => _CustomExerciseFormState();
}

class _CustomExerciseFormState extends State<_CustomExerciseForm> {
  late final _name = TextEditingController(text: widget.query);
  late String _profile = widget.state.bundle.measurementProfiles.keys.first;
  final _groups = <String>{};
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final index = widget.state.index(
      Localizations.localeOf(context).languageCode,
    );
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          20,
          16,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.catalogCreate,
              style: WorkoutType.display(size: 22, color: context.tokens.text),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('catalog-custom-name'),
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: l.catalogName),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              initialValue: _profile,
              isExpanded: true,
              isDense: false,
              itemHeight: null,
              decoration: InputDecoration(labelText: l.catalogMeasurement),
              items: [
                for (final profile
                    in widget.state.bundle.measurementProfiles.values)
                  DropdownMenuItem(
                    value: profile.key,
                    child: Text(
                      [
                        profile.requiredMetrics
                            .map((m) => catalogMetricLabel(l, m))
                            .join(' + '),
                        if (profile.optionalMetrics.isNotEmpty)
                          '${l.catalogOptional}: ${profile.optionalMetrics.map((m) => catalogMetricLabel(l, m)).join(', ')}',
                      ].join(' · '),
                    ),
                  ),
              ],
              onChanged: (v) {
                if (v != null) setState(() => _profile = v);
              },
            ),
            const SizedBox(height: 16),
            ExpansionTile(
              key: const Key('catalog-custom-groups'),
              tilePadding: EdgeInsets.zero,
              title: Text(l.catalogPersonalGroups),
              subtitle: Text(
                _groups.isEmpty
                    ? l.catalogUnclassified
                    : _groups
                          .map(
                            (g) => index.groupLabel(
                              widget.state.bundle.browse!.groups[g]!,
                            ),
                          )
                          .join(', '),
              ),
              children: [
                Text(
                  l.catalogPersonalGroupsHint,
                  style: WorkoutType.body(size: 14, color: context.tokens.dim),
                ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final g in index.browseGroups.where(
                      (g) => g.kind == 'muscle',
                    ))
                      FilterChip(
                        key: ValueKey('catalog-custom-group-${g.key}'),
                        label: Text(index.groupLabel(g)),
                        selected: _groups.contains(g.key),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _groups.add(g.key);
                          } else {
                            _groups.remove(g.key);
                          }
                        }),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _name.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      CatalogChoice.custom(
                        _name.text.trim(),
                        _profile,
                        personalGroups: _groups,
                      ),
                    ),
              child: Text(l.catalogAdd),
            ),
          ],
        ),
      ),
    );
  }
}

String catalogMetricLabel(AppLocalizations l, String metric) =>
    switch (metric) {
      'reported_load' => l.catalogLoad,
      'repetitions' => l.catalogRepetitions,
      'duration' => l.catalogDuration,
      'distance' => l.catalogDistance,
      _ => l.catalogMeasurement,
    };

Future<String?> showCatalogSetupNickname(BuildContext context) =>
    showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _SetupNicknameForm(),
    );

class _SetupNicknameForm extends StatefulWidget {
  const _SetupNicknameForm();
  @override
  State<_SetupNicknameForm> createState() => _SetupNicknameFormState();
}

class _SetupNicknameFormState extends State<_SetupNicknameForm> {
  final _name = TextEditingController();
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          20,
          16,
          20 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l.catalogNewMachine,
              style: WorkoutType.display(size: 22, color: context.tokens.text),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              autofocus: true,
              decoration: InputDecoration(labelText: l.catalogNickname),
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () => Navigator.pop(context, _name.text),
              child: Text(l.catalogUpcoming),
            ),
          ],
        ),
      ),
    );
  }
}
