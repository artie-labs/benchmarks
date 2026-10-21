-- One steady-workload batch for local.sh, run with: psql -v anchor=2026-10-20 -v rpd=100000 -v k=0
-- The same shape as run.sh's recent batch: 300 inserts, 150 updates to rows from the anchor day, and 50 deletes of
-- rows from the day before. k runs on across arms, so each batch changes different rows.
BEGIN;
INSERT INTO activity
SELECT md5('insert-' || :k || '-' || i), now(), 'inserted_' || :k, jsonb_build_object('seq', i, 'note', repeat('x', 400))
FROM generate_series(1, 300) i;

UPDATE activity SET status = 'updated_' || :k, payload = payload || jsonb_build_object('status', 'updated_' || :k)
WHERE uuid IN (SELECT md5(date :'anchor'::text || '-' || n) FROM generate_series(:k * 150 + 1, :k * 150 + 150) n);

DELETE FROM activity
WHERE uuid IN (SELECT md5((date :'anchor' - 1)::text || '-' || n) FROM generate_series(:rpd - (:k + 1) * 50 + 1, :rpd - :k * 50) n);
COMMIT;
