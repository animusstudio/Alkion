import 'catalog_bundle.dart';
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
  });
  final String kind, id, key, label, recognizedQuery;

  /// 0 exact, 1 composed/browse, 2 prefix, 3 visible spelling suggestion.
  final int tier;
  bool get isNavigation => kind != 'variant';
  bool get corrected => tier == 3;
  String? get variantId => kind == 'variant' ? id : null;
}

class CatalogSearchResult {
  CatalogSearchResult({
    required this.status,
    required List<CatalogHit> strict,
    required List<CatalogHit> suggested,
    required List<String> corrections,
    required List<String> unresolvedTokens,
    required this.identity,
  }) : strict = List.unmodifiable(strict),
       suggested = List.unmodifiable(suggested),
       corrections = List.unmodifiable(corrections),
       unresolvedTokens = List.unmodifiable(unresolvedTokens);
  final String status, identity;
  final List<CatalogHit> strict, suggested;
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
    final effective = personalAliases
        .where(
          (a) =>
              profileId != null &&
              a.profileId == profileId &&
              !a.hidden &&
              a.locale == locale,
        )
        .toList();
    identity = catalogHash(
      catalogCanonicalJson([
        bundle.digest,
        bundle.searchRevision,
        catalogNormalizationPolicy,
        'labels-local-english-v1',
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
  }) => List.unmodifiable(
    bundle.variants.values.where(
      (v) => bundle.targetMatches(hit.kind, hit.id, v) && filter.matches(v),
    ),
  );

  String variantLabel(String id, {String query = ''}) =>
      labelFor('variant', id, query: query);

  String labelFor(String kind, String id, {String query = ''}) {
    final entity = bundle.entity(kind, id);
    if (entity == null) {
      throw ArgumentError.value(id, 'id', 'Unknown catalog entity');
    }
    final words = catalogNormalize(query).split(' ');
    final candidates = _labels.where((label) {
      final t = label.term;
      if (t.qualifier || t.source == 'scoped_terms') return false;
      if (!((kind == 'variant' && label.ids.contains(id)) ||
          (t.kind == kind && t.targetId == id))) {
        return false;
      }
      if (t.source == 'personal') return t.locale == locale;
      if (!_eligibleDisplay(t)) return false;
      return query.isNotEmpty && _contains(words, label.words);
    }).toList();
    candidates.sort((a, b) {
      final personalA = a.term.source == 'personal',
          personalB = b.term.source == 'personal';
      if (personalA != personalB) return personalA ? -1 : 1;
      final length = b.words.length.compareTo(a.words.length);
      if (length != 0) return length;
      final localA = a.term.locale == locale, localB = b.term.locale == locale;
      if (localA != localB) return localA ? -1 : 1;
      return a.term.id.compareTo(b.term.id);
    });
    if (candidates.isNotEmpty) return candidates.first.term.text;
    return entity.names[locale] ?? entity.names['en']!;
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

  CatalogSearchResult search(
    String query, {
    CatalogFilter filter = const CatalogFilter(),
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
        .where(filter.matches)
        .map((v) => v.id)
        .toSet();
    final allowed = _qualified(words, filtered),
        literalQualified = _qualified(words, filtered, includeAliases: false);
    final found = <String, _Ranked>{};
    void add(
      String kind,
      String id,
      int tier, {
      bool direct = false,
      bool canonical = false,
      List<String>? recognized,
    }) {
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
        if (t.kind == 'equipment_model' ||
            label.ids.intersection(allowed).isNotEmpty) {
          add(
            t.kind,
            t.targetId,
            0,
            direct: true,
            canonical: t.source == 'canonical',
          );
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
    return result(
      words.isEmpty || key.length == 1 ? 'browse' : 'ok',
      ordered.where((r) => r.hit.tier < 3).map((r) => r.hit).toList(),
      ordered.where((r) => r.hit.tier == 3).map((r) => r.hit).toList(),
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

bool _contains(List<String> words, List<String> phrase) {
  for (var i = 0; i <= words.length - phrase.length; i++) {
    var equal = true;
    for (var j = 0; j < phrase.length; j++) {
      if (words[i + j] != phrase[j]) {
        equal = false;
        break;
      }
    }
    if (equal) return true;
  }
  return false;
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
