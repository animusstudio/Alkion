import 'catalog_bundle.dart';
import 'catalog_labels.dart';
import 'catalog_normalize.dart';

export 'catalog_normalize.dart'
    show catalogNormalize, catalogNormalizationPolicy;

const _particles = <String>{
  'a',
  'al',
  'allo',
  'alla',
  'alle',
  'agli',
  'ai',
  'con',
  'contro',
  'da',
  'dal',
  'dalla',
  'dalle',
  'dall',
  'dei',
  'del',
  'della',
  'delle',
  'dell',
  'di',
  'e',
  'ed',
  'i',
  'il',
  'in',
  'la',
  'le',
  'lo',
  'on',
  'per',
  'su',
  'sul',
  'sulla',
  'sulle',
  'the',
  'to',
  'un',
  'una',
  'with',
  'and',
  'at',
  'of',
  'for',
  'from',
  'against',
};

class CatalogPersonalAlias {
  const CatalogPersonalAlias({
    required this.id,
    required this.profileId,
    required this.locale,
    required this.text,
    required this.kind,
    required this.targetId,
    this.hidden = false,
  });
  final String id, profileId, locale, text, kind, targetId;
  final bool hidden;
  Map<String, dynamic> toJson() => {
    'id': id,
    'profile_id': profileId,
    'locale': locale,
    'text': text,
    'kind': kind,
    'target_id': targetId,
  };
}

class CatalogHit {
  const CatalogHit({
    required this.kind,
    required this.id,
    required this.key,
    required this.tier,
    required this.label,
    required this.recognizedQuery,
    this.admittedVariantIds,
  });
  final String kind, id, key, label, recognizedQuery;

  /// Search-produced navigation pins its admitted children. Null is reserved
  /// for a caller-created unfiltered browse hit; an empty list admits nothing.
  final List<String>? admittedVariantIds;

  /// 0 exact, 1 composed/browse, 2 prefix, 3 visible spelling suggestion.
  final int tier;
  bool get isNavigation => kind != 'variant';
  bool get corrected => tier == 3;
  String? get variantId => kind == 'variant' ? id : null;
}

class CatalogGroupAction {
  const CatalogGroupAction({
    required this.groupKey,
    required this.label,
    required this.kind,
  });
  final String groupKey, label, kind;
}

class CatalogSearchResult {
  CatalogSearchResult({
    required this.status,
    required List<CatalogHit> strict,
    required List<CatalogHit> suggested,
    required List<String> corrections,
    required List<String> unresolvedTokens,
    required this.identity,
    List<CatalogHit> secondaryStrict = const [],
    List<CatalogHit> secondarySuggested = const [],
    List<CatalogGroupAction> groupActions = const [],
    this.scopeUnavailableReason,
  }) : secondaryStrict = List.unmodifiable(secondaryStrict),
       secondarySuggested = List.unmodifiable(secondarySuggested),
       groupActions = List.unmodifiable(groupActions),
       strict = List.unmodifiable(strict),
       suggested = List.unmodifiable(suggested),
       corrections = List.unmodifiable(corrections),
       unresolvedTokens = List.unmodifiable(unresolvedTokens);
  final String status, identity;
  final List<CatalogHit> strict, suggested, secondaryStrict, secondarySuggested;
  final List<CatalogGroupAction> groupActions;
  final String? scopeUnavailableReason;

  List<CatalogHit> get secondaryRows {
    final navigation = secondaryStrict.where((h) => h.isNavigation).toList();
    return List.unmodifiable(navigation.isEmpty ? secondaryStrict : navigation);
  }

  Set<String> _ids(Iterable<CatalogHit> hits) => Set.unmodifiable({
    for (final hit in hits)
      if (hit.variantId != null) hit.variantId! else ...?hit.admittedVariantIds,
  });
  Set<String> get variantIds => _ids(strict);
  Set<String> get secondaryVariantIds => _ids(secondaryStrict);
  bool admitsVariant(String id, {bool includeSuggestions = false}) =>
      variantIds.contains(id) ||
      secondaryVariantIds.contains(id) ||
      (includeSuggestions &&
          _ids([...suggested, ...secondarySuggested]).contains(id));
  final List<String> corrections, unresolvedTokens;

  /// Primary rows collapse broad family/collection navigation, while strict
  /// retains every execution for drill-down and independent parity checks.
  List<CatalogHit> get rows {
    final navigation = strict.where((h) => h.isNavigation).toList();
    return List.unmodifiable(navigation.isEmpty ? strict : navigation);
  }
}

class _Label {
  _Label(this.term, this.ids) : words = catalogNormalize(term.text).split(' ');
  final CatalogTerm term;
  final Set<String> ids;
  final List<String> words;
  String get key => words.join(' ');
}

class _Scope {
  final scope = <String>{}, admitted = <String>{};
}

class _Ranked {
  _Ranked(this.hit, this.rank);
  final CatalogHit hit;
  final List<Comparable<dynamic>> rank;
}

/// Immutable, synchronous offline index. Construct a new snapshot on a profile,
/// locale, bundle or effective personal vocabulary change; identity fences async
/// callers without a global cache or recents shared between profiles.
class CatalogIndex {
  CatalogIndex(
    this.bundle, {
    this.locale = 'en',
    this.profileId,
    List<CatalogPersonalAlias> personalAliases = const [],
  }) {
    final effective =
        personalAliases
            .where(
              (a) => profileId != null && a.profileId == profileId && !a.hidden,
            )
            .toList()
          ..sort((a, b) {
            final localA = a.locale == locale, localB = b.locale == locale;
            if (localA != localB) return localA ? -1 : 1;
            return a.id.compareTo(b.id);
          });
    for (final alias in effective) {
      _personalNames.putIfAbsent(
        '${alias.kind}:${alias.targetId}',
        () => alias.text,
      );
    }
    identity = catalogHash(
      catalogCanonicalJson([
        bundle.digest,
        bundle.searchRevision,
        bundle.browse?.digest,
        bundle.browse?.classificationRevision,
        bundle.browseUnavailableReason,
        catalogNormalizationPolicy,
        'labels-stable-identity-v2',
        locale,
        profileId,
        effective.map((a) => a.toJson()).toList(),
      ]),
    );
    for (final v in bundle.variants.values) {
      (_familyMembers[v.familyId] ??= <String>{}).add(v.id);
    }
    final terms = <CatalogTerm>[];
    for (final kind in ['family', 'variant', 'collection', 'equipment_model']) {
      final entities = switch (kind) {
        'family' => bundle.families.values,
        'variant' => bundle.variants.values,
        'collection' => bundle.collections.values,
        _ => bundle.equipmentModels.values,
      };
      for (final e in entities) {
        for (final name in e.names.entries) {
          terms.add(
            CatalogTerm(
              id: 'canonical:$kind:${e.id}:${name.key}',
              text: name.value,
              locale: name.key,
              kind: kind,
              targetId: e.id,
              source: 'canonical',
            ),
          );
        }
      }
    }
    terms.addAll(bundle.terms);
    for (final alias in effective) {
      if (alias.locale != locale) continue;
      terms.add(
        CatalogTerm(
          id: alias.id,
          text: alias.text,
          locale: alias.locale,
          kind: alias.kind,
          targetId: alias.targetId,
          source: 'personal',
        ),
      );
    }
    for (final term in terms) {
      if (term.locale != 'en' && term.locale != locale) continue;
      if (bundle.entity(term.kind, term.targetId) == null) {
        throw const CatalogFormatException('Personal alias target unavailable');
      }
      final ids = _targetIds(
        term.kind,
        term.targetId,
      ).where((id) => term.selector.matches(bundle.variants[id]!)).toSet();
      final label = _Label(term, ids);
      _labels.add(label);
      (_exact[label.key] ??= <_Label>[]).add(label);
      if ((term.source == 'aliases' || term.source == 'personal') &&
          (term.hasSelector || term.kind == 'variant')) {
        final scope = _aliasScopes[label.key] ??= _Scope();
        final familyIds = term.kind == 'family'
            ? {term.targetId}
            : _targetIds(
                term.kind,
                term.targetId,
              ).map((id) => bundle.variants[id]!.familyId).toSet();
        for (final id in familyIds) {
          scope.scope.addAll(_familyMembers[id] ?? {});
        }
        scope.admitted.addAll(ids);
      }
      if (term.source != 'scoped_terms' &&
          !term.qualifier &&
          !{'bench', 'panca'}.contains(label.key) &&
          term.kind != 'equipment_model') {
        (_anchors[label.key] ??= <String>{}).addAll(ids);
        final movement = _semanticKey(label.words);
        (_movementAnchors[movement] ??= <String>{}).addAll(ids);
        if (term.source == 'canonical' && term.kind == 'variant') {
          (_canonicalWords[movement] ??= <String>{}).addAll(ids);
        }
      }
      var tokenIds = ids;
      if (term.qualifier) {
        tokenIds = term.kind == 'variant'
            ? ids
            : bundle.variants.values
                  .where(term.selector.matches)
                  .map((v) => v.id)
                  .toSet();
        (_qualifiers[label.key] ??= <String>{}).addAll(tokenIds);
      }
      for (final word in label.words) {
        (_tokens[word] ??= <String>{}).addAll(tokenIds);
      }
    }
  }
  final CatalogBundle bundle;
  final String locale;
  final String? profileId;
  late final String identity;
  final _familyMembers = <String, Set<String>>{};
  final _labels = <_Label>[];
  final _personalNames = <String, String>{};
  final _displayNames = <String, String>{};
  final _identifyingNames = <String, String>{};
  final _tokens = <String, Set<String>>{},
      _anchors = <String, Set<String>>{},
      _movementAnchors = <String, Set<String>>{},
      _canonicalWords = <String, Set<String>>{},
      _qualifiers = <String, Set<String>>{};
  final _aliasScopes = <String, _Scope>{};
  final _exact = <String, List<_Label>>{};

  Set<String> _targetIds(String kind, String id) => bundle.variants.values
      .where((v) => bundle.targetMatches(kind, id, v))
      .map((v) => v.id)
      .toSet();

  List<CatalogVariant> variantsFor(
    CatalogHit hit, {
    CatalogFilter filter = const CatalogFilter(),
  }) {
    final admitted = hit.admittedVariantIds;
    final candidates = admitted == null
        ? bundle.variants.values
        : admitted.map((id) => bundle.variants[id]).whereType<CatalogVariant>();
    final variants = candidates
        .where(
          (v) =>
              bundle.targetMatches(hit.kind, hit.id, v) &&
              filter.matches(v, browse: bundle.browse),
        )
        .toList();
    if (admitted == null) {
      variants.sort((a, b) => compareVariants(a.id, b.id));
    }
    return List.unmodifiable(variants);
  }

  int compareVariants(String a, String b) {
    final left = variantLabel(a), right = variantLabel(b);
    final normalized = catalogNormalize(
      left,
    ).compareTo(catalogNormalize(right));
    if (normalized != 0) return normalized;
    final displayed = left.compareTo(right);
    return displayed != 0 ? displayed : a.compareTo(b);
  }

  String variantLabel(String id, {String query = ''}) =>
      labelFor('variant', id, query: query);

  String labelFor(String kind, String id, {String query = ''}) =>
      _displayNames.putIfAbsent('$kind:$id', () => _stableLabel(kind, id));

  String _stableLabel(String kind, String id) {
    final entity = bundle.entity(kind, id);
    if (entity == null) {
      throw ArgumentError.value(id, 'id', 'Unknown catalog entity');
    }
    final canonical = entity.names[locale] ?? entity.names['en']!;
    // Vocabulary admits results; it must never turn the query into their name.
    // Personal names retain their exact text across interface locale changes.
    final personal = _personalNames['$kind:$id'];
    if (personal != null) return personal;
    if (kind != 'variant') return canonical;
    final variant = bundle.variants[id]!;
    final candidates = _labels.where((label) {
      final t = label.term;
      if (t.qualifier ||
          t.source == 'canonical' ||
          t.source == 'personal' ||
          t.source == 'scoped_terms' ||
          !_eligibleDisplay(t) ||
          !label.ids.contains(id)) {
        return false;
      }
      final direct = t.kind == 'variant' && t.targetId == id;
      // RDL is an established familiar term across the supported locales.
      // Other broad acronyms/aliases remain retrieval-only vocabulary.
      final familiarAcronym =
          t.kind == 'family' &&
          t.targetId == variant.familyId &&
          t.text == 'RDL';
      return direct || familiarAcronym;
    }).toList();
    candidates.sort((a, b) {
      final localA = a.term.locale == locale, localB = b.term.locale == locale;
      if (localA != localB) return localA ? -1 : 1;
      final length = b.words.length.compareTo(a.words.length);
      if (length != 0) return length;
      return a.term.id.compareTo(b.term.id);
    });
    if (candidates.isEmpty) return canonical;
    final familiar = candidates.first.term.text;
    return catalogNormalize(familiar) == catalogNormalize(canonical)
        ? canonical
        : familiar;
  }

  /// A self-contained execution name for surfaces without a separate subtitle.
  /// Picker rows use variantLabel plus distinctions among their visible siblings.
  String identifyingVariantLabel(String id) =>
      _identifyingNames.putIfAbsent(id, () => _identifyingLabel(id));

  String _identifyingLabel(String id) {
    final label = variantLabel(id);
    if (_personalNames.containsKey('variant:$id')) return label;
    final variant = bundle.variants[id]!;
    final siblings = bundle.variants.values
        .where((v) => variantLabel(v.id) == label)
        .toList();
    if (siblings.length == 1) return label;
    final distinction = CatalogLabels(locale).distinction(variant, siblings);
    if (distinction.isEmpty) {
      return variant.names[locale] ?? variant.names['en']!;
    }
    final matching = siblings.where(
      (v) => CatalogLabels(locale).distinction(v, siblings) == distinction,
    );
    // Missing or identical dimensions cannot justify a fabricated distinction.
    if (matching.length > 1) {
      return variant.names[locale] ?? variant.names['en']!;
    }
    return '$label · $distinction';
  }

  bool _eligibleDisplay(CatalogTerm t) {
    if (t.locale == locale) return true;
    if (t.locale != 'en') return false;
    // Local canonical names take precedence. English aliases may be displayed
    // internationally only when reviewed explicitly or an uppercase acronym.
    return locale == 'en' ||
        t.displayLocales.contains(locale) ||
        (t.source != 'canonical' &&
            RegExp(r'^[A-Z][A-Z0-9]{1,7}$').hasMatch(t.text));
  }

  Set<String> _intent(List<String> words) {
    final spans = <Set<String>>[];
    var pos = 0;
    while (pos < words.length) {
      final qualifier = _longest(words, pos, _qualifiers);
      if (qualifier != null) {
        spans.add(_qualifiers[qualifier]!);
        pos += qualifier.split(' ').length;
        continue;
      }
      final anchor = _longest(words, pos, _anchors);
      if (anchor != null) {
        spans.add(_anchors[anchor]!);
        pos += anchor.split(' ').length;
        continue;
      }
      if (!_particles.contains(words[pos])) {
        spans.add(_tokens[words[pos]] ?? {});
      }
      pos++;
    }
    var intent = _intersect(spans);
    if (intent.isEmpty && spans.isNotEmpty) {
      intent = _intersect(
        words
            .where((w) => !_particles.contains(w))
            .map((w) => _tokens[w] ?? {}),
      );
    }
    var longest = 0;
    final anchored = <String>{};
    final queryCounts = _counts(words.where((w) => !_particles.contains(w)));
    for (final entry in _movementAnchors.entries) {
      final keys = entry.key.split(' ');
      if (entry.key.isEmpty ||
          !_counts(
            keys,
          ).entries.every((e) => (queryCounts[e.key] ?? 0) >= e.value)) {
        continue;
      }
      if (keys.length > longest) {
        anchored.clear();
        longest = keys.length;
      }
      if (keys.length == longest) anchored.addAll(entry.value);
    }
    if (anchored.isNotEmpty) {
      final families = anchored
          .map((id) => bundle.variants[id]!.familyId)
          .toSet();
      intent = intent
          .where((id) => families.contains(bundle.variants[id]!.familyId))
          .toSet();
    }
    return intent;
  }

  Set<String> _qualified(
    List<String> words,
    Set<String> original, {
    bool includeAliases = true,
  }) {
    var allowed = Set<String>.of(original), pos = 0;
    while (pos < words.length) {
      final phrase = _longest(words, pos, _qualifiers);
      if (phrase != null) {
        allowed = allowed.intersection(_qualifiers[phrase]!);
        pos += phrase.split(' ').length;
      } else {
        pos++;
      }
    }
    if (!includeAliases) return allowed;
    final familyScope = <String>{};
    for (final label in _exact[words.join(' ')] ?? <_Label>[]) {
      if (label.term.source == 'canonical' && label.term.kind == 'family') {
        familyScope.addAll(_familyMembers[label.term.targetId] ?? {});
      }
    }
    final exactIds = _canonicalWords[_semanticKey(words)] ?? <String>{};
    pos = 0;
    while (pos < words.length) {
      final phrase = _longest(words, pos, _aliasScopes);
      if (phrase != null) {
        final scope = _aliasScopes[phrase]!;
        allowed.removeAll(
          scope.scope
              .difference(scope.admitted)
              .difference(familyScope)
              .difference(exactIds),
        );
        pos += phrase.split(' ').length;
      } else {
        pos++;
      }
    }
    return allowed;
  }

  List<CatalogBrowseGroup> get browseGroups {
    final groups =
        bundle.browse?.groups.values.toList() ?? <CatalogBrowseGroup>[];
    groups.sort((a, b) {
      final order = catalogNormalize(
        groupLabel(a),
      ).compareTo(catalogNormalize(groupLabel(b)));
      return order != 0 ? order : a.key.compareTo(b.key);
    });
    return List.unmodifiable(groups);
  }

  String groupLabel(CatalogBrowseGroup group) =>
      group.names[locale] ?? group.names['en']!;

  String? scopeUnavailableReason(CatalogFilter filter) {
    if (filter.groupKey == null) return null;
    if (bundle.browse == null) {
      return bundle.browseUnavailableReason ?? 'missing';
    }
    if (filter.groupKey != CatalogFilter.unclassified &&
        !bundle.browse!.groups.containsKey(filter.groupKey)) {
      return 'unsupported_group';
    }
    return null;
  }

  List<CatalogGroupAction> groupActions(String query) {
    final key = catalogNormalize(query);
    if (key.isEmpty) return const [];
    return List.unmodifiable([
      for (final group in browseGroups)
        if ([
          group.names[locale],
          ...?group.synonyms[locale],
        ].whereType<String>().any((name) => catalogNormalize(name) == key))
          CatalogGroupAction(
            groupKey: group.key,
            label: groupLabel(group),
            kind: group.kind,
          ),
    ]);
  }

  /// Useful for favorites/recents without a second, less restrictive matcher.
  bool matchesVariant(
    String id, {
    String query = '',
    CatalogFilter filter = const CatalogFilter(),
    bool includeSuggestions = false,
  }) => search(
    query,
    filter: filter,
  ).admitsVariant(id, includeSuggestions: includeSuggestions);

  /// Remove only the equipment constraint: selected scope, query and family stay.
  List<String> availableEquipment(
    String query, {
    CatalogFilter filter = const CatalogFilter(),
  }) {
    final result = search(
      query,
      filter: filter.copyWith(equipmentKinds: const []),
    );
    final kinds = <String>{
      for (final id in {...result.variantIds, ...result.secondaryVariantIds})
        bundle.variants[id]!.equipmentKind,
    }.toList();
    kinds.sort((a, b) {
      final order = catalogNormalize(
        CatalogLabels(locale).equipment(a),
      ).compareTo(catalogNormalize(CatalogLabels(locale).equipment(b)));
      return order != 0 ? order : a.compareTo(b);
    });
    return List.unmodifiable(kinds);
  }

  /// Custom groups are explicit personal choices, never inferred anatomy facts.
  bool matchesCustomName(
    String name, {
    String query = '',
    CatalogFilter filter = const CatalogFilter(),
    Set<String> personalGroups = const {},
  }) {
    if (filter.familyIds.isNotEmpty ||
        filter.equipmentKinds.isNotEmpty ||
        filter.facets.isNotEmpty ||
        filter.excludedFacets.isNotEmpty ||
        scopeUnavailableReason(filter) != null) {
      return false;
    }
    final group = filter.groupKey;
    if (group == CatalogFilter.unclassified && personalGroups.isNotEmpty) {
      return false;
    }
    if (group != null &&
        group != CatalogFilter.unclassified &&
        !personalGroups.contains(group)) {
      return false;
    }
    return catalogNormalize(name).contains(catalogNormalize(query));
  }

  CatalogSearchResult search(
    String query, {
    CatalogFilter filter = const CatalogFilter(),
  }) {
    final primary = _search(
      query,
      filter: filter.copyWith(includeSecondary: false),
    );
    final secondary = filter.includeSecondary && filter.groupKey != null
        ? _search(query, filter: filter, secondaryOnly: true)
        : null;
    final unavailable = scopeUnavailableReason(filter);
    return CatalogSearchResult(
      status: unavailable == null ? primary.status : 'browse_unavailable',
      strict: primary.strict,
      suggested: primary.suggested,
      secondaryStrict: secondary?.strict ?? const [],
      secondarySuggested: secondary?.suggested ?? const [],
      groupActions: groupActions(query),
      scopeUnavailableReason: unavailable,
      corrections: {...primary.corrections, ...?secondary?.corrections}.toList()
        ..sort(),
      unresolvedTokens: primary.unresolvedTokens,
      identity: catalogHash(
        catalogCanonicalJson([identity, query, filter.toJson()]),
      ),
    );
  }

  CatalogSearchResult _search(
    String query, {
    CatalogFilter filter = const CatalogFilter(),
    bool secondaryOnly = false,
  }) {
    final key = catalogNormalize(query),
        words = catalogNormalize(
          query,
        ).split(' ').where((w) => w.isNotEmpty).toList();
    final resultIdentity = catalogHash(
      catalogCanonicalJson([identity, query, filter.toJson()]),
    );
    final unresolved = words
        .where((w) => !_tokens.containsKey(w) && !_particles.contains(w))
        .toList();
    CatalogSearchResult result(
      String status,
      List<CatalogHit> strict,
      List<CatalogHit> suggested,
      List<String> corrections,
    ) => CatalogSearchResult(
      status: status,
      strict: strict,
      suggested: suggested,
      corrections: corrections,
      unresolvedTokens: unresolved,
      identity: resultIdentity,
    );
    if (query.length > 200 || words.length > 12) {
      return result('input_limit', [], [], []);
    }
    final filtered = bundle.variants.values
        .where(
          (v) => filter.matches(
            v,
            browse: bundle.browse,
            secondaryOnly: secondaryOnly,
          ),
        )
        .map((v) => v.id)
        .toSet();
    final allowed = _qualified(words, filtered),
        literalQualified = _qualified(words, filtered, includeAliases: false);
    final found = <String, _Ranked>{};
    final navigationAdmission = <String, Set<String>>{};
    void add(
      String kind,
      String id,
      int tier, {
      bool direct = false,
      bool canonical = false,
      List<String>? recognized,
      Set<String>? admitted,
    }) {
      if (kind != 'variant') {
        (navigationAdmission['$kind:$id'] ??= <String>{}).addAll(
          admitted ?? _targetIds(kind, id).intersection(allowed),
        );
      }
      final e = bundle.entity(kind, id)!;
      final recognizedQuery = (recognized ?? words).join(' ');
      final row = _Ranked(
        CatalogHit(
          kind: kind,
          id: id,
          key: e.key,
          tier: tier,
          label: labelFor(kind, id, query: recognizedQuery),
          recognizedQuery: recognizedQuery,
        ),
        [
          tier,
          direct ? 0 : 1,
          canonical ? 0 : 1,
          if (words.isEmpty || key.length == 1) ...[
            catalogNormalize(labelFor(kind, id)),
            labelFor(kind, id),
          ] else
            e is CatalogVariant ? e.facets.length : 0,
          id,
        ],
      );
      final old = found['$kind:$id'];
      if (old == null || _compare(row.rank, old.rank) < 0) {
        found['$kind:$id'] = row;
      }
    }

    final corrections = <String>{};
    if (words.isEmpty || key.length == 1) {
      for (final f in bundle.families.values) {
        if ((_familyMembers[f.id] ?? {}).intersection(allowed).isNotEmpty) {
          add('family', f.id, 1, direct: true);
        }
      }
    } else {
      for (final label in _exact[key] ?? <_Label>[]) {
        final t = label.term;
        if (t.kind == 'equipment_model' &&
            catalogLiteralKey(t.text) != catalogLiteralKey(query)) {
          continue;
        }
        final unscopedModel =
            t.kind == 'equipment_model' &&
            filter.groupKey == null &&
            !secondaryOnly &&
            filter.familyIds.isEmpty &&
            filter.equipmentKinds.isEmpty &&
            filter.facets.isEmpty &&
            filter.excludedFacets.isEmpty;
        if (unscopedModel || label.ids.intersection(allowed).isNotEmpty) {
          // A scoped term's target is an editorial vocabulary carrier, not
          // permission to navigate to every execution in that family.
          if (t.kind == 'variant' ||
              (!t.qualifier && t.source != 'scoped_terms')) {
            add(
              t.kind,
              t.targetId,
              0,
              direct: true,
              canonical: t.source == 'canonical',
              admitted: label.ids.intersection(allowed),
            );
          }
          for (final id in label.ids.intersection(allowed)) {
            add('variant', id, 1);
          }
        }
      }
      final intent = _intent(words);
      for (final id in intent.intersection(allowed)) {
        add('variant', id, 1);
      }
      final last = words.last;
      final prefixable =
          !_tokens.containsKey(last) ||
          (intent.isEmpty &&
              !_anchors.containsKey(last) &&
              !_qualifiers.containsKey(last));
      if (last.length >= 2 && prefixable) {
        for (final completion in _tokens.keys) {
          if (completion == last || !completion.startsWith(last)) continue;
          final completed = [...words.take(words.length - 1), completion];
          for (final id in _intent(
            completed,
          ).intersection(_qualified(completed, literalQualified))) {
            add('variant', id, 2, recognized: completed);
          }
        }
      }
      final unknown = [
        for (var i = 0; i < words.length; i++)
          if (!_tokens.containsKey(words[i])) i,
      ];
      if (unknown.isNotEmpty &&
          unknown.length <= 2 &&
          unknown.every(
            (i) =>
                words[i].length > 3 && RegExp(r'^[a-z]+$').hasMatch(words[i]),
          )) {
        final choices = <List<(String, int)>>[];
        for (final i in unknown) {
          final word = words[i], budget = words[i].length < 8 ? 1 : 2;
          final options = <(String, int)>[];
          for (final candidate in _tokens.keys) {
            if ((word.length - candidate.length).abs() > budget) continue;
            final distance = _distance(word, candidate);
            if (distance <= budget) options.add((candidate, distance));
          }
          choices.add(options);
        }
        void visit(int n, List<(String, int)> chosen) {
          if (n < choices.length) {
            for (final choice in choices[n]) {
              visit(n + 1, [...chosen, choice]);
            }
            return;
          }
          if (chosen.fold<int>(0, (sum, e) => sum + e.$2) > 2) return;
          final corrected = List<String>.of(words);
          for (var i = 0; i < unknown.length; i++) {
            corrected[unknown[i]] = chosen[i].$1;
          }
          final ids = _intent(
            corrected,
          ).intersection(_qualified(corrected, literalQualified));
          if (ids.isNotEmpty) corrections.add(corrected.join(' '));
          for (final id in ids) {
            add('variant', id, 3, recognized: corrected);
          }
        }

        visit(0, []);
      }
    }
    final ordered = found.values.toList()
      ..sort((a, b) => _compare(a.rank, b.rank));
    CatalogHit pinNavigation(_Ranked ranked) {
      final hit = ranked.hit;
      if (!hit.isNavigation) return hit;
      final admitted = navigationAdmission['${hit.kind}:${hit.id}']!;
      // Drill-down preserves concrete result ranking; browse children follow
      // their displayed labels, independently of incidental bundle/UUID order.
      final children = ordered
          .where((r) => r.hit.kind == 'variant' && admitted.contains(r.hit.id))
          .map((r) => r.hit.id)
          .toList();
      if (children.isEmpty) {
        children.addAll(bundle.variants.keys.where(admitted.contains));
        children.sort(compareVariants);
      }
      return CatalogHit(
        kind: hit.kind,
        id: hit.id,
        key: hit.key,
        tier: hit.tier,
        label: hit.label,
        recognizedQuery: hit.recognizedQuery,
        admittedVariantIds: List.unmodifiable(children),
      );
    }

    return result(
      words.isEmpty || key.length == 1 ? 'browse' : 'ok',
      ordered.where((r) => r.hit.tier < 3).map(pinNavigation).toList(),
      ordered.where((r) => r.hit.tier == 3).map(pinNavigation).toList(),
      corrections.toList()..sort(),
    );
  }
}

String _semanticKey(Iterable<String> words) =>
    (words.where((w) => !_particles.contains(w)).toList()..sort()).join(' ');
Map<String, int> _counts(Iterable<String> words) {
  final result = <String, int>{};
  for (final w in words) {
    result[w] = (result[w] ?? 0) + 1;
  }
  return result;
}

String? _longest(List<String> words, int pos, Map<String, dynamic> map) {
  for (var end = words.length; end > pos; end--) {
    final phrase = words.sublist(pos, end).join(' ');
    if (map.containsKey(phrase)) return phrase;
  }
  return null;
}

Set<String> _intersect(Iterable<Set<String>> spans) {
  final iterator = spans.iterator;
  if (!iterator.moveNext()) return {};
  var result = Set<String>.of(iterator.current);
  while (iterator.moveNext()) {
    result = result.intersection(iterator.current);
  }
  return result;
}

int _compare(List<Comparable<dynamic>> a, List<Comparable<dynamic>> b) {
  for (var i = 0; i < a.length; i++) {
    final value = a[i].compareTo(b[i]);
    if (value != 0) return value;
  }
  return 0;
}

int _distance(String a, String b) {
  final grid = List.generate(
    a.length + 1,
    (i) => List.generate(
      b.length + 1,
      (j) => i == 0
          ? j
          : j == 0
          ? i
          : 0,
    ),
  );
  for (var i = 1; i <= a.length; i++) {
    for (var j = 1; j <= b.length; j++) {
      var value = grid[i - 1][j] + 1;
      for (final other in [
        grid[i][j - 1] + 1,
        grid[i - 1][j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1),
      ]) {
        if (other < value) value = other;
      }
      if (i > 1 &&
          j > 1 &&
          a[i - 1] == b[j - 2] &&
          a[i - 2] == b[j - 1] &&
          grid[i - 2][j - 2] + 1 < value) {
        value = grid[i - 2][j - 2] + 1;
      }
      grid[i][j] = value;
    }
  }
  return grid[a.length][b.length];
}
