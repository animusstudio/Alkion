-- +goose Up
UPDATE exercises SET equip='Panatta', compound=TRUE, base_weight_kg=72.5, plate_step_kg=2.5, default_rep_low=6, default_rep_high=8, default_warmup_sets=2, default_working_sets=4, default_rir_low=0, default_rir_high=1 WHERE slug='incline-bench-press';
UPDATE exercises SET equip='Horizontal', compound=FALSE, base_weight_kg=64, plate_step_kg=2.0, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='chest-press';
UPDATE exercises SET equip='Dumbbell', compound=FALSE, base_weight_kg=24, plate_step_kg=2.0, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='seated-db-shoulder-press';
UPDATE exercises SET equip='Dumbbell', compound=FALSE, base_weight_kg=11, plate_step_kg=1.0, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='db-lateral-raise';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=40, plate_step_kg=2.5, default_rep_low=12, default_rep_high=15, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='reverse-pec-deck';
UPDATE exercises SET equip='Cable', compound=FALSE, base_weight_kg=32, plate_step_kg=2.5, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='rope-triceps-pushdown';
UPDATE exercises SET equip='Cable', compound=FALSE, base_weight_kg=27, plate_step_kg=2.5, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='overhead-rope-extension';
UPDATE exercises SET equip='Machine', compound=TRUE, base_weight_kg=120, plate_step_kg=5.0, default_rep_low=6, default_rep_high=8, default_warmup_sets=2, default_working_sets=4, default_rir_low=0, default_rir_high=1 WHERE slug='hack-squat';
UPDATE exercises SET equip='Feet high/wide', compound=FALSE, base_weight_kg=200, plate_step_kg=5.0, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='leg-press';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=60, plate_step_kg=5.0, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='leg-extension';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=55, plate_step_kg=5.0, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='seated-leg-curl';
UPDATE exercises SET equip='Weighted', compound=FALSE, base_weight_kg=90, plate_step_kg=5.0, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=4, default_rir_low=0, default_rir_high=1 WHERE slug='standing-calf-raise';
UPDATE exercises SET equip='Wide pronated', compound=TRUE, base_weight_kg=75, plate_step_kg=2.5, default_rep_low=6, default_rep_high=8, default_warmup_sets=2, default_working_sets=4, default_rir_low=0, default_rir_high=1 WHERE slug='lat-pulldown';
UPDATE exercises SET equip='Panatta, wide', compound=FALSE, base_weight_kg=80, plate_step_kg=5.0, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=4, default_rir_low=1, default_rir_high=1 WHERE slug='row';
UPDATE exercises SET equip='Close neutral', compound=FALSE, base_weight_kg=60, plate_step_kg=2.5, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='iliac-pulldown';
UPDATE exercises SET equip='Close neutral', compound=FALSE, base_weight_kg=65, plate_step_kg=2.5, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='cable-row';
UPDATE exercises SET equip='Barbell', compound=FALSE, base_weight_kg=32, plate_step_kg=2.5, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='preacher-curl';
UPDATE exercises SET equip='Cable', compound=FALSE, base_weight_kg=27, plate_step_kg=2.5, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='cable-hammer-curl';
UPDATE exercises SET equip='Cable', compound=FALSE, base_weight_kg=22, plate_step_kg=2.5, default_rep_low=12, default_rep_high=15, default_warmup_sets=0, default_working_sets=3, default_rir_low=0, default_rir_high=1 WHERE slug='cable-curl';
UPDATE exercises SET equip='Barbell', compound=TRUE, base_weight_kg=100, plate_step_kg=2.5, default_rep_low=6, default_rep_high=8, default_warmup_sets=2, default_working_sets=4, default_rir_low=1, default_rir_high=1 WHERE slug='romanian-deadlift';
UPDATE exercises SET equip='Depth focus', compound=FALSE, base_weight_kg=90, plate_step_kg=5.0, default_rep_low=10, default_rep_high=12, default_warmup_sets=0, default_working_sets=3, default_rir_low=1, default_rir_high=1 WHERE slug='hack-squat-depth-focus';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=50, plate_step_kg=5.0, default_rep_low=8, default_rep_high=10, default_warmup_sets=0, default_working_sets=4, default_rir_low=1, default_rir_high=1 WHERE slug='lying-leg-curl';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=30, plate_step_kg=2.5, default_rep_low=12, default_rep_high=15, default_warmup_sets=0, default_working_sets=3, default_rir_low=0, default_rir_high=1 WHERE slug='unilateral-leg-extension';
UPDATE exercises SET equip='Machine', compound=FALSE, base_weight_kg=45, plate_step_kg=5.0, default_rep_low=12, default_rep_high=15, default_warmup_sets=0, default_working_sets=4, default_rir_low=0, default_rir_high=1 WHERE slug='seated-calf-raise';

-- +goose Down
-- Reset traits to defaults (idempotent rollback).
UPDATE exercises SET equip=NULL, compound=FALSE, base_weight_kg=NULL, plate_step_kg=2.5,
  default_rep_low=NULL, default_rep_high=NULL, default_warmup_sets=NULL,
  default_working_sets=NULL, default_rir_low=NULL, default_rir_high=NULL
  WHERE is_template=TRUE;
