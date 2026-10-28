-- +goose Up
-- Publish the new tables so their changes enter the replication stream. sessions
-- is already published (00009); adding a column to it needs no re-publish.
ALTER PUBLICATION powersync ADD TABLE day_templates;
ALTER PUBLICATION powersync ADD TABLE day_template_items;

-- +goose Down
ALTER PUBLICATION powersync DROP TABLE day_template_items;
ALTER PUBLICATION powersync DROP TABLE day_templates;
