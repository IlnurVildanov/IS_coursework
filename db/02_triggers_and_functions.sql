-- триггеры и функции
\set ON_ERROR_STOP on

-- автоматическое обновление поля updated_at при изменении записи
CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at := CURRENT_TIMESTAMP;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_set_updated_at ON appointments;
CREATE TRIGGER t_set_updated_at
BEFORE UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_set_updated_at();

-- проверка перед созданием записи (слоты, врач записи и врач слота)
CREATE OR REPLACE FUNCTION trg_check_appointment_doctor_matches_slot()
RETURNS TRIGGER AS $$
DECLARE
  v_slot_doctor BIGINT;
  v_slot_status slot_status;
  v_start TIMESTAMPTZ;
BEGIN
  SELECT doctor_id, status, start_at INTO v_slot_doctor, v_slot_status, v_start
  FROM schedule_slots
  WHERE id = NEW.slot_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'slot_id=% not found', NEW.slot_id;
  END IF;

  IF v_slot_doctor <> NEW.doctor_id THEN
    RAISE EXCEPTION 'appointment.doctor_id=% does not match slot.doctor_id=%', NEW.doctor_id, v_slot_doctor;
  END IF;

  IF v_start <= CURRENT_TIMESTAMP THEN
    RAISE EXCEPTION 'cannot book past slot (start_at=%)', v_start;
  END IF;

  IF v_slot_status <> 'FREE' THEN
    RAISE EXCEPTION 'slot status is % (expected FREE)', v_slot_status;
  END IF;

  RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_check_appt_before_insert ON appointments;
CREATE TRIGGER t_check_appt_before_insert
BEFORE INSERT ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_check_appointment_doctor_matches_slot();

-- действия после создания записи (статус, уведомление пациенту и событие)
CREATE OR REPLACE FUNCTION trg_after_appointment_insert()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id BIGINT;
BEGIN
  UPDATE schedule_slots
  SET status = 'BOOKED'
  WHERE id = NEW.slot_id;

  SELECT user_id INTO v_user_id FROM patients WHERE id = NEW.patient_id;

  INSERT INTO ui_notifications(user_id, type, title, body)
  VALUES (v_user_id, 'APPOINTMENT', 'Запись создана', 'Запись на приём успешно создана.');

  INSERT INTO audit_events(actor_user_id, entity_type, entity_id, action, meta)
  VALUES (v_user_id, 'APPOINTMENT', NEW.id, 'CREATE_APPOINTMENT', jsonb_build_object('slot_id', NEW.slot_id));

  RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_after_appt_insert ON appointments;
CREATE TRIGGER t_after_appt_insert
AFTER INSERT ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_after_appointment_insert();

-- действия при изменении статуса записи 
CREATE OR REPLACE FUNCTION trg_after_appointment_update()
RETURNS TRIGGER AS $$
DECLARE
  v_user_id BIGINT;
  v_has_active BOOLEAN;
BEGIN
  IF NEW.status = OLD.status THEN
    RETURN NEW;
  END IF;

  IF NEW.status = 'CANCELLED' THEN
    SELECT user_id INTO v_user_id FROM patients WHERE id = NEW.patient_id;

    SELECT EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.slot_id = NEW.slot_id AND a.status = 'BOOKED'
    ) INTO v_has_active;

    IF NOT v_has_active THEN
      UPDATE schedule_slots SET status='FREE' WHERE id=NEW.slot_id;
    END IF;

    INSERT INTO ui_notifications(user_id, type, title, body)
    VALUES (v_user_id, 'APPOINTMENT', 'Запись отменена', 'Запись на приём отменена.');

    INSERT INTO audit_events(actor_user_id, entity_type, entity_id, action, meta)
    VALUES (v_user_id, 'APPOINTMENT', NEW.id, 'CANCEL_APPOINTMENT', jsonb_build_object('slot_id', NEW.slot_id));
  END IF;

  RETURN NEW;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_after_appt_update ON appointments;
CREATE TRIGGER t_after_appt_update
AFTER UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_after_appointment_update();

-- запрет удаления слота, если по нему есть записи
CREATE OR REPLACE FUNCTION trg_prevent_delete_slot_with_appointments()
RETURNS TRIGGER AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM appointments WHERE slot_id = OLD.id) THEN
    RAISE EXCEPTION 'cannot delete slot %, it has appointments', OLD.id;
  END IF;
  RETURN OLD;
END; $$ LANGUAGE plpgsql;

DROP TRIGGER IF EXISTS t_prevent_delete_slot ON schedule_slots;
CREATE TRIGGER t_prevent_delete_slot
BEFORE DELETE ON schedule_slots
FOR EACH ROW
EXECUTE FUNCTION trg_prevent_delete_slot_with_appointments();

-- функции

-- получить свободные слоты врача в интервале
CREATE OR REPLACE FUNCTION fn_get_available_slots(p_doctor_id BIGINT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE(slot_id BIGINT, start_at TIMESTAMPTZ, end_at TIMESTAMPTZ, room_id INT) AS $$
BEGIN
  RETURN QUERY
  SELECT s.id, s.start_at, s.end_at, s.room_id
  FROM schedule_slots s
  WHERE s.doctor_id = p_doctor_id
    AND s.status = 'FREE'
    AND s.start_at >= p_from
    AND s.start_at < p_to
  ORDER BY s.start_at;
END; $$ LANGUAGE plpgsql STABLE;

-- создать запись пациента на слот
CREATE OR REPLACE FUNCTION fn_create_appointment(p_patient_id BIGINT, p_slot_id BIGINT, p_doctor_id BIGINT)
RETURNS BIGINT AS $$
DECLARE
  v_id BIGINT;
BEGIN
  INSERT INTO appointments(slot_id, patient_id, doctor_id, status)
  VALUES (p_slot_id, p_patient_id, p_doctor_id, 'BOOKED')
  RETURNING id INTO v_id;

  RETURN v_id;
END; $$ LANGUAGE plpgsql;

-- отменить запись
CREATE OR REPLACE FUNCTION fn_cancel_appointment(p_appointment_id BIGINT, p_cancel_reason TEXT, p_cancelled_by_user_id BIGINT)
RETURNS VOID AS $$
BEGIN
  UPDATE appointments
     SET status='CANCELLED',
         cancel_reason = p_cancel_reason,
         cancelled_by_user_id = p_cancelled_by_user_id
   WHERE id = p_appointment_id;
END; $$ LANGUAGE plpgsql;

-- выборка записей по врачу и периоду для администратора
CREATE OR REPLACE FUNCTION fn_admin_get_appointments(p_doctor_id BIGINT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS TABLE(appointment_id BIGINT, patient_id BIGINT, slot_start TIMESTAMPTZ, slot_end TIMESTAMPTZ, status appointment_status) AS $$
BEGIN
  RETURN QUERY
  SELECT a.id, a.patient_id, s.start_at, s.end_at, a.status
  FROM appointments a
  JOIN schedule_slots s ON s.id = a.slot_id
  WHERE a.doctor_id = p_doctor_id
    AND s.start_at >= p_from
    AND s.start_at < p_to
  ORDER BY s.start_at DESC;
END; $$ LANGUAGE plpgsql STABLE;

-- интеграция аптечного сервиса (обновление кэша)
CREATE OR REPLACE FUNCTION fn_upsert_pharmacy_cache(p_key VARCHAR, p_items JSONB, p_ttl_minutes INT DEFAULT 1440)
RETURNS VOID AS $$
BEGIN
  INSERT INTO pharmacy_cache(cache_key, items, updated_at, expires_at)
  VALUES (p_key, p_items, CURRENT_TIMESTAMP, CURRENT_TIMESTAMP + make_interval(mins => p_ttl_minutes))
  ON CONFLICT (cache_key)
  DO UPDATE SET items = EXCLUDED.items, updated_at = CURRENT_TIMESTAMP, expires_at = EXCLUDED.expires_at;
END; $$ LANGUAGE plpgsql;

-- интеграция аптечного сервиса (лог запроса - статус/время/класс ошибки)
CREATE OR REPLACE FUNCTION fn_log_pharmacy_request(p_key VARCHAR, p_http_status INT, p_duration_ms INT, p_error_class VARCHAR)
RETURNS VOID AS $$
BEGIN
  INSERT INTO pharmacy_request_log(request_key, http_status, duration_ms, error_class)
  VALUES (p_key, p_http_status, p_duration_ms, p_error_class);
END; $$ LANGUAGE plpgsql;