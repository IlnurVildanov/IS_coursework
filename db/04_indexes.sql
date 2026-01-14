\set ON_ERROR_STOP on

-- быстрый поиск пользователя по email (регистрация/вход)
CREATE UNIQUE INDEX IF NOT EXISTS ux_users_email_lower ON users (lower(email));

-- активные врачи
CREATE INDEX IF NOT EXISTS ix_doctors_active ON doctors (active);

-- связи врач-специальность/услуга
CREATE INDEX IF NOT EXISTS ix_doctor_specialties_specialty ON doctor_specialties (specialty_id, doctor_id);
CREATE INDEX IF NOT EXISTS ix_doctor_services_service ON doctor_services (service_id, doctor_id);

-- сценарий «Свободные слоты врача»
CREATE INDEX IF NOT EXISTS ix_slots_doctor_start_free
ON schedule_slots (doctor_id, start_at)
WHERE status = 'FREE';

-- сценарий «Мои записи пациента»
CREATE INDEX IF NOT EXISTS ix_appointments_patient_created
ON appointments (patient_id, created_at DESC);

-- сценарий «Записи врача за период»
CREATE INDEX IF NOT EXISTS ix_appointments_doctor_slot
ON appointments (doctor_id, slot_id);

-- общий индекс по времени слота (для периодов/сортировок)
CREATE INDEX IF NOT EXISTS ix_slots_start ON schedule_slots (start_at);

-- уведомления пользователя (непрочитанные)
CREATE INDEX IF NOT EXISTS ix_notifications_user_unread
ON ui_notifications (user_id, created_at DESC)
WHERE is_read = FALSE;

-- большая таблица аудита
CREATE INDEX IF NOT EXISTS ix_audit_events_brin_time
ON audit_events USING brin (event_at);

-- лог интеграции аптечного сервиса
CREATE INDEX IF NOT EXISTS ix_pharmacy_log_brin_time
ON pharmacy_request_log USING brin (created_at);

CREATE INDEX IF NOT EXISTS ix_facilities_type_active
ON facilities(type)
WHERE is_active = TRUE;

CREATE INDEX IF NOT EXISTS ix_facility_addresses_current
ON facility_addresses(facility_id, valid_from DESC)
WHERE valid_to IS NULL;

-- история анализов пациента
CREATE INDEX IF NOT EXISTS ix_lab_orders_patient_requested
ON lab_orders(patient_id, requested_at DESC);

-- рабочий список лаборатории по исполнителю + статус + время
CREATE INDEX IF NOT EXISTS ix_lab_orders_performer_status_time
ON lab_orders(performing_facility_id, status, requested_at DESC);

-- передачи входящие для лаборатории
CREATE INDEX IF NOT EXISTS ix_lab_transfers_to_status_time
ON lab_transfers(to_facility_id, status, transferred_at DESC);

-- результаты по позиции заказа
CREATE INDEX IF NOT EXISTS ix_lab_results_item_time
ON lab_results(lab_order_item_id, created_at DESC);

ANALYZE;