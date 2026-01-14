-- запуск бенчмарка с индексами
\set ON_ERROR_STOP on
\timing on

SET max_parallel_workers_per_gather = 0;
SET parallel_setup_cost = 1000000000;
SET parallel_tuple_cost = 1000000000;
SET min_parallel_table_scan_size = '1TB';
SET min_parallel_index_scan_size = '1TB';
SET jit = off;

TRUNCATE bench_runs;
ANALYZE;

CALL bench_explain(
  'WITH_INDEX',
  'patient_my_appointments',
  $$SELECT a.id, a.created_at, a.status
    FROM appointments a
    WHERE a.patient_id = (SELECT id FROM patients ORDER BY id DESC LIMIT 1)
    ORDER BY a.created_at DESC
    LIMIT 30$$
);

CALL bench_explain(
  'WITH_INDEX',
  'available_slots_for_doctor',
  $$SELECT s.id, s.start_at, s.end_at
    FROM schedule_slots s
    WHERE s.doctor_id = (SELECT id FROM doctors ORDER BY id DESC LIMIT 1)
      AND s.status='FREE'
      AND s.start_at >= CURRENT_DATE
      AND s.start_at <  CURRENT_DATE + INTERVAL '14 day'
    ORDER BY s.start_at$$
);

CALL bench_explain(
  'WITH_INDEX',
  'admin_doctor_appointments_period',
  $$SELECT a.id, a.status, s.start_at
    FROM appointments a
    JOIN schedule_slots s ON s.id=a.slot_id
    WHERE a.doctor_id = (SELECT id FROM doctors ORDER BY id DESC LIMIT 1)
      AND s.start_at >= CURRENT_DATE
      AND s.start_at < CURRENT_DATE + INTERVAL '30 day'
    ORDER BY s.start_at DESC$$
);

CALL bench_explain(
  'WITH_INDEX',
  'patient_lab_orders',
  $$SELECT o.id, o.status, o.requested_at
    FROM lab_orders o
    WHERE o.patient_id = (SELECT id FROM patients ORDER BY id DESC LIMIT 1)
    ORDER BY o.requested_at DESC
    LIMIT 50$$
);

CALL bench_explain(
  'WITH_INDEX',
  'lab_incoming_transfers',
  $$SELECT t.id, t.status, t.transferred_at, t.lab_order_id
    FROM lab_transfers t
    WHERE t.to_facility_id = (SELECT id FROM facilities WHERE type='LAB' ORDER BY id DESC LIMIT 1)
      AND t.status = 'SENT'
    ORDER BY t.transferred_at DESC
    LIMIT 50$$
);

SELECT
  label,
  scenario,
  count(*) FILTER (WHERE phase='measure') AS n,
  round((avg(exec_ms) FILTER (WHERE phase='measure'))::numeric, 3) AS avg_ms,
  round((percentile_cont(0.5) WITHIN GROUP (ORDER BY exec_ms)
        FILTER (WHERE phase='measure'))::numeric, 3) AS median_ms,
  round((percentile_cont(0.95) WITHIN GROUP (ORDER BY exec_ms)
        FILTER (WHERE phase='measure'))::numeric, 3) AS p95_ms
FROM bench_runs
GROUP BY label, scenario
ORDER BY scenario, label;