-- бенчмарк для обоснования полезности индексов
\set ON_ERROR_STOP on

CREATE TABLE IF NOT EXISTS bench_runs (
  id        BIGSERIAL PRIMARY KEY,
  label     TEXT NOT NULL,
  scenario  TEXT NOT NULL,
  run_no    INT NOT NULL,
  phase     TEXT NOT NULL,
  exec_ms   NUMERIC(12,3) NOT NULL,
  plan      JSONB NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE OR REPLACE PROCEDURE bench_explain(
  p_label TEXT,
  p_scenario TEXT,
  p_sql TEXT,
  p_runs INT DEFAULT 20,
  p_warmup INT DEFAULT 5
)
LANGUAGE plpgsql
AS $$
DECLARE
  i INT;
  v_plan JSON;
  v_exec_ms NUMERIC;
  v_phase TEXT;
BEGIN
  FOR i IN 1..p_runs LOOP
    IF i <= p_warmup THEN v_phase := 'warmup'; ELSE v_phase := 'measure'; END IF;

    EXECUTE 'EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) ' || p_sql INTO v_plan;
    v_exec_ms := ((v_plan->0)->>'Execution Time')::numeric;

    INSERT INTO bench_runs(label, scenario, run_no, phase, exec_ms, plan)
    VALUES (p_label, p_scenario, i, v_phase, v_exec_ms, v_plan::jsonb);
  END LOOP;
END $$;