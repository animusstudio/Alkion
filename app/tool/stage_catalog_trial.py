#!/usr/bin/env python3
"""Project explicit, hash-pinned catalog input for a private offline trial.

The projection is not cleared for redistribution. Only the isolated Android
target includes it; ordinary Flutter assets declare the public README alone.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tempfile

APP = Path(__file__).resolve().parents[1]
ASSETS = APP / 'assets/catalog_trial'
ANDROID_ASSETS = APP / 'build/private-catalog-trial/assets'
DEV_ANDROID_ASSETS = APP / 'build/private-catalog-dev/assets'
CATALOG_NAME = 'catalog.dev.json'
MANIFEST_NAME = 'manifest.dev.json'
BROWSE_NAME = 'browse.dev.json'
MUSCLE_GROUPS = set('chest back shoulders biceps triceps forearms quads hamstrings glutes calves core adductors abductors'.split())
ACTIVITY_GROUPS = {'mobility', 'conditioning', 'whole_body'}
LOCALES = {'en', 'it', 'de', 'es'}
NOTICE = (
    'Private development trial only. Publication and redistribution are not '
    'cleared. Editorial names and partial or unknown muscle roles are not '
    'verified manufacturer or measured activation claims. No media is included.'
)
DEV_NOTICE = NOTICE.replace('Private development trial only.', 'Private development catalog only.')
TABLE_FIELDS = {
    'families': ('id', 'key', 'names'),
    'variants': ('id', 'key', 'family_id', 'revision', 'names',
                 'equipment_kind', 'facets', 'measurement_profile'),
    'collections': ('id', 'key', 'names', 'selector'),
    'measurement_profiles': ('key', 'required_metrics', 'optional_metrics',
                             'progression_policy'),
    'anatomy_nodes': ('id', 'names'),
    'muscle_profiles': ('variant_id', 'variant_revision', 'coverage',
                        'relationships'),
    **{key: ('id', 'text', 'locale', 'target', 'selector', 'qualifier', 'literal')
       for key in ('aliases', 'scoped_terms', 'abbreviations')},
}


def _object_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError('Duplicate JSON object key')
        result[key] = value
    return result


def decode(data):
    def invalid_constant(_):
        raise ValueError('Non-JSON numeric constant')
    return json.loads(data.decode('utf-8'), object_pairs_hook=_object_pairs,
                      parse_constant=invalid_constant)


def encode(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True,
                       separators=(',', ':')) + '\n').encode('utf-8')


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def _object(value):
    if not isinstance(value, dict):
        raise ValueError('Expected a catalog object')
    return value


def _array(value):
    if not isinstance(value, list):
        raise ValueError('Expected a catalog array')
    return value


def _strings(value):
    if any(not isinstance(v, str) for v in _array(value)):
        raise ValueError('Expected catalog string values')
    return value


def _string_map(value):
    if any(not isinstance(v, str) for v in _object(value).values()):
        raise ValueError('Expected catalog string labels')
    return value


def _selector(value):
    result = {}
    for key, item in _object(value).items():
        if key in ('family_ids', 'equipment_kinds'):
            result[key] = _strings(item)
        elif key in ('facets', 'excluded_facets'):
            result[key] = {name: _strings(values)
                           for name, values in _object(item).items()}
    return result


def project(source):
    source = _object(source)
    if (source.get('format') != 'alkion-exercise-catalog' or
            type(source.get('schema_version')) is not int or
            source['schema_version'] != 1):
        raise ValueError('Unsupported catalog format/schema')
    if _array(source.get('equipment_models')):
        raise ValueError('Equipment models are not admitted for this trial')
    result = {key: source[key] for key in
              ('format', 'schema_version', 'catalog_revision', 'search_revision')}
    for key in ('catalog_revision', 'search_revision'):
        if not isinstance(result[key], str) or not result[key]:
            raise ValueError('Missing catalog revision')
    result['equipment_kinds'] = _strings(source.get('equipment_kinds'))
    result['facet_vocabulary'] = {
        key: _strings(values)
        for key, values in _object(source.get('facet_vocabulary')).items()
    }
    result['equipment_models'] = []
    for table, fields in TABLE_FIELDS.items():
        result[table] = []
        for original in _array(source.get(table)):
            original = _object(original)
            row = {key: original[key] for key in fields if key in original}
            for key in ('names', 'facets'):
                if key in row:
                    row[key] = _string_map(row[key])
            if 'selector' in row:
                row['selector'] = _selector(row['selector'])
            if 'target' in row:
                target = _object(row['target'])
                row['target'] = {key: target[key] for key in ('kind', 'id')}
                if any(not isinstance(value, str) or not value
                       for value in row['target'].values()):
                    raise ValueError('Invalid catalog target')
            for key in ('required_metrics', 'optional_metrics'):
                if key in row:
                    row[key] = _strings(row[key])
            for key in ('id', 'key', 'family_id', 'equipment_kind',
                        'measurement_profile', 'text', 'locale', 'variant_id',
                        'progression_policy'):
                if key in row and (not isinstance(row[key], str) or not row[key]):
                    raise ValueError('Invalid catalog scalar')
            for key in ('qualifier', 'literal'):
                if key in row and type(row[key]) is not bool:
                    raise ValueError('Invalid catalog term flag')
            for key in ('revision', 'variant_revision'):
                if key in row and (type(row[key]) is not int or row[key] < 1):
                    raise ValueError('Invalid catalog revision')
            if 'relationships' in row:
                if row.get('coverage') not in ('unknown', 'partial'):
                    raise ValueError('Only unknown/partial muscle coverage is admitted')
                row['relationships'] = [
                    {key: relation[key] for key in
                     ('anatomy_node_id', 'role', 'emphasis') if key in relation}
                    for relation in map(_object, _array(row['relationships']))
                ]
                if row['coverage'] == 'unknown' and row['relationships']:
                    raise ValueError('Unknown muscle coverage must not contain claims')
                for relation in row['relationships']:
                    if (not isinstance(relation.get('anatomy_node_id'), str) or
                            relation.get('role') not in ('primary', 'secondary', 'stabilizer') or
                            ('emphasis' in relation and
                             not isinstance(relation['emphasis'], (str, int, float)))):
                        raise ValueError('Invalid editorial muscle relationship')
            result[table].append(row)
    return result


def project_browse(source, catalog, source_digest, projection_digest):
    """Expand author-reviewed input only; never infer membership from names/anatomy."""
    source = _object(source)
    if (source.get('format') != 'alkion-catalog-browse' or
            type(source.get('schema_version')) is not int or
            source['schema_version'] != 1 or
            source.get('source_sha256') != source_digest or
            source.get('catalog_revision') != catalog['catalog_revision'] or
            not isinstance(source.get('classification_revision'), str) or
            not source['classification_revision'].strip()):
        raise ValueError('Unsupported or stale browse classification binding')
    result = {key: source[key] for key in ('format', 'schema_version',
              'classification_revision', 'source_sha256', 'catalog_revision')}
    result['projection_sha256'] = projection_digest
    groups = {}
    for row in map(_object, _array(source.get('groups'))):
        key, kind = row.get('key'), row.get('kind')
        allowed = MUSCLE_GROUPS if kind == 'muscle' else ACTIVITY_GROUPS if kind == 'activity' else set()
        if not isinstance(key, str) or key not in allowed or key in groups:
            raise ValueError('Duplicate or unsupported browse group')
        names = _string_map(row.get('names'))
        synonyms = _object(row.get('synonyms'))
        if (set(names) != LOCALES or set(synonyms) != LOCALES or
                any(not name.strip() for name in names.values())):
            raise ValueError('Browse groups require all supported locales')
        synonyms = {locale: _strings(values) for locale, values in synonyms.items()}
        if any(any(not v.strip() for v in values) or len(values) != len(set(values))
               for values in synonyms.values()):
            raise ValueError('Invalid or duplicate group synonyms')
        groups[key] = dict(key=key, kind=kind, names=names, synonyms=synonyms)
    if not groups:
        raise ValueError('Browse groups are empty')
    result['groups'] = list(groups.values())
    revisions = {row['id']: row['revision'] for row in catalog['variants']}
    variants = {}
    for row in map(_object, _array(source.get('variants'))):
        key, status = row.get('variant_id'), row.get('status')
        if (not isinstance(key, str) or key not in revisions or key in variants or
                type(row.get('variant_revision')) is not int or
                row['variant_revision'] != revisions[key] or
                status not in ('reviewed', 'unresolved')):
            raise ValueError('Duplicate, unsupported or stale browse variant')
        entry = {name: row[name] for name in ('variant_id', 'variant_revision', 'status')}
        for name in ('target_groups', 'secondary_groups', 'activity_groups'):
            values = _strings(row.get(name))
            kind = 'activity' if name == 'activity_groups' else 'muscle'
            if (len(values) != len(set(values)) or
                    any(groups.get(v, {}).get('kind') != kind for v in values) or
                    (status == 'unresolved' and values)):
                raise ValueError('Invalid browse membership')
            entry[name] = values
        if status == 'reviewed' and not (entry['target_groups'] or entry['activity_groups']):
            raise ValueError('Reviewed browse variants require a target or activity')
        if set(entry['target_groups']) & set(entry['secondary_groups']):
            raise ValueError('Overlapping browse roles')
        variants[key] = entry
    if set(variants) != set(revisions):
        raise ValueError('Browse classifications must account for every variant')
    result['variants'] = list(variants.values())
    return result


def manifest_for(catalog, source_digest, projection_digest, browse=None, *, development=False):
    manifest = {
        'format': 'alkion-catalog-trial-manifest',
        'schema_version': 1,
        'private_trial_only': True,
        'redistribution_cleared': False,
        'source_sha256': source_digest,
        'projection_sha256': projection_digest,
        'catalog_revision': catalog['catalog_revision'],
        'search_revision': catalog['search_revision'],
        'counts': {key: len(catalog[key])
                   for key in (*TABLE_FIELDS, 'equipment_models')},
        'muscle_evidence': 'partial_or_unknown_editorial_roles',
        'media_included': False,
        'notices': [NOTICE],
    }

    if browse is not None:
        manifest['schema_version'] = 2
        manifest['browse'] = browse
    if development:
        manifest['format'] = 'alkion-catalog-development-manifest'
        manifest['schema_version'] = 3
        del manifest['private_trial_only']
        manifest['private_development_only'] = True
        manifest['notices'] = [DEV_NOTICE]
    return manifest


def _safe_output(path):
    for ancestor in (path, *path.parents):
        if ancestor.is_symlink():
            raise ValueError('Staging output must not contain symlinks')
        if ancestor == APP:
            break


def _write_files(directory, files):
    _safe_output(directory)
    directory.mkdir(parents=True, exist_ok=True)
    for name, data in files.items():
        path = directory / name
        if path.exists() and (path.is_symlink() or path.read_bytes() != data):
            raise ValueError('Existing staging differs; preserve/review it before restaging')
    with tempfile.TemporaryDirectory(prefix='.catalog-stage-', dir=directory) as temp:
        for name, data in files.items():
            path = Path(temp) / name
            path.write_bytes(data)
            path.replace(directory / name)


def stage(source_path, expected_sha256, browse_path=None, browse_sha256=None):
    if not re.fullmatch(r'[0-9a-f]{64}', expected_sha256):
        raise ValueError('An explicit lowercase SHA-256 is required')
    if source_path.is_symlink() or not source_path.is_file():
        raise ValueError('Input must be an explicit regular file, not a symlink')
    data = source_path.read_bytes()
    if sha256(data) != expected_sha256:
        raise ValueError('Input does not match the reviewed SHA-256')
    catalog = project(decode(data))
    projected = encode(catalog)
    manifest = manifest_for(catalog, expected_sha256, sha256(projected))
    files = {CATALOG_NAME: projected}
    if (browse_path is None) != (browse_sha256 is None):
        raise ValueError('Both explicit browse input and SHA-256 are required')
    if browse_path is not None:
        if (not re.fullmatch(r'[0-9a-f]{64}', browse_sha256) or
                browse_path.is_symlink() or not browse_path.is_file()):
            raise ValueError('Browse input must be an explicit regular file and SHA-256')
        browse_data = browse_path.read_bytes()
        if sha256(browse_data) != browse_sha256:
            raise ValueError('Browse input does not match the reviewed SHA-256')
        browse = project_browse(decode(browse_data), catalog, expected_sha256, sha256(projected))
        files[BROWSE_NAME] = encode(browse)
        manifest = manifest_for(catalog, expected_sha256, sha256(projected), {
            'source_sha256': browse_sha256,
            'projection_sha256': sha256(files[BROWSE_NAME]),
            'classification_revision': browse['classification_revision'],
        })
    files[MANIFEST_NAME] = encode(manifest)
    mirror = ANDROID_ASSETS / 'flutter_assets/assets/catalog_trial'
    for directory in (ASSETS, mirror):
        _safe_output(directory)
        if BROWSE_NAME not in files and (directory / BROWSE_NAME).exists():
            raise ValueError('Existing browse staging differs; preserve/review it before restaging')
        for name, output in files.items():
            path = directory / name
            if path.exists() and (path.is_symlink() or path.read_bytes() != output):
                raise ValueError('Existing staging differs; preserve/review it before restaging')
    _write_files(ASSETS, files)
    _write_files(mirror, files)
    return verify()


def verify(*, development=False):
    android_assets = DEV_ANDROID_ASSETS if development else ANDROID_ASSETS
    mirror = android_assets / 'flutter_assets/assets/catalog_trial'
    assets = mirror if development else ASSETS
    _safe_output(assets)
    _safe_output(android_assets)
    files = {}
    for name in (CATALOG_NAME, MANIFEST_NAME):
        path = assets / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Private catalog staging is absent or redirected')
        files[name] = path.read_bytes()
    catalog = project(decode(files[CATALOG_NAME]))
    if encode(catalog) != files[CATALOG_NAME]:
        raise ValueError('Staged catalog contains unadmitted fields or encoding')
    manifest = decode(files[MANIFEST_NAME])
    source_digest = manifest.get('source_sha256', '')
    if not isinstance(source_digest, str) or not re.fullmatch(r'[0-9a-f]{64}', source_digest):
        raise ValueError('Invalid source digest in trial manifest')
    browse_metadata = manifest.get('browse')
    if browse_metadata is not None:
        if (not isinstance(browse_metadata, dict) or
                set(browse_metadata) != {'source_sha256', 'projection_sha256', 'classification_revision'} or
                any(not isinstance(browse_metadata.get(key), str) or
                    not re.fullmatch(r'[0-9a-f]{64}', browse_metadata[key])
                    for key in ('source_sha256', 'projection_sha256'))):
            raise ValueError('Invalid browse manifest')
        path = assets / BROWSE_NAME
        if path.is_symlink() or not path.is_file():
            raise ValueError('Browse staging is absent or redirected')
        files[BROWSE_NAME] = path.read_bytes()
        browse = project_browse(decode(files[BROWSE_NAME]), catalog, source_digest,
                                sha256(files[CATALOG_NAME]))
        if (encode(browse) != files[BROWSE_NAME] or
                sha256(files[BROWSE_NAME]) != browse_metadata['projection_sha256'] or
                browse['classification_revision'] != browse_metadata['classification_revision']):
            raise ValueError('Browse manifest or projection mismatch')
    elif (assets / BROWSE_NAME).exists():
        raise ValueError('Unbound browse staging inventory')
    expected = manifest_for(catalog, source_digest, sha256(files[CATALOG_NAME]),
                            browse_metadata, development=development)
    if manifest != expected:
        raise ValueError('Private trial manifest does not match the projection')
    _safe_output(mirror)
    allowed_paths = {mirror / name for name in files}
    for path in android_assets.rglob('*'):
        if path.is_symlink() or (path.is_file() and path not in allowed_paths):
            raise ValueError('Unexpected private Android asset inventory')
    if {p.name for p in mirror.iterdir()} != set(files):
        raise ValueError('Unexpected private Android asset inventory')
    for name, data in files.items():
        path = mirror / name
        if path.is_symlink() or not path.is_file() or path.read_bytes() != data:
            raise ValueError('Private Android asset mirror differs')
    return manifest


def stage_development():
    """Admit the retained reviewed projection without rewriting either trial copy."""
    trial = verify()
    files = {name: (ASSETS / name).read_bytes()
             for name in (CATALOG_NAME, BROWSE_NAME)
             if name == CATALOG_NAME or trial.get('browse') is not None}
    catalog = project(decode(files[CATALOG_NAME]))
    files[MANIFEST_NAME] = encode(manifest_for(
        catalog, trial['source_sha256'], trial['projection_sha256'],
        trial.get('browse'), development=True))
    directory = DEV_ANDROID_ASSETS / 'flutter_assets/assets/catalog_trial'
    _safe_output(DEV_ANDROID_ASSETS)
    if DEV_ANDROID_ASSETS.exists():
        allowed = {directory / name for name in files}
        if any(p.is_symlink() or (p.is_file() and p not in allowed)
               for p in DEV_ANDROID_ASSETS.rglob('*')):
            raise ValueError('Unexpected private development asset inventory')
    _write_files(directory, files)
    return verify(development=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input', type=Path)
    parser.add_argument('--expected-sha256')
    parser.add_argument('--browse-input')
    parser.add_argument('--browse-sha256')
    parser.add_argument('--verify', action='store_true')
    parser.add_argument('--stage-dev', action='store_true')
    parser.add_argument('--verify-dev', action='store_true')
    args = parser.parse_args()
    if sum((args.verify, args.stage_dev, args.verify_dev)) > 1:
        parser.error('Select one staging or verification mode')
    if args.verify or args.stage_dev or args.verify_dev:
        if args.input or args.expected_sha256 or args.browse_input or args.browse_sha256:
            parser.error('This mode uses only the previously staged private inputs')
        manifest = stage_development() if args.stage_dev else verify(development=args.verify_dev)
    else:
        if not args.input or not args.expected_sha256:
            parser.error('Explicit --input and --expected-sha256 are required')
        manifest = stage(args.input, args.expected_sha256,
                         Path(args.browse_input) if args.browse_input else None,
                         args.browse_sha256 or None)
    print('Private catalog verified: ' +
          str(manifest['counts']['variants']) + ' variants; projection SHA-256 ' +
          manifest['projection_sha256'] + '; redistribution remains uncleared')


if __name__ == '__main__':
    main()
