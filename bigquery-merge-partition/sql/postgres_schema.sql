-- Source table for local.sh, run with: psql -v anchor=2026-10-20 -v rpd=100000
-- It holds the two days the workload touches (the anchor day and the day before), with the same uuid and created_at
-- as daily_1095 in BigQuery: uuid = md5('<date>-<n>'), created_at spreads n = 1..rpd evenly over the day.

SET client_min_messages = warning;

-- Drop Reader's slots and publications from an earlier run, so the seed rows aren't streamed.
\o /dev/null
SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name LIKE 'bench%';
\o
DROP PUBLICATION IF EXISTS bench_slot, bench_drain_raw, bench_drain_json;

DROP TABLE IF EXISTS activity;
CREATE TABLE activity (
  uuid text PRIMARY KEY,
  created_at timestamptz NOT NULL,
  status text,
  payload jsonb
);
-- Deletes carry every column, including created_at, so Transfer can build the partition predicate for them.
ALTER TABLE activity REPLICA IDENTITY FULL;

INSERT INTO activity
SELECT md5(d::date::text || '-' || n),
  (d::timestamp AT TIME ZONE 'UTC') + make_interval(secs => (n - 1)::bigint * 86400 / :rpd),
  'created',
  jsonb_build_object('seq', n, 'note', repeat('x', 400))
FROM generate_series(date :'anchor' - 1, date :'anchor', interval '1 day') d, generate_series(1, :rpd) n;
