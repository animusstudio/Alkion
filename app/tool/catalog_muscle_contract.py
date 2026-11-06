"""Offline consumer admission for the portable v2 muscle artifact.

Explicit reviewed inputs establish trust. This validator does not fetch sources,
interpret evidence or verify a human's qualification. Full canonical historical
artifact and trust admission remains a separate reviewed gate.
"""
from datetime import date, datetime
import hashlib
import json
from pathlib import Path
import re

SCHEMA = json.loads((Path(__file__).parent / 'contracts/muscle-v2.schema.json').read_text())


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':')).encode()


def digest(value):
    return hashlib.sha256(canonical(value)).hexdigest()


def validate(value, definition='bundle'):
    def check(v, s):
        if '$ref' in s:
            return check(v, SCHEMA['$defs'][s['$ref'].split('/')[-1]])
        if 'const' in s and v != s['const']:
            return False
        if 'enum' in s and v not in s['enum']:
            return False
        if 'anyOf' in s and not any(check(v, item) for item in s['anyOf']):
            return False
        if not all(check(v, item) for item in s.get('allOf', [])):
            return False
        if 'if' in s and not check(v, s.get('then' if check(v, s['if']) else 'else', {})):
            return False
        types = {'object': lambda: isinstance(v, dict), 'array': lambda: isinstance(v, list),
                 'string': lambda: isinstance(v, str), 'boolean': lambda: type(v) is bool,
                 'integer': lambda: type(v) is int, 'number': lambda: type(v) in (int, float),
                 'null': lambda: v is None}
        if 'type' in s and not any(types[t]() for t in (s['type'] if isinstance(s['type'], list) else [s['type']])):
            return False
        if isinstance(v, dict):
            props = s.get('properties', {})
            if not all(k in v for k in s.get('required', [])):
                return False
            for k, item in v.items():
                if k in props:
                    if not check(item, props[k]):
                        return False
                elif s.get('additionalProperties') is False:
                    return False
                elif isinstance(s.get('additionalProperties'), dict) and not check(item, s['additionalProperties']):
                    return False
        if isinstance(v, list):
            if not s.get('minItems', 0) <= len(v) <= s.get('maxItems', 2**31) or (s.get('uniqueItems') and len({canonical(x) for x in v}) != len(v)):
                return False
            if 'items' in s and not all(check(x, s['items']) for x in v):
                return False
        if isinstance(v, str):
            if not s.get('minLength', 0) <= len(v) <= s.get('maxLength', 2**31):
                return False
            if 'pattern' in s and not re.search(s['pattern'], v):
                return False
            if s.get('format') in ('date', 'date-time'):
                try:
                    if s['format'] == 'date':
                        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}', v):
                            return False
                        date.fromisoformat(v)
                    else:
                        if not re.fullmatch(r'\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z', v):
                            return False
                        if int(v[11:13]) >= 24 or int(v[14:16]) >= 60 or int(v[17:19]) >= 60:
                            return False
                        datetime.fromisoformat(v)
                except ValueError:
                    return False
        if type(v) in (int, float) and v < s.get('minimum', float('-inf')):
            return False
        return True
    if not check(value, SCHEMA['$defs'][definition]):
        raise ValueError('Unsupported or invalid muscle contract schema')


def validate_inputs(catalog, bundle, scopes, raw_bundle):
    validate(bundle)
    validate(scopes, 'scope_registry')
    ref = catalog.get('muscle_bundle_ref')
    if (not isinstance(ref, dict) or set(ref) != {'namespace', 'revision', 'sha256'} or
            ref != {'namespace': bundle['namespace'], 'revision': bundle['revision'],
                    'sha256': hashlib.sha256(raw_bundle).hexdigest()}):
        raise ValueError('Catalog muscle bundle pointer mismatch')
    if bundle['scope_registry_ref'] != {'revision': scopes['revision'], 'sha256': digest(scopes)}:
        raise ValueError('Trusted scope registry reference mismatch')
    executions = sorted(({'variant_id': v['id'], 'variant_revision': v['revision'],
                          **{k: v[k] for k in ('family_id', 'equipment_kind', 'facets', 'measurement_profile')}}
                         for v in catalog['variants']), key=lambda x: x['variant_id'])
    execution_hash = digest({'namespace': 'alkion-exercises', 'executions': executions,
                             'measurement_definitions': sorted(catalog['measurement_profiles'], key=lambda x: x['key'])})
    if (bundle['catalog_binding']['catalog_namespace'] != 'alkion-exercises' or
            bundle['catalog_binding']['catalog_revision'] != catalog['catalog_revision'] or
            bundle['catalog_binding']['execution_catalog_sha256'] != execution_hash):
        raise ValueError('Muscle execution catalog mismatch')
    variants = {v['id']: v for v in catalog['variants']}
    profiles = {p['variant_id']: p for p in bundle['profiles']}
    if set(profiles) != set(variants) or len(profiles) != len(bundle['profiles']):
        raise ValueError('Incomplete exact muscle profiles')
    assessments = {a['id']: a for a in bundle['assessments']}
    for execution in executions:
        p = profiles[execution['variant_id']]
        a = assessments.get(p['assessment_id'])
        if (p['variant_revision'] != execution['variant_revision'] or p['execution_sha256'] != digest(execution) or
                a is None or a['profile_sha256'] != digest(p) or a['profile_id'] != p['id'] or
                a['profile_revision'] != p['revision'] or a['execution_sha256'] != p['execution_sha256']):
            raise ValueError('Invalid muscle profile assessment binding')
    _validate_semantics(catalog, bundle, scopes)


def _search_after_declaration(declared, searched):
    # Same UTC timestamp is allowed. A date-only capture loses within-day order.
    return declared <= searched if 'T' in searched else declared[:10] < searched


def _role_valid(row):
    return ((row['kind'] == 'strength' and row['role'] in ('primary', 'secondary', 'stabilizer')) or
            (row['kind'] in ('stretch_target', 'mobility_target', 'conditioning_participation') and row['role'] is None))


def _index(rows, key='id'):
    result = {row[key]: row for row in rows}
    if len(result) != len(rows):
        raise ValueError('Duplicate muscle admission identity')
    return result


def _validate_semantics(catalog, bundle, scopes):
    sources, claims = _index(bundle['sources']), _index(bundle['claims'])
    nodes, variants = _index(bundle['anatomy']['nodes']), _index(catalog['variants'])
    assessments = _index(bundle['assessments'])
    registry = {(s['id'], s['revision']): s for s in scopes['scopes']}
    for c in claims.values():
        source = sources.get(c['source_id'])
        if (source is None or c['url'] != source['url'] or
                (c['anatomy_node_id'] is not None and
                 (c['anatomy_node_id'] not in nodes or c['granularity'] != nodes[c['anatomy_node_id']]['kind']))):
            raise ValueError('Invalid precise evidence source or granularity')
        if c['claim_kind'] == 'anatomy_action':
            if (any(c[k] is not None for k in ('variant_id', 'variant_revision', 'execution_sha256', 'kind', 'role')) or c['anatomy_node_id'] is None):
                raise ValueError('General anatomy claim asserts execution role')
        else:
            v = variants.get(c['variant_id'])
            execution = None if v is None else {'variant_id': v['id'], 'variant_revision': v['revision'],
                                                **{k: v[k] for k in ('family_id', 'equipment_kind', 'facets', 'measurement_profile')}}
            if v is None or c['variant_revision'] != v['revision'] or c['execution_sha256'] != digest(execution):
                raise ValueError('Evidence execution mismatch')
            if c['claim_kind'] == 'execution_mechanics':
                if any(c[k] is not None for k in ('anatomy_node_id', 'kind', 'role')) or c['granularity'] != 'movement_only':
                    raise ValueError('Mechanics claim asserts anatomical role')
            elif c['anatomy_node_id'] is None or not _role_valid(c):
                raise ValueError('Invalid relationship claim kind or role')
    for p in bundle['profiles']:
        a = assessments[p['assessment_id']]
        scope = registry.get((p['scope_ref']['id'], p['scope_ref']['revision']))
        if scope is None or p['scope_ref']['sha256'] != digest(scope):
            raise ValueError('Untrusted profile scope')
        cells, relations = _index(scope['cells']), _index(p['relationships'])
        if len({r['cell_id'] for r in relations.values()}) != len(relations):
            raise ValueError('Duplicate relationship scope cell')
        for r in relations.values():
            cell = cells.get(r['cell_id'])
            if cell is None or any(r[k] != cell[k] for k in ('anatomy_node_id', 'kind', 'role')) or not _role_valid(r):
                raise ValueError('Relationship outside declared scope')
            if len(set(r['claim_ids'])) != len(r['claim_ids']) or any(i not in claims for i in r['claim_ids']):
                raise ValueError('Unknown or duplicate relationship claim')
            linked = [claims[i] for i in r['claim_ids']]
            if any(c['access_result'] != 'accessible' or c['support_status'] != 'supports' or sources[c['source_id']]['publication_status'] != 'current' for c in linked):
                raise ValueError('Unavailable relationship evidence')
            target = [c for c in linked if all(c[k] == p[k] for k in ('variant_id', 'variant_revision', 'execution_sha256'))]
            if r['evidence_basis'] == 'direct':
                if r['reasoning_chain'] or not any(c['claim_kind'] == 'execution_relationship' and c['exact_setup_match'] and all(c[k] == r[k] for k in ('anatomy_node_id', 'kind', 'role')) and c['action'] == cell['action'] for c in target):
                    raise ValueError('Missing direct relationship evidence')
            elif (len(r['reasoning_chain']) < 2 or
                  not any(c['claim_kind'] == 'execution_mechanics' and c['action'] == cell['action'] for c in target) or
                  not any(c['claim_kind'] == 'anatomy_action' and c['anatomy_node_id'] == r['anatomy_node_id'] and c['action'] == cell['action'] for c in linked)):
                raise ValueError('Missing inference evidence')
            criteria = r['confidence_criteria']
            source_ids = {c['source_id'] for c in linked}
            if set(criteria['independent_source_ids']) != source_ids:
                raise ValueError('Confidence source mismatch')
            if r['confidence'] == 'high' and (len({sources[i]['publisher_id'] for i in source_ids}) < 2 or not criteria['exact_execution_supported'] or criteria['material_conflict']):
                raise ValueError('Unsupported high confidence')
            if r['confidence'] == 'low' and not criteria['limitations']:
                raise ValueError('Low confidence needs limitations')
        dispositions = _index(a['dispositions'], 'cell_id')
        if not set(dispositions) <= cells.keys():
            raise ValueError('Disposition outside declared scope')
        unresolved = set(cells) - dispositions.keys()
        for d in dispositions.values():
            cell = cells[d['cell_id']]
            if any(i not in claims for i in d['claim_ids']):
                raise ValueError('Unknown disposition claim')
            matching = {r['id'] for r in relations.values() if r['cell_id'] == d['cell_id']}
            if d['status'] == 'supported':
                linked_ids = {i for ident in matching for i in relations[ident]['claim_ids']}
                if not matching or set(d['relationship_ids']) != matching or set(d['claim_ids']) != linked_ids or d['next_evidence_needed'] is not None:
                    raise ValueError('Unsupported scope closure evidence')
            elif d['status'] == 'excluded':
                linked = [claims[i] for i in d['claim_ids']]
                if (d['relationship_ids'] or matching or not linked or d['next_evidence_needed'] is not None or
                        any(c['claim_kind'] != 'scope_exclusion' or c['access_result'] != 'accessible' or c['support_status'] != 'supports' or
                            sources[c['source_id']]['publication_status'] != 'current' or not c['exact_setup_match'] or
                            any(c[k] != p[k] for k in ('variant_id', 'variant_revision', 'execution_sha256')) or
                            any(c[k] != cell[k] for k in ('anatomy_node_id', 'kind', 'role', 'action')) for c in linked)):
                    raise ValueError('Missing exact affirmative exclusion')
            else:
                unresolved.add(d['cell_id'])
                if d['relationship_ids'] or not d['next_evidence_needed']:
                    raise ValueError('Unresolved scope cell needs evidence gap')
        gaps = any(a[k] for k in ('unresolved', 'contradictions', 'omitted_claims'))
        if p['coverage'] == 'complete':
            if (a['assessment_status'] != 'assessed' or unresolved or gaps or not a['closure_rationale'] or
                    a['reconciliation']['status'] != 'accepted' or a['reconciliation']['reviewed_on'] is None or
                    a['researcher_id'] == a['reconciler_id'] or not _search_after_declaration(scope['declared_on'], a['searched_on'])):
                raise ValueError('Unclosed complete scope')
        elif not unresolved and not gaps:
            raise ValueError('Incomplete assessment needs explicit gaps')
        if ((not relations) != (p['coverage'] == 'unknown') or
                (a['assessment_status'] == 'pending' and (relations or p['coverage'] != 'unknown'))):
            raise ValueError('Coverage does not match admitted relationships')
