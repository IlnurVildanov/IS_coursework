\set ON_ERROR_STOP on

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'facility_type') THEN
    CREATE TYPE facility_type AS ENUM ('CLINIC','LAB');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'slot_status') THEN
    CREATE TYPE slot_status AS ENUM ('FREE','BOOKED','CLOSED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'appointment_status') THEN
    CREATE TYPE appointment_status AS ENUM ('BOOKED','CANCELLED','COMPLETED','NO_SHOW');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lab_order_status') THEN
    CREATE TYPE lab_order_status AS ENUM ('CREATED','IN_PROGRESS','DONE','CANCELLED');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'lab_transfer_status') THEN
    CREATE TYPE lab_transfer_status AS ENUM ('SENT','ACCEPTED','REJECTED');
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS users (
  id            BIGSERIAL PRIMARY KEY,
  email         VARCHAR(255) NOT NULL,
  phone         VARCHAR(32),
  password_hash VARCHAR(255) NOT NULL,
  full_name     VARCHAR(255) NOT NULL,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS roles (
  id   SERIAL PRIMARY KEY,
  code VARCHAR(32) NOT NULL UNIQUE  -- PATIENT / DOCTOR / ADMIN
);

CREATE TABLE IF NOT EXISTS user_roles (
  user_id BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  role_id INT    NOT NULL REFERENCES roles(id) ON DELETE CASCADE,
  PRIMARY KEY (user_id, role_id)
);

CREATE TABLE IF NOT EXISTS facilities (
  id         BIGSERIAL PRIMARY KEY,
  name       VARCHAR(255) NOT NULL,
  type       facility_type NOT NULL,
  is_active  BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS facility_addresses (
  id           BIGSERIAL PRIMARY KEY,
  facility_id  BIGINT NOT NULL REFERENCES facilities(id) ON DELETE CASCADE,
  address_line VARCHAR(500) NOT NULL,
  valid_from   DATE NOT NULL,
  valid_to     DATE,
  CHECK (valid_to IS NULL OR valid_to > valid_from)
);

CREATE TABLE IF NOT EXISTS rooms (
  id          SERIAL PRIMARY KEY,
  facility_id BIGINT NOT NULL REFERENCES facilities(id) ON DELETE CASCADE,
  room_number VARCHAR(50) NOT NULL,
  CONSTRAINT uq_room_per_facility UNIQUE (facility_id, room_number)
);

CREATE TABLE IF NOT EXISTS patients (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  birth_date DATE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS doctors (
  id              BIGSERIAL PRIMARY KEY,
  user_id         BIGINT NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
  facility_id     BIGINT NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  default_room_id INT REFERENCES rooms(id) ON DELETE SET NULL,
  active          BOOLEAN NOT NULL DEFAULT TRUE,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS specialties (
  id   SERIAL PRIMARY KEY,
  name VARCHAR(128) NOT NULL UNIQUE
);

CREATE TABLE IF NOT EXISTS doctor_specialties (
  doctor_id    BIGINT NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  specialty_id INT NOT NULL REFERENCES specialties(id) ON DELETE RESTRICT,
  PRIMARY KEY (doctor_id, specialty_id)
);

CREATE TABLE IF NOT EXISTS services (
  id           SERIAL PRIMARY KEY,
  name         VARCHAR(128) NOT NULL UNIQUE,
  duration_min INT NOT NULL CHECK (duration_min > 0),
  base_price   INT
);

CREATE TABLE IF NOT EXISTS doctor_services (
  doctor_id      BIGINT NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  service_id     INT NOT NULL REFERENCES services(id) ON DELETE RESTRICT,
  price_override INT,
  PRIMARY KEY (doctor_id, service_id)
);

CREATE TABLE IF NOT EXISTS schedule_slots (
  id        BIGSERIAL PRIMARY KEY,
  doctor_id BIGINT NOT NULL REFERENCES doctors(id) ON DELETE CASCADE,
  room_id   INT    NOT NULL REFERENCES rooms(id) ON DELETE RESTRICT,
  start_at  TIMESTAMPTZ NOT NULL,
  end_at    TIMESTAMPTZ NOT NULL,
  status    slot_status NOT NULL DEFAULT 'FREE',
  CONSTRAINT chk_slot_time CHECK (end_at > start_at),
  CONSTRAINT uq_doctor_start UNIQUE (doctor_id, start_at)
);

CREATE TABLE IF NOT EXISTS appointments (
  id                   BIGSERIAL PRIMARY KEY,
  slot_id              BIGINT NOT NULL REFERENCES schedule_slots(id) ON DELETE RESTRICT,
  patient_id           BIGINT NOT NULL REFERENCES patients(id) ON DELETE RESTRICT,
  doctor_id            BIGINT NOT NULL REFERENCES doctors(id) ON DELETE RESTRICT,
  status               appointment_status NOT NULL DEFAULT 'BOOKED',
  created_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  cancel_reason        TEXT,
  cancelled_by_user_id BIGINT REFERENCES users(id) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS appointment_services (
  appointment_id BIGINT NOT NULL REFERENCES appointments(id) ON DELETE CASCADE,
  service_id     INT    NOT NULL REFERENCES services(id) ON DELETE RESTRICT,
  qty            INT    NOT NULL DEFAULT 1 CHECK (qty > 0),
  PRIMARY KEY (appointment_id, service_id)
);

CREATE TABLE IF NOT EXISTS ui_notifications (
  id         BIGSERIAL PRIMARY KEY,
  user_id    BIGINT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  type       VARCHAR(32) NOT NULL,
  title      VARCHAR(255) NOT NULL,
  body       TEXT,
  is_read    BOOLEAN NOT NULL DEFAULT FALSE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS audit_events (
  id            BIGSERIAL PRIMARY KEY,
  actor_user_id BIGINT REFERENCES users(id) ON DELETE SET NULL,
  entity_type   VARCHAR(64) NOT NULL,
  entity_id     BIGINT,
  action        VARCHAR(64) NOT NULL,
  event_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  meta          JSONB NOT NULL DEFAULT '{}'::jsonb
);

CREATE TABLE IF NOT EXISTS pharmacy_cache (
  cache_key  VARCHAR(128) PRIMARY KEY,
  items      JSONB NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  expires_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE IF NOT EXISTS pharmacy_request_log (
  id          BIGSERIAL PRIMARY KEY,
  request_key VARCHAR(128) NOT NULL,
  http_status INT,
  duration_ms INT,
  error_class VARCHAR(64),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS lab_tests (
  id          BIGSERIAL PRIMARY KEY,
  code        VARCHAR(64) NOT NULL UNIQUE,
  name        VARCHAR(255) NOT NULL,
  description TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE IF NOT EXISTS lab_orders (
  id                     BIGSERIAL PRIMARY KEY,
  patient_id             BIGINT NOT NULL REFERENCES patients(id) ON DELETE CASCADE,
  status                 lab_order_status NOT NULL DEFAULT 'CREATED',
  requested_at           TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  source_facility_id     BIGINT NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  performing_facility_id BIGINT NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  referral_appointment_id BIGINT REFERENCES appointments(id) ON DELETE SET NULL,
  comment                TEXT
);

CREATE TABLE IF NOT EXISTS lab_order_items (
  id           BIGSERIAL PRIMARY KEY,
  lab_order_id BIGINT NOT NULL REFERENCES lab_orders(id) ON DELETE CASCADE,
  lab_test_id  BIGINT NOT NULL REFERENCES lab_tests(id) ON DELETE RESTRICT,
  qty          INT NOT NULL DEFAULT 1 CHECK (qty > 0),
  CONSTRAINT uq_lab_order_item UNIQUE (lab_order_id, lab_test_id)
);

CREATE TABLE IF NOT EXISTS lab_results (
  id                BIGSERIAL PRIMARY KEY,
  lab_order_item_id BIGINT NOT NULL REFERENCES lab_order_items(id) ON DELETE CASCADE,
  created_at        TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  result_payload    JSONB,
  comment           TEXT
);

CREATE TABLE IF NOT EXISTS lab_transfers (
  id              BIGSERIAL PRIMARY KEY,
  lab_order_id     BIGINT NOT NULL REFERENCES lab_orders(id) ON DELETE CASCADE,
  from_facility_id BIGINT NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  to_facility_id   BIGINT NOT NULL REFERENCES facilities(id) ON DELETE RESTRICT,
  status          lab_transfer_status NOT NULL DEFAULT 'SENT',
  transferred_at  TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  reason          TEXT,
  CHECK (from_facility_id <> to_facility_id)
);