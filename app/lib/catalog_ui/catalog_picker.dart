import 'package:flutter/material.dart';

import '../catalog/catalog.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';
import '../widgets/fit_label.dart';
import '../widgets/w_action_sheet.dart';
import 'catalog_trial_scope.dart';

/// Shared task-aware discovery; no catalog navigation item can escape as a
/// performed exercise. Multi selection retains explicit ordered occurrences.
Future<List<CatalogChoice>?> showCatalogPicker(
  BuildContext context, {
  required CatalogTrialState state,
  bool multiple = false,
  String? familyId,
}) => showModalBottomSheet<List<CatalogChoice>>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  backgroundColor: context.tokens.surface,
  barrierColor: context.tokens.overlay,
  sheetAnimationStyle: MediaQuery.disableAnimationsOf(context)
      ? AnimationStyle.noAnimation
      : null,
  builder: (_) =>
      CatalogPicker(state: state, multiple: multiple, familyId: familyId),
);

class CatalogPicker extends StatefulWidget {
  const CatalogPicker({
    super.key,
    required this.state,
    this.multiple = false,
    this.familyId,
  });
  final CatalogTrialState state;
  final bool multiple;
  final String? familyId;
  @override
  State<CatalogPicker> createState() => _CatalogPickerState();
}

class _CatalogPickerState extends State<CatalogPicker> {
  final _search = TextEditingController();
  final _selected = <CatalogChoice>[];
  final _scroll = ScrollController();
  String? _family, _equipment;
  CatalogHit? _navigation;
  bool _browse = false, _favorites = false;
  String get _locale => Localizations.localeOf(context).languageCode;
  @override
  void initState() {
    super.initState();
    _family = widget.familyId;
    _browse = _family != null;
  }

  @override
  void dispose() {
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _choose(CatalogChoice choice, {bool again = false}) {
    widget.state.remember(choice, locale: _locale, query: _search.text);
    if (!widget.multiple) {
      Navigator.pop(context, [choice]);
      return;
    }
    setState(() {
      if (again || !_selected.any((c) => c.key == choice.key)) {
        _selected.add(choice);
      }
    });
  }

  Future<void> _details(CatalogChoice choice) async {
    final l = AppLocalizations.of(context);
    final result = await showWActionSheet<String>(
      context,
      title: widget.state.label(choice, _locale, query: _search.text),
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
        WSheetAction(
          label:
              widget.state.bundle.variants[choice.variantId]?.muscleCoverage ==
                  'partial'
              ? CatalogLabels(_locale).partialMuscles
              : CatalogLabels(_locale).unknownMuscles,
          value: 'muscles',
          enabled: false,
        ),
      ],
    );
    if (!mounted) return;
    if (result == 'favorite') {
      setState(() => widget.state.toggleFavorite(choice));
    }
    if (result == 'again') _choose(choice, again: true);
    if (result == 'remove') {
      setState(
        () => _selected.removeAt(
          _selected.lastIndexWhere((c) => c.key == choice.key),
        ),
      );
    }
  }

  Future<void> _create() async {
    final choice = await showModalBottomSheet<CatalogChoice>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) =>
          _CustomExerciseForm(query: _search.text, state: widget.state),
    );
    if (mounted && choice != null) _choose(choice);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context), state = widget.state;
    final index = state.index(_locale), labels = CatalogLabels(_locale);
    final filter = CatalogFilter(
      familyIds: _family == null ? [] : [_family!],
      equipmentKinds: _equipment == null ? [] : [_equipment!],
    );
    final result = index.search(_search.text, filter: filter);
    // Equipment options come from the admitted choices before this chip's
    // own filter, so narrowing never removes the way to clear that choice.
    final familyFilter = CatalogFilter(
      familyIds: _family == null ? [] : [_family!],
    );
    final unfilteredVariants = _navigation == null
        ? null
        : index.variantsFor(_navigation!, filter: familyFilter);
    final List<CatalogVariant>? variants = unfilteredVariants
        ?.where(filter.matches)
        .toList();
    final admittedIds = <String>{
      for (final hit in result.strict)
        if (hit.variantId != null) hit.variantId!,
      for (final hit in result.strict.where((h) => h.isNavigation))
        ...index.variantsFor(hit, filter: filter).map((v) => v.id),
    };
    bool admitted(CatalogChoice choice) => choice.variantId == null
        ? _search.text.trim().isEmpty && _family == null && _equipment == null
        : admittedIds.contains(choice.variantId);
    final recent = state.recents.where(admitted).toList();
    final showRecent =
        _search.text.isEmpty && !_browse && _family == null && !_favorites;
    final favoriteChoices = state.choices.values
        .where((c) => state.favorites.contains(c.key) && admitted(c))
        .toList();
    final rows = variants == null ? result.rows : <CatalogHit>[];
    final variantChoices = variants
        ?.map((v) => CatalogChoice.variant(v.id))
        .toList();
    final equipment = <String>{
      ...?unfilteredVariants?.map((v) => v.equipmentKind),
      if (_equipment != null) _equipment!,
    }.toList();
    Widget choiceRow(CatalogChoice choice, {List<CatalogVariant>? siblings}) {
      final count = _selected.where((c) => c.key == choice.key).length;
      final variant = state.bundle.variants[choice.variantId];
      final distinction = siblings != null && variant != null
          ? labels.distinction(variant, siblings)
          : state.distinction(choice, _locale);
      return CatalogPickerRow(
        key: ValueKey(choice.key),
        label: state.label(choice, _locale, query: _search.text),
        subtitle: distinction,
        selected: count > 0,
        count: count,
        onTap: () => _choose(choice),
        menuLabel: l.catalogDetails,
        onMenu: () => _details(choice),
      );
    }

    return PopScope(
      canPop: _navigation == null,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) {
          setState(() {
            _navigation = null;
            _equipment = null;
          });
        }
      },
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * .88,
        child: Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: ListView(
                  controller: _scroll,
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                      child: Row(
                        children: [
                          if (_navigation != null)
                            IconButton(
                              tooltip: MaterialLocalizations.of(
                                context,
                              ).backButtonTooltip,
                              onPressed: () => setState(() {
                                _navigation = null;
                                _equipment = null;
                              }),
                              icon: const Icon(Icons.arrow_back),
                            ),
                          Expanded(
                            child: FitLabel(
                              _navigation?.label ?? l.exerciseSheetTitle,
                              maxLines: 2,
                              style: WorkoutType.display(
                                size: 22,
                                color: context.tokens.text,
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: MaterialLocalizations.of(
                              context,
                            ).closeButtonTooltip,
                            onPressed: () => Navigator.pop(context),
                            icon: const Icon(Icons.close),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: TextField(
                        key: const Key('catalog-search'),
                        controller: _search,
                        style: WorkoutType.body(
                          size: 16,
                          color: context.tokens.text,
                        ),
                        decoration: InputDecoration(
                          hintText: l.sessionSearchExercises,
                          prefixIcon: const Icon(Icons.search),
                          suffixIcon: _search.text.isEmpty
                              ? null
                              : IconButton(
                                  tooltip: MaterialLocalizations.of(
                                    context,
                                  ).clearButtonTooltip,
                                  onPressed: () => setState(() {
                                    _search.clear();
                                    _navigation = null;
                                    _equipment = null;
                                  }),
                                  icon: const Icon(Icons.close),
                                ),
                        ),
                        onChanged: (_) => setState(() {
                          _navigation = null;
                          _equipment = null;
                        }),
                      ),
                    ),
                    Padding(
                      padding: EdgeInsets.zero,
                      child: Wrap(
                        spacing: 8,
                        children: [
                          FilterChip(
                            label: Text(l.catalogFavorites),
                            selected: _favorites,
                            onSelected: (v) => setState(() {
                              _favorites = v;
                              _navigation = null;
                            }),
                          ),
                          if (_search.text.isEmpty && _family == null)
                            ActionChip(
                              label: Text(l.catalogBrowse),
                              onPressed: () => setState(() {
                                _browse = true;
                                _favorites = false;
                              }),
                            ),
                          if (equipment.length > 1 || _equipment != null)
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
                    ),
                    if (showRecent && recent.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          l.catalogRecent,
                          style: WorkoutType.body(
                            size: 13,
                            color: context.tokens.dim,
                          ),
                        ),
                      ),
                    if (showRecent) ...recent.map((c) => choiceRow(c)),
                    if (_favorites)
                      ...favoriteChoices.map((c) => choiceRow(c))
                    else if (!showRecent || recent.isEmpty) ...[
                      if (variantChoices != null)
                        ...variantChoices.map(
                          (c) => choiceRow(c, siblings: variants),
                        )
                      else
                        for (final hit in rows)
                          if (hit.isNavigation)
                            CatalogPickerRow(
                              label: hit.label,
                              subtitle: l.catalogChoose,
                              onTap: () => setState(() => _navigation = hit),
                            )
                          else
                            choiceRow(CatalogChoice.variant(hit.id)),
                      if (result.suggested.isNotEmpty && variants == null) ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          child: Text(
                            l.catalogSuggested,
                            style: WorkoutType.body(
                              size: 13,
                              color: context.tokens.dim,
                            ),
                          ),
                        ),
                        for (final hit in result.suggested)
                          if (hit.isNavigation)
                            CatalogPickerRow(
                              label: hit.label,
                              subtitle: '',
                              onTap: () => setState(() => _navigation = hit),
                            )
                          else
                            choiceRow(CatalogChoice.variant(hit.id)),
                      ],
                      if (rows.isEmpty &&
                          variantChoices == null &&
                          result.suggested.isEmpty)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            l.catalogNoResults,
                            style: WorkoutType.body(
                              size: 15,
                              color: context.tokens.dim,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 16),
                    TextButton.icon(
                      onPressed: _create,
                      icon: const Icon(Icons.add),
                      label: Text(l.catalogCreate),
                    ),
                  ],
                ),
              ),
              if (widget.multiple)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: FilledButton(
                      key: const Key('catalog-add-selected'),
                      onPressed: _selected.isEmpty
                          ? null
                          : () => Navigator.pop(
                              context,
                              List<CatalogChoice>.of(_selected),
                            ),
                      child: Text(
                        '${l.catalogAddSelected} · ${_selected.length}',
                      ),
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
  Widget build(BuildContext context) => Semantics(
    selected: selected,
    child: Material(
      color: context.tokens.surface,
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
                        : Icon(Icons.check, color: context.tokens.accentText),
                  ),
                if (onMenu != null)
                  IconButton(
                    onPressed: onMenu,
                    tooltip: menuLabel,
                    icon: const Icon(Icons.more_horiz),
                  ),
              ],
            ),
          ),
        ),
      ),
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
            FilledButton(
              onPressed: _name.text.trim().isEmpty
                  ? null
                  : () => Navigator.pop(
                      context,
                      CatalogChoice.custom(_name.text.trim(), _profile),
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
