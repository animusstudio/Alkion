import 'package:flutter/widgets.dart';

/// Copy for the ordinary Profile → Data import flow.
class RepsImportStrings {
  RepsImportStrings(this.language);
  final String language;
  String failure(Object error) {
    final code = '$error';
    if (code.contains('active_workout')) return activeWorkout;
    if (code.contains('namespace_artifact_conflict')) {
      return _s(
        'This import source already contains a different file. Choose the previously imported file; overlapping files need a separate review.',
        'Questa origine contiene già un altro file. Scegli il file già importato; i file sovrapposti richiedono una revisione separata.',
        'Diese Quelle enthält bereits eine andere Datei. Bereits importierte Datei wählen; überlappende Dateien erfordern eine eigene Prüfung.',
        'Este origen ya contiene otro archivo. Elige el archivo ya importado; los archivos superpuestos requieren otra revisión.',
      );
    }
    if (code.contains('mapping')) {
      return _s(
        'This mapping does not match the chosen history or the available catalog and measurement context. Choose its reviewed sidecar again. No mapping was applied.',
        'La mappatura non corrisponde alla cronologia o al catalogo e al contesto di misura disponibili. Scegli la mappatura revisionata corretta. Nessuna mappatura è stata applicata.',
        'Die Zuordnung passt nicht zum Verlauf oder zum verfügbaren Katalog und Messkontext. Passende geprüfte Datei wählen. Keine Zuordnung wurde angewendet.',
        'La asignación no coincide con el historial o el catálogo y contexto de medida disponibles. Elige el archivo revisado correcto. No se aplicó la asignación.',
      );
    }
    return _s(
      'The operation could not finish. Choose a supported Reps export or retry. Existing profiles and original files are preserved.',
      'L’operazione non è terminata. Scegli un export Reps supportato o riprova. Profili e file originali sono conservati.',
      'Der Vorgang konnte nicht beendet werden. Unterstützten Reps-Export wählen oder erneut versuchen. Profile und Originaldateien bleiben erhalten.',
      'La operación no terminó. Elige un exportación Reps compatible o reintenta. Se conservan los perfiles y archivos originales.',
    );
  }

  factory RepsImportStrings.of(BuildContext context) =>
      RepsImportStrings(Localizations.localeOf(context).languageCode);
  String get title => _s(
    'Import Reps data',
    'Importa dati Reps',
    'Reps-Daten importieren',
    'Importar datos de Reps',
  );
  String get intro => _s(
    'Import a Reps full or history export into this profile. Review its contents before importing.',
    'Importa un export Reps completo o della cronologia in questo profilo. Controlla il contenuto prima di importare.',
    'Vollständigen Reps-Export oder Verlauf in dieses Profil importieren. Inhalt vorher prüfen.',
    'Importa una exportación completa o un historial de Reps en este perfil. Revisa el contenido antes de importar.',
  );
  String get choose => _s(
    'Choose Reps file',
    'Scegli file Reps',
    'Reps-Datei wählen',
    'Elegir archivo de Reps',
  );
  String get mapping => _s(
    'Choose reviewed mapping',
    'Scegli mappatura revisionata',
    'Geprüfte Zuordnung wählen',
    'Elegir asignación revisada',
  );
  String get preview => _s('Preview', 'Anteprima', 'Vorschau', 'Vista previa');
  String get import =>
      _s('Import data', 'Importa dati', 'Daten importieren', 'Importar datos');
  String get imported => _s(
    'Data imported into this profile.',
    'Dati importati in questo profilo.',
    'Daten in dieses Profil importiert.',
    'Datos importados en este perfil.',
  );
  String get applySettings => _s(
    'Apply exported preferences',
    'Applica le preferenze esportate',
    'Exportierte Einstellungen anwenden',
    'Aplicar preferencias exportadas',
  );
  String get done => _s('Done', 'Fine', 'Fertig', 'Listo');
  String get mappings => _s(
    'Reviewed mappings',
    'Mappature revisionate',
    'Geprüfte Zuordnungen',
    'Asignaciones revisadas',
  );
  String get exceptions => _s(
    'Exceptions and preserved evidence',
    'Eccezioni e dati conservati',
    'Ausnahmen und erhaltene Belege',
    'Excepciones y datos conservados',
  );
  String get source => _s('Original', 'Originale', 'Original', 'Original');
  String get approximate => _s(
    'Approximate mapping',
    'Mappatura approssimativa',
    'Ungefähre Zuordnung',
    'Asignación aproximada',
  );
  String get exact => _s(
    'Reviewed exact mapping',
    'Mappatura esatta revisionata',
    'Geprüfte genaue Zuordnung',
    'Asignación exacta revisada',
  );
  String get unresolved => _s(
    'Unresolved · legacy history',
    'Irrisolta · cronologia originale',
    'Ungeklärt · Originalverlauf',
    'Sin resolver · historial original',
  );
  String get error => _s(
    'Could not complete this action',
    'Impossibile completare l’azione',
    'Aktion konnte nicht abgeschlossen werden',
    'No se pudo completar la acción',
  );
  String get activeWorkout => _s(
    'Finish or discard the active workout before importing data.',
    'Termina o elimina l’allenamento attivo prima di importare dati.',
    'Aktives Training vor dem Datenimport beenden oder verwerfen.',
    'Finaliza o descarta el entrenamiento activo antes de importar datos.',
  );
  String get filePath => _s(
    'Explicit file path',
    'Percorso esplicito del file',
    'Expliziter Dateipfad',
    'Ruta explícita del archivo',
  );
  String counts(Map<String, int> counts) => counts.entries
      .map(
        (entry) =>
            '${entry.value} ${switch (entry.key) {
              'exercises' => _s('exercises', 'esercizi', 'Übungen', 'ejercicios'),
              'day_templates' => _s('training days', 'giorni di allenamento', 'Trainingstage', 'días de entrenamiento'),
              'day_template_items' => _s('plan exercises', 'esercizi nel piano', 'Planübungen', 'ejercicios del plan'),
              'sessions' => _s('workouts', 'allenamenti', 'Trainings', 'entrenamientos'),
              'exercise_blocks' => _s('exercise blocks', 'blocchi esercizio', 'Übungsblöcke', 'bloques de ejercicio'),
              'sets' => _s('sets', 'serie', 'Sätze', 'series'),
              'bodyweight_logs' => _s('bodyweight entries', 'pesate', 'Körpergewichtseinträge', 'registros de peso corporal'),
              'muscle_targets' => _s('muscle targets', 'obiettivi muscolari', 'Muskelziele', 'objetivos musculares'),
              'settings' => _s('settings', 'impostazioni', 'Einstellungen', 'ajustes'),
              _ => entry.key,
            }}',
      )
      .join(' · ');
  String mappingCounts(Map<String, int> counts) =>
      '${counts['exact']} ${_s('exact', 'esatte', 'genau', 'exactas')} · ${counts['approximate']} ${_s('approximate', 'approssimative', 'ungefähr', 'aproximadas')} · ${counts['unresolved']} ${_s('unresolved', 'irrisolte', 'ungeklärt', 'sin resolver')}';
  String get preserved => _s(
    'Recorded kg, repetitions, RIR nulls and flags stay as exported. Calendar days have no inferred timezone. Mapping is review metadata only; imported workouts cannot be sent as native workouts.',
    'Kg, ripetizioni, RIR nulli e indicatori restano come esportati. Nessun fuso orario viene dedotto. La mappatura è solo metadato di revisione; gli allenamenti importati non possono essere inviati come nativi.',
    'Kg, Wiederholungen, leere RIR-Werte und Kennzeichen bleiben unverändert. Keine Zeitzone wird abgeleitet. Zuordnung ist nur Prüfmetadaten; importierte Trainings können nicht als native Trainings gesendet werden.',
    'Kg, repeticiones, RIR nulos e indicadores se conservan. No se deduce zona horaria. La asignación solo añade metadatos de revisión; los entrenamientos importados no se envían como nativos.',
  );
  String _s(String en, String it, String de, String es) => switch (language) {
    'it' => it,
    'de' => de,
    'es' => es,
    _ => en,
  };
}
