-- Drops and recreates the benchmark schema. Each tool's warehouse and objects come from setup_<tool>.sql, which
-- bench.sh runs afterwards for the tools in TOOLS (plugin tools use their sf_setup hook). Some tools create their own
-- tables.
-- Variables: db, schema.

DROP SCHEMA IF EXISTS <% db %>.<% schema %> CASCADE;
CREATE SCHEMA <% db %>.<% schema %>;
-- Every table created in the schema from here on gets row timestamps (METADATA$ROW_LAST_COMMIT_TIME), which the
-- latency queries read. That includes the tables the tools create themselves. Tables that already exist aren't affected,
-- so this must run before anything creates a table.
ALTER SCHEMA <% db %>.<% schema %> SET ROW_TIMESTAMP_DEFAULT = TRUE;
USE SCHEMA <% db %>.<% schema %>;
