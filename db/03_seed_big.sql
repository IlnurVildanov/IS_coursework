\set ON_ERROR_STOP on

\set p_clinics 15
\set p_labs 10
\set p_rooms_per_clinic 50

\set p_doctors 1200
\set p_patients 250000

\set p_days 120
\set p_slot_minutes 20
\set p_book_rate 0.35

\set p_extra_audit 12000000

\set p_lab_tests 200
\set p_lab_orders 200000
\set p_lab_transfers 50000

INSERT INTO roles(code) VALUES
  ('ADMIN'),
  ('DOCTOR'),
  ('PATIENT')
ON CONFLICT (code) DO NOTHING;

WITH ins AS (
  INSERT INTO facilities(name, type)
  SELECT 'Клиника '||gs, 'CLINIC'::facility_type
  FROM generate_series(1, :p_clinics) gs
  RETURNING id
)
INSERT INTO facility_addresses(facility_id, address_line, valid_from, valid_to)
SELECT id, 'Город, улица Клиник, д.'||id, (current_date - 365), NULL
FROM ins;

WITH ins AS (
  INSERT INTO facilities(name, type)
  SELECT 'Лаборатория '||gs, 'LAB'::facility_type
  FROM generate_series(1, :p_labs) gs
  RETURNING id
)
INSERT INTO facility_addresses(facility_id, address_line, valid_from, valid_to)
SELECT id, 'Город, улица Лаб, д.'||id, (current_date - 365), NULL
FROM ins;

INSERT INTO facility_addresses(facility_id, address_line, valid_from, valid_to)
SELECT f.id,
       'Старый адрес (переезд) #'||f.id,
       current_date - 900,
       current_date - 365
FROM facilities f
WHERE (f.id % 5) = 0;

WITH clinics AS (
  SELECT id FROM facilities WHERE type='CLINIC'::facility_type ORDER BY id LIMIT :p_clinics
)
INSERT INTO rooms(facility_id, room_number)
SELECT c.id, lpad(gs::text, 3, '0')
FROM clinics c
CROSS JOIN generate_series(1, :p_rooms_per_clinic) gs
ON CONFLICT DO NOTHING;

INSERT INTO specialties(name) VALUES
  ('Терапевт'),('Хирург'),('Невролог'),('Кардиолог'),('Офтальмолог'),
  ('ЛОР'),('Педиатр'),('Дерматолог'),('Эндокринолог'),('Уролог')
ON CONFLICT (name) DO NOTHING;

INSERT INTO services(name, duration_min, base_price) VALUES
  ('Первичный приём', 30, 1500),
  ('Повторный приём', 20, 1200),
  ('Консультация', 20, 900),
  ('Процедура', 40, 2000)
ON CONFLICT (name) DO NOTHING;

WITH ins AS (
  INSERT INTO users(email, password_hash, full_name, phone)
  SELECT 'admin@example.com','bcrypt$dummy','Администратор','+7-900-0000000'
  WHERE NOT EXISTS (SELECT 1 FROM users WHERE email='admin@example.com')
  RETURNING id
)
INSERT INTO user_roles(user_id, role_id)
SELECT
  COALESCE((SELECT id FROM ins), (SELECT id FROM users WHERE email='admin@example.com')),
  (SELECT id FROM roles WHERE code='ADMIN')
ON CONFLICT DO NOTHING;

WITH clinics AS (
  SELECT id, row_number() OVER (ORDER BY id) AS rn
  FROM facilities
  WHERE type='CLINIC'::facility_type
  ORDER BY id
  LIMIT :p_clinics
),
new_doctor_users AS (
  INSERT INTO users(email, password_hash, full_name, phone)
  SELECT
    'doctor'||gs||'@example.com',
    'bcrypt$dummy',
    'Врач '||gs::text,
    '+7-901-'||lpad((100000 + (gs % 900000))::text, 6, '0')
  FROM generate_series(1, :p_doctors) gs
  RETURNING id
),
doc_users AS (
  SELECT u.id AS user_id, row_number() OVER (ORDER BY u.id) AS rn
  FROM new_doctor_users u
),
doc_rows AS (
  SELECT
    du.user_id,
    c.id AS facility_id
  FROM doc_users du
  JOIN clinics c
    ON c.rn = ((du.rn - 1) % (SELECT count(*) FROM clinics)) + 1
),
ins_doctors AS (
  INSERT INTO doctors(user_id, facility_id, default_room_id, active)
  SELECT
    dr.user_id,
    dr.facility_id,
    (SELECT r.id
     FROM rooms r
     WHERE r.facility_id = dr.facility_id
     ORDER BY random()
     LIMIT 1),
    TRUE
  FROM doc_rows dr
  RETURNING id, user_id
)
INSERT INTO user_roles(user_id, role_id)
SELECT d.user_id, (SELECT id FROM roles WHERE code='DOCTOR')
FROM ins_doctors d
ON CONFLICT DO NOTHING;

INSERT INTO doctor_specialties(doctor_id, specialty_id)
SELECT d.id, 1 + (random()*9)::int
FROM doctors d
ON CONFLICT DO NOTHING;

INSERT INTO doctor_specialties(doctor_id, specialty_id)
SELECT d.id, 1 + (random()*9)::int
FROM doctors d
WHERE random() < 0.55
ON CONFLICT DO NOTHING;

INSERT INTO doctor_services(doctor_id, service_id, price_override)
SELECT d.id, 1 + (random()*3)::int, NULL
FROM doctors d
ON CONFLICT DO NOTHING;

INSERT INTO doctor_services(doctor_id, service_id, price_override)
SELECT d.id, 1 + (random()*3)::int, NULL
FROM doctors d
WHERE random() < 0.70
ON CONFLICT DO NOTHING;

WITH new_patient_users AS (
  INSERT INTO users(email, password_hash, full_name, phone)
  SELECT
    'patient'||gs||'@example.com',
    'bcrypt$dummy',
    'Пациент '||gs::text,
    '+7-902-'||lpad((100000 + (gs % 900000))::text, 6, '0')
  FROM generate_series(1, :p_patients) gs
  RETURNING id
),
ins_patients AS (
  INSERT INTO patients(user_id, birth_date)
  SELECT id, date '1970-01-01' + ((random()*18000)::int)
  FROM new_patient_users
  RETURNING id, user_id
)
INSERT INTO user_roles(user_id, role_id)
SELECT p.user_id, (SELECT id FROM roles WHERE code='PATIENT')
FROM ins_patients p
ON CONFLICT DO NOTHING;

WITH days AS (
  SELECT (current_date + 1 + gs)::date AS day
  FROM generate_series(0, :p_days-1) gs
),
times AS (
  SELECT gs::time AS t
  FROM generate_series(
    timestamp '2000-01-01 09:00',
    timestamp '2000-01-01 16:40',
    make_interval(mins => :p_slot_minutes)
  ) AS gs
)
INSERT INTO schedule_slots(doctor_id, room_id, start_at, end_at, status)
SELECT
  d.id,
  COALESCE(d.default_room_id, (SELECT r.id FROM rooms r WHERE r.facility_id = d.facility_id ORDER BY r.id LIMIT 1)),
  (days.day + times.t)::timestamptz,
  (days.day + times.t + make_interval(mins => :p_slot_minutes))::timestamptz,
  CASE
    WHEN random() < 0.04 THEN 'CLOSED'::slot_status
    ELSE 'FREE'::slot_status
  END
FROM doctors d
CROSS JOIN days
CROSS JOIN times
ON CONFLICT DO NOTHING;

WITH slots_to_book AS (
  SELECT s.id AS slot_id, s.doctor_id
  FROM schedule_slots s
  WHERE s.status = 'FREE'::slot_status
    AND s.start_at >= (CURRENT_TIMESTAMP + interval '10 minutes')
    AND random() < :p_book_rate
)
INSERT INTO appointments(slot_id, patient_id, doctor_id, status)
SELECT
  stb.slot_id,
  ((stb.slot_id % (SELECT max(id) FROM patients)) + 1),
  stb.doctor_id,
  'BOOKED'::appointment_status
FROM slots_to_book stb;

INSERT INTO appointment_services(appointment_id, service_id, qty)
SELECT a.id, 1 + (random()*3)::int, 1
FROM appointments a
WHERE random() < 0.92
ON CONFLICT DO NOTHING;

INSERT INTO audit_events(event_at, actor_user_id, entity_type, entity_id, action, meta)
SELECT
  CURRENT_TIMESTAMP - make_interval(secs => (random()*86400*30)::int),
  NULL,
  'SYSTEM',
  NULL,
  CASE WHEN random() < 0.5 THEN 'HEARTBEAT' ELSE 'METRICS' END,
  jsonb_build_object('i', gs, 'x', md5(gs::text))
FROM generate_series(1, :p_extra_audit) gs;

SELECT fn_upsert_pharmacy_cache(
  'symptom:cold|age:adult',
  jsonb_build_object('items', jsonb_build_array(
    jsonb_build_object('name','Пример препарата','form','таблетки','price','~300')
  ))
);

INSERT INTO lab_tests(code, name, description)
SELECT
  'T' || lpad(gs::text, 4, '0'),
  'Анализ ' || gs,
  'Описание анализа ' || gs
FROM generate_series(1, :p_lab_tests) gs
ON CONFLICT (code) DO NOTHING;

WITH clinics AS (
  SELECT id FROM facilities WHERE type='CLINIC'::facility_type ORDER BY id LIMIT :p_clinics
),
labs AS (
  SELECT id FROM facilities WHERE type='LAB'::facility_type ORDER BY id LIMIT :p_labs
),
ins AS (
  INSERT INTO lab_orders(
    patient_id, status, requested_at,
    source_facility_id, performing_facility_id,
    referral_appointment_id, comment
  )
  SELECT
    1 + (gs % :p_patients) AS patient_id,
    CASE
      WHEN gs % 10 < 6 THEN 'CREATED'
      WHEN gs % 10 < 8 THEN 'IN_PROGRESS'
      WHEN gs % 10 < 9 THEN 'DONE'
      ELSE 'CANCELLED'
    END::lab_order_status AS status,
    CURRENT_TIMESTAMP - make_interval(days => (gs % 180)) AS requested_at,
    (SELECT id FROM clinics OFFSET (gs % (SELECT count(*) FROM clinics)) LIMIT 1) AS source_facility_id,
    (SELECT id FROM labs OFFSET (gs % (SELECT count(*) FROM labs)) LIMIT 1) AS performing_facility_id,
    CASE WHEN gs % 5 = 0 THEN NULL ELSE (1 + (gs % (SELECT GREATEST(COALESCE(max(id), 1), 1) FROM appointments))) END AS referral_appointment_id,
    CASE WHEN gs % 7 = 0 THEN 'Без консультации (принесли анализы)' ELSE NULL END AS comment
  FROM generate_series(1, :p_lab_orders) gs
  RETURNING id
)
INSERT INTO lab_order_items(lab_order_id, lab_test_id, qty)
SELECT
  o.id,
  1 + ((o.id + t) % :p_lab_tests) AS lab_test_id,
  1
FROM ins o
CROSS JOIN generate_series(1, 2) t
ON CONFLICT DO NOTHING;

INSERT INTO lab_results(lab_order_item_id, result_payload, created_at, comment)
SELECT
  i.id,
  jsonb_build_object(
    'value', round((random()*100)::numeric, 2),
    'unit', CASE WHEN (i.lab_test_id % 3)=0 THEN 'mg/dL'
                 WHEN (i.lab_test_id % 3)=1 THEN 'mmol/L'
                 ELSE 'unit' END
  ),
  CURRENT_TIMESTAMP,
  NULL
FROM lab_order_items i
WHERE (i.lab_order_id % 3) = 0;

WITH labs AS (
  SELECT id FROM facilities WHERE type='LAB'::facility_type ORDER BY id LIMIT :p_labs
),
src AS (
  SELECT o.id AS lab_order_id, o.performing_facility_id, o.requested_at
  FROM lab_orders o
  WHERE o.id <= :p_lab_transfers
)
INSERT INTO lab_transfers(lab_order_id, from_facility_id, to_facility_id, status, transferred_at, reason)
SELECT
  s.lab_order_id,
  s.performing_facility_id AS from_facility_id,
  (SELECT id FROM labs WHERE id <> s.performing_facility_id ORDER BY id DESC LIMIT 1) AS to_facility_id,
  'SENT'::lab_transfer_status,
  s.requested_at + interval '2 hours',
  'Перенаправление на другую лабораторию'
FROM src s;

VACUUM (ANALYZE);