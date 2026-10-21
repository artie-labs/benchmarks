-- The drain backlog for local.sh, run with: psql -v anchor=2026-10-20 -v rpd=100000 -v inserts=1000000 -v deletes=10000
-- Updates and deletes touch seeded rows only, so each has a matching row in daily_1095. Deletes start halfway through
-- the day before the anchor, away from the steady arms' deletes at its end. It prints each statement's row count.
DELETE FROM activity
WHERE uuid IN (SELECT md5((date :'anchor' - 1)::text || '-' || n) FROM generate_series(:rpd / 2 + 1, :rpd / 2 + :deletes) n);
\echo deleted :ROW_COUNT

UPDATE activity SET status = 'drained', payload = payload || '{"status": "drained"}'
WHERE status = 'created' OR status LIKE 'updated\_%';
\echo updated :ROW_COUNT

INSERT INTO activity
SELECT md5('drain-' || i), now(), 'drain_inserted', jsonb_build_object('seq', i, 'note', repeat('x', 400))
FROM generate_series(1, :inserts) i;
\echo inserted :ROW_COUNT
