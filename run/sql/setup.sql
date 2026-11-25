-- Drops and recreates the benchmark schema. bench.sh then creates the objects of the tools in TOOLS: setup_dms.sql and
-- setup_debezium.sql, and plugin tools' sf_setup hooks. Some tools create their own tables. Openflow writes to its own
-- database, so it's not affected.
-- Variables: db, schema.

DROP SCHEMA IF EXISTS <% db %>.<% schema %> CASCADE;
CREATE SCHEMA <% db %>.<% schema %>;
-- Every table created in the schema from here on gets row timestamps (METADATA$ROW_LAST_COMMIT_TIME), which the
-- latency queries read. That includes the tables the tools create themselves. Tables that already exist aren't affected,
-- so this must run before anything creates a table.
ALTER SCHEMA <% db %>.<% schema %> SET ROW_TIMESTAMP_DEFAULT = TRUE;
USE SCHEMA <% db %>.<% schema %>;
