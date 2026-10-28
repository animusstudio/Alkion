-- +goose Up
-- Backfill focus + scheduled_weekday on the 4 seeded shared days. 00014 put the
-- focus text into the notes column and never set scheduled_weekday; the columns
-- (added in 00017) are still NULL on these rows. Weekday is Mon=0..Sun=6.
UPDATE day_templates SET focus='Push',            scheduled_weekday=0 WHERE slug='upper-a';
UPDATE day_templates SET focus='Quad + Calf',     scheduled_weekday=1 WHERE slug='lower-a';
UPDATE day_templates SET focus='Pull',            scheduled_weekday=3 WHERE slug='upper-b';
UPDATE day_templates SET focus='Posterior Chain', scheduled_weekday=4 WHERE slug='lower-b';

-- +goose Down
UPDATE day_templates SET focus=NULL, scheduled_weekday=NULL
  WHERE slug IN ('upper-a','lower-a','upper-b','lower-b');
