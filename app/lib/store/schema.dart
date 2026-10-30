import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Forward IDs are reserved: 1 foundation, 2 domain adapters, 3 workout,
/// 4 flexible prescriptions, 5 catalog execution. IDs 1–4 remain frozen.
const currentSchemaVersion = 5;
const alkionApplicationId = 0x414C4B31;
const reservedMigrationIds = {
  2: 'domains',
  3: 'workout',
  4: 'flexible-prescriptions',
  5: 'catalog-execution',
};

const foundationDomainTables = [
  'exercises',
  'day_templates',
  'day_template_items',
  'sessions',
  'sets',
  'bodyweight_logs',
  'muscle_targets',
];
const foundationDomainKinds = [
  'exercise',
  'trainingDay',
  'trainingSlot',
  'workout',
  'workoutSet',
  'bodyweight',
  'muscleTarget',
];
const domainTables = [
  ...foundationDomainTables,
  'exercise_catalog_bindings',
  'exercise_tracking_contexts',
];
const domainKinds = [
  ...foundationDomainKinds,
  'catalogBinding',
  'trackingContext',
];
const foundationPreservedTables = [
  'profile_state',
  'schema_migrations',
  'operations',
  'operation_dependencies',
  'reviews',
  'review_decisions',
  'operation_attempts',
  'attempt_outcomes',
  'record_revisions',
  'source_artifacts',
  'origin_mappings',
  'source_revisions',
  'source_projections',
  'corrections',
  'derived_results',
  'local_state',
  'catalog_pins',
  'import_generations',
  'import_journal',
  'correspondence',
  'replica_rows',
  'replica_checkpoints',
  'restore_journal',
  ...foundationDomainTables,
];
const preservedTables = [
  ...foundationPreservedTables,
  'exercise_catalog_bindings',
  'exercise_tracking_contexts',
];
List<String> preservedTablesAt(int version) =>
    version < 5 ? foundationPreservedTables : preservedTables;

final schemaStatements = <String>[
  '''CREATE TABLE profile_state (
    singleton INTEGER PRIMARY KEY CHECK(singleton=1),
    profile_id TEXT NOT NULL UNIQUE, installation_id TEXT NOT NULL,
    generation INTEGER NOT NULL CHECK(generation>=1),
    write_state TEXT NOT NULL CHECK(write_state IN ('writable','fenced','recovery')),
    created_at TEXT NOT NULL)''',
  '''CREATE TABLE schema_migrations (version INTEGER PRIMARY KEY,
    digest TEXT NOT NULL, applied_at TEXT NOT NULL)''',
  '''CREATE TABLE operations (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id),
    family TEXT NOT NULL CHECK(family IN ('workouts','bodyweight','targets')),
    operation_id TEXT NOT NULL, target_kind TEXT NOT NULL, target_id TEXT NOT NULL,
    action TEXT NOT NULL, semantic_version INTEGER NOT NULL CHECK(semantic_version=1),
    base_local_revision INTEGER NOT NULL CHECK(base_local_revision>=0),
    eligibility TEXT NOT NULL CHECK(eligibility IN ('localOnly','awaitingAttachment','unsupportedMapping')),
    input_bytes BLOB NOT NULL, input_hash TEXT NOT NULL, result_bytes BLOB NOT NULL,
    PRIMARY KEY(profile_id,family,operation_id))''',
  '''CREATE TABLE operation_dependencies (
    profile_id TEXT NOT NULL, family TEXT NOT NULL, operation_id TEXT NOT NULL,
    dependency_id TEXT NOT NULL CHECK(operation_id<>dependency_id),
    PRIMARY KEY(profile_id,family,operation_id,dependency_id),
    FOREIGN KEY(profile_id,family,operation_id) REFERENCES operations(profile_id,family,operation_id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(profile_id,family,dependency_id) REFERENCES operations(profile_id,family,operation_id) DEFERRABLE INITIALLY DEFERRED)''',
  '''CREATE TABLE reviews (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), review_id TEXT NOT NULL,
    family TEXT, operation_id TEXT, category TEXT NOT NULL, evidence_bytes BLOB NOT NULL,
    created_at TEXT NOT NULL, PRIMARY KEY(profile_id,review_id),
    FOREIGN KEY(profile_id,family,operation_id) REFERENCES operations(profile_id,family,operation_id) DEFERRABLE INITIALLY DEFERRED)''',
  '''CREATE TABLE review_decisions (
    profile_id TEXT NOT NULL, review_id TEXT NOT NULL, decision_id TEXT NOT NULL,
    decision_bytes BLOB NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,review_id,decision_id),
    FOREIGN KEY(profile_id,review_id) REFERENCES reviews(profile_id,review_id))''',
  '''CREATE TABLE operation_attempts (
    profile_id TEXT NOT NULL, family TEXT NOT NULL, operation_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL, translation_version TEXT NOT NULL,
    request_bytes BLOB NOT NULL, request_hash TEXT NOT NULL, binding_bytes BLOB NOT NULL,
    server_base_revision TEXT, attempted_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,family,operation_id,attempt_id),
    FOREIGN KEY(profile_id,family,operation_id) REFERENCES operations(profile_id,family,operation_id))''',
  '''CREATE TABLE attempt_outcomes (
    profile_id TEXT NOT NULL, family TEXT NOT NULL, operation_id TEXT NOT NULL,
    attempt_id TEXT NOT NULL, outcome_id TEXT NOT NULL, outcome_bytes BLOB NOT NULL,
    review_id TEXT, received_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,family,operation_id,attempt_id,outcome_id),
    FOREIGN KEY(profile_id,family,operation_id,attempt_id) REFERENCES operation_attempts(profile_id,family,operation_id,attempt_id),
    FOREIGN KEY(profile_id,review_id) REFERENCES reviews(profile_id,review_id) DEFERRABLE INITIALLY DEFERRED)''',
  '''CREATE TABLE record_revisions (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), kind TEXT NOT NULL,
    record_id TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>=1),
    deleted INTEGER NOT NULL CHECK(deleted IN (0,1)),
    layer TEXT NOT NULL CHECK(layer IN ('authored','sourceSelection','correction')),
    payload_bytes BLOB NOT NULL, family TEXT, operation_id TEXT,
    source_revision_id TEXT, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,kind,record_id,revision),
    FOREIGN KEY(profile_id,family,operation_id) REFERENCES operations(profile_id,family,operation_id) DEFERRABLE INITIALLY DEFERRED)''',
  '''CREATE TABLE source_artifacts (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), artifact_id TEXT NOT NULL,
    digest TEXT NOT NULL, raw_bytes BLOB NOT NULL, parser_version TEXT NOT NULL,
    format TEXT NOT NULL, disposition TEXT NOT NULL, observation_time_bytes BLOB,
    ingested_at TEXT NOT NULL, PRIMARY KEY(profile_id,artifact_id))''',
  '''CREATE TABLE origin_mappings (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), namespace TEXT NOT NULL,
    source_kind TEXT NOT NULL, external_id TEXT NOT NULL,
    local_kind TEXT NOT NULL, local_id TEXT NOT NULL,
    PRIMARY KEY(profile_id,namespace,source_kind,external_id),
    UNIQUE(profile_id,local_kind,local_id))''',
  '''CREATE TABLE source_revisions (
    profile_id TEXT NOT NULL, source_revision_id TEXT NOT NULL, namespace TEXT NOT NULL,
    source_kind TEXT NOT NULL, external_id TEXT NOT NULL, artifact_id TEXT NOT NULL,
    content_digest TEXT NOT NULL, original_fields BLOB NOT NULL, parser_version TEXT NOT NULL,
    observation_time_bytes BLOB, ingested_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,source_revision_id),
    UNIQUE(profile_id,namespace,source_kind,external_id,content_digest),
    FOREIGN KEY(profile_id,namespace,source_kind,external_id) REFERENCES origin_mappings(profile_id,namespace,source_kind,external_id),
    FOREIGN KEY(profile_id,artifact_id) REFERENCES source_artifacts(profile_id,artifact_id))''',
  '''CREATE TABLE source_projections (
    profile_id TEXT NOT NULL, source_revision_id TEXT NOT NULL, projection_version TEXT NOT NULL,
    projection_bytes BLOB NOT NULL, digest TEXT NOT NULL,
    PRIMARY KEY(profile_id,source_revision_id,projection_version),
    FOREIGN KEY(profile_id,source_revision_id) REFERENCES source_revisions(profile_id,source_revision_id))''',
  '''CREATE TABLE corrections (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), correction_id TEXT NOT NULL,
    kind TEXT NOT NULL, record_id TEXT NOT NULL, base_local_revision INTEGER NOT NULL,
    source_revision_id TEXT, attribution TEXT NOT NULL, correction_bytes BLOB NOT NULL,
    availability TEXT NOT NULL CHECK(availability IN ('available','unavailable')),
    created_at TEXT NOT NULL, PRIMARY KEY(profile_id,correction_id),
    FOREIGN KEY(profile_id,source_revision_id) REFERENCES source_revisions(profile_id,source_revision_id))''',
  '''CREATE TABLE derived_results (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), result_id TEXT NOT NULL,
    profile_version TEXT NOT NULL, view TEXT NOT NULL, input_revisions BLOB NOT NULL,
    result_bytes BLOB NOT NULL, coverage_bytes BLOB NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,result_id))''',
  '''CREATE TABLE local_state (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id),
    state_kind TEXT NOT NULL CHECK(state_kind IN ('draft','finishedRecovery','timer','semanticSetting','goalInitialization','orderResolution','catalogSelection','onboarding')),
    state_key TEXT NOT NULL, generation INTEGER NOT NULL CHECK(generation>=1),
    revision INTEGER NOT NULL CHECK(revision>=1), payload_bytes BLOB NOT NULL,
    status TEXT NOT NULL, updated_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,state_kind,state_key))''',
  '''CREATE TABLE catalog_pins (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), namespace TEXT NOT NULL,
    pin_id TEXT NOT NULL, digest TEXT NOT NULL, schema_version TEXT NOT NULL,
    raw_bytes BLOB NOT NULL, ancestry_bytes BLOB NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,namespace,pin_id))''',
  '''CREATE TABLE import_generations (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), namespace TEXT NOT NULL,
    import_id TEXT NOT NULL, artifact_id TEXT NOT NULL, status TEXT NOT NULL,
    selected INTEGER NOT NULL CHECK(selected IN (0,1)), manifest_bytes BLOB NOT NULL,
    PRIMARY KEY(profile_id,namespace,import_id),
    FOREIGN KEY(profile_id,artifact_id) REFERENCES source_artifacts(profile_id,artifact_id))''',
  'CREATE UNIQUE INDEX one_selected_import ON import_generations(profile_id,namespace) WHERE selected=1',
  '''CREATE TABLE import_journal (
    profile_id TEXT NOT NULL, namespace TEXT NOT NULL, import_id TEXT NOT NULL,
    entry_id TEXT NOT NULL, entry_bytes BLOB NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,namespace,import_id,entry_id),
    FOREIGN KEY(profile_id,namespace,import_id) REFERENCES import_generations(profile_id,namespace,import_id))''',
  '''CREATE TABLE correspondence (
    profile_id TEXT NOT NULL, namespace TEXT NOT NULL, source_kind TEXT NOT NULL,
    external_id TEXT NOT NULL, correspondence_id TEXT NOT NULL, account_id TEXT NOT NULL,
    space_id TEXT NOT NULL, source_id TEXT NOT NULL, animus_kind TEXT NOT NULL,
    logical_id TEXT NOT NULL, server_revision TEXT,
    verification TEXT NOT NULL CHECK(verification IN ('unresolved','verified')),
    evidence_bytes BLOB NOT NULL, PRIMARY KEY(profile_id,namespace,source_kind,external_id),
    FOREIGN KEY(profile_id,namespace,source_kind,external_id) REFERENCES origin_mappings(profile_id,namespace,source_kind,external_id))''',
  '''CREATE TABLE replica_rows (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), dataset TEXT NOT NULL,
    remote_id TEXT NOT NULL, server_revision TEXT NOT NULL, body_bytes BLOB NOT NULL,
    PRIMARY KEY(profile_id,dataset,remote_id))''',
  '''CREATE TABLE replica_checkpoints (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), dataset TEXT NOT NULL,
    checkpoint_bytes BLOB NOT NULL, coverage_bytes BLOB NOT NULL,
    PRIMARY KEY(profile_id,dataset))''',
  '''CREATE TABLE restore_journal (
    profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), restore_id TEXT NOT NULL,
    entry_id TEXT NOT NULL, from_generation INTEGER NOT NULL, to_generation INTEGER NOT NULL,
    entry_bytes BLOB NOT NULL, created_at TEXT NOT NULL,
    PRIMARY KEY(profile_id,restore_id,entry_id))''',
  _domain(
    'exercises',
    'exercise',
    '''name TEXT, slug TEXT, muscle_group TEXT,
    equip TEXT, compound INTEGER, base_weight_kg TEXT, plate_step_kg TEXT,
    default_rep_low INTEGER, default_rep_high INTEGER, default_warmup_sets INTEGER,
    default_working_sets INTEGER, default_rir_low INTEGER, default_rir_high INTEGER,
    default_rest_seconds INTEGER, is_template INTEGER, created_by TEXT, created_at TEXT''',
  ),
  _domain(
    'day_templates',
    'trainingDay',
    '''slug TEXT, name TEXT, notes TEXT, position INTEGER,
    is_template INTEGER, created_by TEXT, created_at TEXT, focus TEXT, scheduled_weekday INTEGER''',
  ),
  _domain(
    'day_template_items',
    'trainingSlot',
    '''day_template_id TEXT, exercise_id TEXT,
    position INTEGER, target_warmup_sets INTEGER, target_working_sets INTEGER,
    target_rep_low INTEGER, target_rep_high INTEGER, target_rir_low INTEGER,
    target_rir_high INTEGER, is_template INTEGER, created_by TEXT, created_at TEXT,
    FOREIGN KEY(profile_id,day_template_id) REFERENCES day_templates(profile_id,id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(profile_id,exercise_id) REFERENCES exercises(profile_id,id) DEFERRABLE INITIALLY DEFERRED''',
  ),
  _domain(
    'sessions',
    'workout',
    '''user_id TEXT, date TEXT, split_label TEXT, notes TEXT,
    day_template_id TEXT, created_at TEXT, finished_at TEXT, duration_min INTEGER,
    original_day_id TEXT,
    FOREIGN KEY(profile_id,day_template_id) REFERENCES day_templates(profile_id,id) DEFERRABLE INITIALLY DEFERRED''',
  ),
  _domain(
    'sets',
    'workoutSet',
    '''session_id TEXT, exercise_id TEXT, user_id TEXT,
    set_number INTEGER, weight_kg TEXT, reps INTEGER, rir INTEGER,
    is_warmup INTEGER, is_top_set INTEGER, is_pr INTEGER,
    created_at TEXT, updated_at TEXT,
    FOREIGN KEY(profile_id,session_id) REFERENCES sessions(profile_id,id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(profile_id,exercise_id) REFERENCES exercises(profile_id,id) DEFERRABLE INITIALLY DEFERRED''',
  ),
  _domain(
    'bodyweight_logs',
    'bodyweight',
    'user_id TEXT, date TEXT, weight_kg TEXT, created_at TEXT',
  ),
  _domain(
    'muscle_targets',
    'muscleTarget',
    'user_id TEXT, muscle TEXT, target_sets INTEGER, created_at TEXT',
  ),
  'CREATE INDEX sets_session ON sets(profile_id,session_id,set_number)',
  'CREATE INDEX slots_day ON day_template_items(profile_id,day_template_id,position)',
  for (final table in [
    'schema_migrations',
    'operations',
    'operation_dependencies',
    'reviews',
    'review_decisions',
    'operation_attempts',
    'attempt_outcomes',
    'record_revisions',
    'source_artifacts',
    'origin_mappings',
    'source_revisions',
    'source_projections',
    'corrections',
    'derived_results',
    'catalog_pins',
    'import_journal',
    'correspondence',
    'restore_journal',
  ])
    ..._immutable(table),
  for (final table in foundationDomainTables)
    "CREATE TRIGGER ${table}_retain BEFORE DELETE ON $table BEGIN SELECT RAISE(ABORT,'recoverable_tombstone_required'); END",
  "CREATE TRIGGER profile_retain BEFORE DELETE ON profile_state BEGIN SELECT RAISE(ABORT,'profile_preserved'); END",
];

String _domain(String table, String kind, String fields) =>
    '''CREATE TABLE $table (
  profile_id TEXT NOT NULL REFERENCES profile_state(profile_id), id TEXT NOT NULL,
  kind TEXT NOT NULL DEFAULT '$kind' CHECK(kind='$kind'),
  revision INTEGER NOT NULL CHECK(revision>=1), deleted INTEGER NOT NULL DEFAULT 0 CHECK(deleted IN (0,1)),
  source_revision_id TEXT, ancestry_bytes BLOB, evidence_bytes BLOB, $fields,
  PRIMARY KEY(profile_id,id),
  FOREIGN KEY(profile_id,kind,id,revision) REFERENCES record_revisions(profile_id,kind,record_id,revision) DEFERRABLE INITIALLY DEFERRED,
  FOREIGN KEY(profile_id,source_revision_id) REFERENCES source_revisions(profile_id,source_revision_id))''';

List<String> _immutable(String table) => [
  for (final verb in ['UPDATE', 'DELETE'])
    "CREATE TRIGGER ${table}_${verb.toLowerCase()}_immutable BEFORE $verb ON $table BEGIN SELECT RAISE(ABORT,'immutable_evidence'); END",
];
String get foundationMigrationDigest =>
    sha256.convert(utf8.encode(schemaStatements.join('\n'))).toString();

String schemaSqlDigest(Iterable<String> statements) {
  final normalized =
      statements
          .map((sql) => sql.replaceAll(RegExp(r'\s+'), ' ').trim())
          .toList()
        ..sort();
  return sha256.convert(utf8.encode(normalized.join('\n'))).toString();
}

/// Later tasks supply their reserved contiguous ID, immutable SQL and reviewed
/// resulting sqlite_master digest. The foundation SQL/digest remains frozen.
final class ForwardMigration {
  ForwardMigration({
    required this.version,
    required List<String> statements,
    required this.expectedSchemaDigest,
  }) : statements = List.unmodifiable(statements);
  final int version;
  final List<String> statements;
  final String expectedSchemaDigest;
  String get digest =>
      sha256.convert(utf8.encode(statements.join('\n'))).toString();
}

final class SchemaRegistry {
  SchemaRegistry({List<ForwardMigration> forward = const []})
    : migrations = List.unmodifiable([
        ForwardMigration(
          version: 1,
          statements: schemaStatements,
          expectedSchemaDigest: schemaSqlDigest(schemaStatements),
        ),
        ...forward,
      ]) {
    for (var i = 0; i < migrations.length; i++) {
      if (migrations[i].version != i + 1 ||
          migrations[i].version > 5 ||
          !RegExp(
            r'^[0-9a-f]{64}$',
          ).hasMatch(migrations[i].expectedSchemaDigest)) {
        throw const FormatException(
          'Contiguous qualified migration IDs 1–5 required',
        );
      }
    }
  }
  final List<ForwardMigration> migrations;
  int get latestVersion => migrations.last.version;
  ForwardMigration at(int version) => migrations[version - 1];
}

/// Registered domain indexes; date duplicates remain deliberately allowed.
const domainMigrationStatements = [
  'CREATE INDEX domain_bodyweight_date ON bodyweight_logs(profile_id,date,deleted)',
  'CREATE INDEX domain_target_label ON muscle_targets(profile_id,muscle,deleted)',
];
SchemaRegistry domainSchemaRegistry() => SchemaRegistry(
  forward: [
    ForwardMigration(
      version: 2,
      statements: domainMigrationStatements,
      expectedSchemaDigest: schemaSqlDigest([
        ...schemaStatements,
        ...domainMigrationStatements,
      ]),
    ),
  ],
);

const workflowMigrationStatements = [
  'CREATE VIEW reps_compat1_captured AS SELECT s.*, is_top_set AS captured_top, is_pr AS captured_pr FROM sets s',
  'CREATE VIEW reps_compat1_legacy_server AS SELECT s.*, NULL AS server_top, NULL AS server_pr, 0 AS server_derivation_available FROM sets s',
  r"CREATE VIEW reps_compat1_legacy_local AS SELECT s.*, COALESCE((SELECT json_extract(CAST(d.result_bytes AS TEXT),'$.is_top_set') FROM derived_results d WHERE d.profile_id=s.profile_id AND d.result_id='workout-set:'||s.id||':'||s.revision AND d.profile_version='reps-compat/1' AND d.view='legacy-local'),s.is_top_set) AS legacy_local_top, COALESCE((SELECT json_extract(CAST(d.result_bytes AS TEXT),'$.is_pr') FROM derived_results d WHERE d.profile_id=s.profile_id AND d.result_id='workout-set:'||s.id||':'||s.revision AND d.profile_version='reps-compat/1' AND d.view='legacy-local'),s.is_pr) AS legacy_local_pr FROM sets s",
  'CREATE INDEX workflow_sessions_date ON sessions(profile_id,deleted,date,created_at,id)',
];
SchemaRegistry workflowSchemaRegistry() => SchemaRegistry(
  forward: [
    ...domainSchemaRegistry().migrations.skip(1),
    ForwardMigration(
      version: 3,
      statements: workflowMigrationStatements,
      expectedSchemaDigest: schemaSqlDigest([
        ...schemaStatements,
        ...domainMigrationStatements,
        ...workflowMigrationStatements,
      ]),
    ),
  ],
);

/// Nullable policy preserves legacy slot targets/inheritance; unknown literals
/// are retained as unavailable. A missing legacy active flag becomes 1, while
/// explicit null/unknown flags remain available for recovery rather than active.
const prescriptionMigrationStatements = [
  'ALTER TABLE day_templates ADD COLUMN is_active INTEGER DEFAULT 1',
  'ALTER TABLE day_template_items ADD COLUMN rir_policy TEXT',
];

/// sqlite_master's ALTER TABLE shape, without modifying foundation SQL/history.
final _prescriptionSchemaStatements = [
  for (final sql in schemaStatements)
    if (sql.startsWith('CREATE TABLE day_templates '))
      sql.replaceFirst(
        'PRIMARY KEY(profile_id,id),',
        'is_active INTEGER DEFAULT 1, PRIMARY KEY(profile_id,id),',
      )
    else if (sql.startsWith('CREATE TABLE day_template_items '))
      sql.replaceFirst(
        'FOREIGN KEY(profile_id,day_template_id)',
        'rir_policy TEXT, FOREIGN KEY(profile_id,day_template_id)',
      )
    else
      sql,
  ...domainMigrationStatements,
  ...workflowMigrationStatements,
];

SchemaRegistry prescriptionSchemaRegistry() => SchemaRegistry(
  forward: [
    ...workflowSchemaRegistry().migrations.skip(1),
    ForwardMigration(
      version: 4,
      statements: prescriptionMigrationStatements,
      expectedSchemaDigest: schemaSqlDigest(_prescriptionSchemaStatements),
    ),
  ],
);

final catalogExecutionMigrationStatements = <String>[
  'ALTER TABLE exercises ADD COLUMN execution_definition_bytes BLOB',
  'ALTER TABLE day_template_items ADD COLUMN tracking_context_id TEXT',
  'ALTER TABLE day_template_items ADD COLUMN catalog_selection_bytes BLOB',
  'ALTER TABLE day_template_items ADD COLUMN catalog_targets_bytes BLOB',
  'ALTER TABLE sets ADD COLUMN tracking_context_id TEXT',
  'ALTER TABLE sets ADD COLUMN catalog_set_bytes BLOB',
  'ALTER TABLE sets ADD COLUMN block_id TEXT',
  'ALTER TABLE sets ADD COLUMN origin_slot_id TEXT',
  'ALTER TABLE sets ADD COLUMN origin_slot_revision INTEGER',
  _domain(
    'exercise_catalog_bindings',
    'catalogBinding',
    '''exercise_id TEXT NOT NULL, catalog_namespace TEXT NOT NULL,
    family_id TEXT NOT NULL, variant_id TEXT NOT NULL,
    variant_revision INTEGER NOT NULL CHECK(variant_revision>=1),
    bundle_digest TEXT NOT NULL, label_policy TEXT NOT NULL,
    stable_label TEXT NOT NULL, measurement_profile_bytes BLOB NOT NULL,
    UNIQUE(profile_id,catalog_namespace,variant_id), UNIQUE(profile_id,exercise_id),
    FOREIGN KEY(profile_id,exercise_id) REFERENCES exercises(profile_id,id) DEFERRABLE INITIALLY DEFERRED''',
  ),
  _domain(
    'exercise_tracking_contexts',
    'trackingContext',
    '''exercise_id TEXT NOT NULL, binding_id TEXT, binding_revision INTEGER,
    label TEXT NOT NULL, resistance_source TEXT NOT NULL,
    load_convention TEXT NOT NULL, execution_bytes BLOB NOT NULL,
    CHECK((binding_id IS NULL)=(binding_revision IS NULL)),
    FOREIGN KEY(profile_id,exercise_id) REFERENCES exercises(profile_id,id) DEFERRABLE INITIALLY DEFERRED,
    FOREIGN KEY(profile_id,binding_id) REFERENCES exercise_catalog_bindings(profile_id,id) DEFERRABLE INITIALLY DEFERRED''',
  ),
  'CREATE INDEX catalog_context_exercise ON exercise_tracking_contexts(profile_id,exercise_id,deleted)',
  'CREATE INDEX catalog_sets_context ON sets(profile_id,tracking_context_id,session_id,set_number)',
  for (final table in [
    'exercise_catalog_bindings',
    'exercise_tracking_contexts',
  ])
    "CREATE TRIGGER ${table}_retain BEFORE DELETE ON $table BEGIN SELECT RAISE(ABORT,'recoverable_tombstone_required'); END",
];

// ALTER TABLE appends columns immediately before table constraints in
// sqlite_master, even though the executed statements are kept immutable above.
final _catalogExecutionSchemaStatements = [
  for (final sql in _prescriptionSchemaStatements)
    if (sql.startsWith('CREATE TABLE exercises '))
      sql.replaceFirst(
        'PRIMARY KEY(profile_id,id),',
        'execution_definition_bytes BLOB, PRIMARY KEY(profile_id,id),',
      )
    else if (sql.startsWith('CREATE TABLE day_template_items '))
      sql.replaceFirst(
        'FOREIGN KEY(profile_id,day_template_id)',
        'tracking_context_id TEXT, catalog_selection_bytes BLOB, catalog_targets_bytes BLOB, FOREIGN KEY(profile_id,day_template_id)',
      )
    else if (sql.startsWith('CREATE TABLE sets '))
      sql.replaceFirst(
        'FOREIGN KEY(profile_id,session_id)',
        'tracking_context_id TEXT, catalog_set_bytes BLOB, block_id TEXT, origin_slot_id TEXT, origin_slot_revision INTEGER, FOREIGN KEY(profile_id,session_id)',
      )
    else
      sql,
  ...catalogExecutionMigrationStatements.where(
    (sql) => !sql.startsWith('ALTER TABLE '),
  ),
];

SchemaRegistry catalogExecutionSchemaRegistry() => SchemaRegistry(
  forward: [
    ...prescriptionSchemaRegistry().migrations.skip(1),
    ForwardMigration(
      version: 5,
      statements: catalogExecutionMigrationStatements,
      expectedSchemaDigest: schemaSqlDigest(_catalogExecutionSchemaStatements),
    ),
  ],
);
