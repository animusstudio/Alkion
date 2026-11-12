import 'package:flutter/material.dart';

import '../domain/catalog_execution.dart';
import '../domain/evidence.dart';
import '../l10n/app_localizations.dart';
import '../theme/app_theme.dart';
import '../theme/typography.dart';

/// The role of one run of a compact catalog set: a measured number, its unit
/// (or the "reps" word), or the separator between them.
enum CatalogSetRunRole { value, unit, separator }

/// One styled run of a compact catalog set.
typedef CatalogSetRun = ({String text, CatalogSetRunRole role});

const _load = 'reported_load';
const _reps = 'repetitions';

/// The compact form of a typed set as styled runs, in the profile's metric
/// order with load and reps joined into one `18 kg × 12` group where the first
/// of them sits. Only valid metrics are shown; values and units are the stored
/// text, never converted or rounded. Empty when no metric is valid.
List<CatalogSetRun> catalogSetRuns(
  CatalogSetEvidence evidence,
  AppLocalizations l,
) {
  String? valid(String metric) {
    final quantity = evidence.metrics[metric];
    if (quantity == null || quantity.state != ValueState.valid) return null;
    final raw = quantity.raw;
    return raw is String && raw.isNotEmpty ? raw : null;
  }

  CatalogSetRun value(String text) =>
      (text: text, role: CatalogSetRunRole.value);
  CatalogSetRun unit(String text) => (text: text, role: CatalogSetRunRole.unit);
  CatalogSetRun separator(String text) =>
      (text: text, role: CatalogSetRunRole.separator);

  List<CatalogSetRun> withUnit(String raw, String metric) => [
    value(raw),
    unit(' ${evidence.metrics[metric]!.unit}'),
  ];

  final load = valid(_load);
  final reps = valid(_reps);
  final groups = <List<CatalogSetRun>>[];
  var loadRepsDone = false;
  for (final metric in evidence.selection.profile.metrics) {
    if (metric == _load || metric == _reps) {
      if (loadRepsDone) continue;
      if (load == null && reps == null) continue;
      loadRepsDone = true;
      if (load != null && reps != null) {
        groups.add([...withUnit(load, _load), separator(' × '), value(reps)]);
      } else if (load != null) {
        groups.add(withUnit(load, _load));
      } else {
        groups.add(_repsRuns(l, reps!));
      }
      continue;
    }
    final raw = valid(metric);
    if (raw != null) groups.add(withUnit(raw, metric));
  }
  return [
    for (var i = 0; i < groups.length; i++) ...[
      if (i > 0) separator(' · '),
      ...groups[i],
    ],
  ];
}

/// `12 reps`, localized, with the stored digits as the value run and the
/// words around them as unit runs.
List<CatalogSetRun> _repsRuns(AppLocalizations l, String raw) {
  final text = l.catalogRepsCompact(int.tryParse(raw) ?? 0, raw);
  final at = text.indexOf(raw);
  if (at < 0) return [(text: text, role: CatalogSetRunRole.value)];
  return [
    if (at > 0) (text: text.substring(0, at), role: CatalogSetRunRole.unit),
    (text: raw, role: CatalogSetRunRole.value),
    if (at + raw.length < text.length)
      (text: text.substring(at + raw.length), role: CatalogSetRunRole.unit),
  ];
}

/// A typed set in its compact plain form: `18 kg × 12`, `45 s`, `200 m`,
/// `18 kg × 12 · 30 s`, `12 reps`. Empty when no metric is valid.
String catalogSetCompact(CatalogSetEvidence evidence, AppLocalizations l) =>
    catalogSetRuns(evidence, l).map((run) => run.text).join();

/// [catalogSetCompact] styled like the classic set line: mono numbers, smaller
/// dim units and faint separators. One line that scales down as a whole rather
/// than ellipsising a number. Shows `—` when no metric is valid.
class CatalogSetText extends StatelessWidget {
  const CatalogSetText(
    this.evidence, {
    super.key,
    this.size = 15,
    this.color,
    this.weight = FontWeight.w500,
  });

  final CatalogSetEvidence evidence;

  /// The value size; units and separators are drawn at 12.
  final double size;

  /// The value colour; defaults to the text token.
  final Color? color;
  final FontWeight weight;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final l = AppLocalizations.of(context);
    final runs = catalogSetRuns(evidence, l);
    final small = size < 12 ? size : 12.0;
    final valueStyle = WorkoutType.mono(
      size: size,
      weight: weight,
      color: color ?? tokens.text,
    );
    TextStyle style(CatalogSetRunRole role) => switch (role) {
      CatalogSetRunRole.value => valueStyle,
      CatalogSetRunRole.unit => WorkoutType.mono(
        size: small,
        color: tokens.dim,
      ),
      CatalogSetRunRole.separator => WorkoutType.mono(
        size: small,
        color: tokens.faint,
      ),
    };
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: AlignmentDirectional.centerStart,
      child: Text.rich(
        TextSpan(
          children: runs.isEmpty
              ? [TextSpan(text: '—', style: valueStyle)]
              : [
                  for (final run in runs)
                    TextSpan(text: run.text, style: style(run.role)),
                ],
        ),
        maxLines: 1,
        softWrap: false,
      ),
    );
  }
}
