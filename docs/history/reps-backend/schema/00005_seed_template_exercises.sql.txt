-- +goose Up
-- Seed the flat list of template exercises from the README training split.
-- Templates have created_by = NULL and is_template = TRUE, so the `templates`
-- sync-rules bucket replicates them to every user as a read-only catalog.
-- Idempotent via ON CONFLICT (slug) DO NOTHING.
INSERT INTO exercises (name, slug, muscle_group, is_template, created_by) VALUES
    ('Incline bench press',       'incline-bench-press',       'chest',     TRUE, NULL),
    ('Chest press',               'chest-press',               'chest',     TRUE, NULL),
    ('Seated DB shoulder press',  'seated-db-shoulder-press',  'shoulders', TRUE, NULL),
    ('DB lateral raise',          'db-lateral-raise',          'shoulders', TRUE, NULL),
    ('Reverse pec deck',          'reverse-pec-deck',          'shoulders', TRUE, NULL),
    ('Rope triceps pushdown',     'rope-triceps-pushdown',     'triceps',   TRUE, NULL),
    ('Overhead rope extension',   'overhead-rope-extension',   'triceps',   TRUE, NULL),
    ('Hack squat',                'hack-squat',                'quads',     TRUE, NULL),
    ('Leg press',                 'leg-press',                 'quads',     TRUE, NULL),
    ('Leg extension',             'leg-extension',             'quads',     TRUE, NULL),
    ('Seated leg curl',           'seated-leg-curl',           'hamstrings',TRUE, NULL),
    ('Standing calf raise',       'standing-calf-raise',       'calves',    TRUE, NULL),
    ('Lat pulldown',              'lat-pulldown',              'back',      TRUE, NULL),
    ('Row',                       'row',                       'back',      TRUE, NULL),
    ('Iliac pulldown',            'iliac-pulldown',            'back',      TRUE, NULL),
    ('Cable row',                 'cable-row',                 'back',      TRUE, NULL),
    ('Preacher curl',             'preacher-curl',             'biceps',    TRUE, NULL),
    ('Cable hammer curl',         'cable-hammer-curl',         'biceps',    TRUE, NULL),
    ('Cable curl',                'cable-curl',                'biceps',    TRUE, NULL),
    ('Romanian deadlift',         'romanian-deadlift',         'hamstrings',TRUE, NULL),
    ('Hack squat (depth focus)',  'hack-squat-depth-focus',    'quads',     TRUE, NULL),
    ('Lying leg curl',            'lying-leg-curl',            'hamstrings',TRUE, NULL),
    ('Unilateral leg extension',  'unilateral-leg-extension',  'quads',     TRUE, NULL),
    ('Seated calf raise',         'seated-calf-raise',         'calves',    TRUE, NULL)
ON CONFLICT (slug) DO NOTHING;

-- +goose Down
DELETE FROM exercises WHERE slug IN (
    'incline-bench-press', 'chest-press', 'seated-db-shoulder-press',
    'db-lateral-raise', 'reverse-pec-deck', 'rope-triceps-pushdown',
    'overhead-rope-extension', 'hack-squat', 'leg-press', 'leg-extension',
    'seated-leg-curl', 'standing-calf-raise', 'lat-pulldown', 'row',
    'iliac-pulldown', 'cable-row', 'preacher-curl', 'cable-hammer-curl',
    'cable-curl', 'romanian-deadlift', 'hack-squat-depth-focus',
    'lying-leg-curl', 'unilateral-leg-extension', 'seated-calf-raise'
) AND is_template = TRUE AND created_by IS NULL;
