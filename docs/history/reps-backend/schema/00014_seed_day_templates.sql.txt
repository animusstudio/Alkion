-- +goose Up
-- Seed the 4 README split days as shared templates (is_template=TRUE,
-- created_by=NULL). Idempotent via ON CONFLICT (slug) DO NOTHING. RIR ranges are
-- stored low..high (e.g. README "1-0" -> rir_low 0, rir_high 1).
INSERT INTO day_templates (slug, name, notes, position, is_template, created_by) VALUES
    ('upper-a', 'Upper A', 'Push focus',      1, TRUE, NULL),
    ('lower-a', 'Lower A', 'Quad + calf',     2, TRUE, NULL),
    ('upper-b', 'Upper B', 'Pull focus',      3, TRUE, NULL),
    ('lower-b', 'Lower B', 'Posterior chain', 4, TRUE, NULL)
ON CONFLICT (slug) DO NOTHING;

-- Items: resolve day_template + exercise by slug. Idempotent via NOT EXISTS.
INSERT INTO day_template_items
    (day_template_id, exercise_id, position, target_warmup_sets, target_working_sets,
     target_rep_low, target_rep_high, target_rir_low, target_rir_high, is_template, created_by)
SELECT dt.id, ex.id, v.position, v.warm, v.work, v.rlow, v.rhigh, v.rirlow, v.rirhigh, TRUE, NULL
FROM (VALUES
    -- Upper A (push)
    ('upper-a','incline-bench-press',      1, 2, 4,  6,  8, 0, 1),
    ('upper-a','chest-press',              2, 0, 3,  8, 10, 1, 1),
    ('upper-a','seated-db-shoulder-press', 3, 0, 3,  8, 10, 1, 1),
    ('upper-a','db-lateral-raise',         4, 0, 3, 10, 12, 1, 1),
    ('upper-a','reverse-pec-deck',         5, 0, 3, 12, 15, 1, 1),
    ('upper-a','rope-triceps-pushdown',    6, 0, 3, 10, 12, 1, 1),
    ('upper-a','overhead-rope-extension',  7, 0, 3, 10, 12, 1, 1),
    -- Lower A (quad + calf)
    ('lower-a','hack-squat',               1, 2, 4,  6,  8, 0, 1),
    ('lower-a','leg-press',                2, 0, 3, 10, 12, 1, 1),
    ('lower-a','leg-extension',            3, 0, 3, 10, 12, 1, 1),
    ('lower-a','seated-leg-curl',          4, 0, 3,  8, 10, 1, 1),
    ('lower-a','standing-calf-raise',      5, 0, 4, 10, 12, 0, 1),
    -- Upper B (pull)
    ('upper-b','lat-pulldown',             1, 2, 4,  6,  8, 0, 1),
    ('upper-b','row',                      2, 0, 4,  8, 10, 1, 1),
    ('upper-b','iliac-pulldown',           3, 0, 3, 10, 12, 1, 1),
    ('upper-b','cable-row',                4, 0, 3, 10, 12, 1, 1),
    ('upper-b','preacher-curl',            5, 0, 3,  8, 10, 1, 1),
    ('upper-b','cable-hammer-curl',        6, 0, 3, 10, 12, 1, 1),
    ('upper-b','cable-curl',               7, 0, 3, 12, 15, 0, 1),
    -- Lower B (posterior chain)
    ('lower-b','romanian-deadlift',        1, 2, 4,  6,  8, 1, 1),
    ('lower-b','hack-squat-depth-focus',   2, 0, 3, 10, 12, 1, 1),
    ('lower-b','lying-leg-curl',           3, 0, 4,  8, 10, 1, 1),
    ('lower-b','unilateral-leg-extension', 4, 0, 3, 12, 15, 0, 1),
    ('lower-b','seated-calf-raise',        5, 0, 4, 12, 15, 0, 1)
) AS v(dt_slug, ex_slug, position, warm, work, rlow, rhigh, rirlow, rirhigh)
JOIN day_templates dt ON dt.slug = v.dt_slug
JOIN exercises ex ON ex.slug = v.ex_slug
WHERE NOT EXISTS (
    SELECT 1 FROM day_template_items i WHERE i.day_template_id = dt.id AND i.exercise_id = ex.id
);

-- +goose Down
DELETE FROM day_template_items WHERE is_template = TRUE AND created_by IS NULL;
DELETE FROM day_templates WHERE slug IN ('upper-a','lower-a','upper-b','lower-b')
    AND is_template = TRUE AND created_by IS NULL;
