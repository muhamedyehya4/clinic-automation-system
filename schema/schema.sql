-- =============================================================
-- Clinic Automation System — PostgreSQL schema
-- Reconstructed from the queries executed by the n8n workflows.
-- Target: PostgreSQL 14+
-- =============================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";

-- -------------------------------------------------------------
-- 1. clinic_patients
--    Source-of-truth patient roster. Visit records here are what
--    trigger the post-visit follow-up cascade.
-- -------------------------------------------------------------
CREATE TABLE clinic_patients (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    phone             VARCHAR(20)  NOT NULL,
    full_name         VARCHAR(255) NOT NULL,
    doctor_name       VARCHAR(255),
    visit_date        TIMESTAMPTZ,
    visit_type        VARCHAR(100),
    clinic_name       VARCHAR(255),
    google_maps_link  TEXT,
    manager_phone     VARCHAR(20),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_clinic_patients_phone      ON clinic_patients (phone);
-- Drives the "1-3 hours post-visit" sweep every 30 minutes.
CREATE INDEX idx_clinic_patients_visit_date ON clinic_patients (visit_date);


-- -------------------------------------------------------------
-- 2. patient_intake
--    Pre-visit medical form + AI risk triage output.
--    One row per (phone, appointment_date).
-- -------------------------------------------------------------
CREATE TABLE patient_intake (
    id                       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_phone            VARCHAR(20)  NOT NULL,
    patient_name             VARCHAR(255),
    doctor_name              VARCHAR(255),
    appointment_date         DATE,
    appointment_time         VARCHAR(20),

    -- Collected via the intake form
    date_of_birth            DATE,
    gender                   VARCHAR(20),
    chief_complaint          TEXT,
    allergies                TEXT,
    current_medications      TEXT,
    chronic_conditions       TEXT,
    dental_concerns          TEXT,
    last_dental_visit        VARCHAR(100),
    previous_surgeries       TEXT,
    insurance_provider       VARCHAR(255),
    emergency_contact_name   VARCHAR(255),
    emergency_contact_phone  VARCHAR(20),
    xray_consent             BOOLEAN,

    -- Written by the LLM triage step
    risk_level               VARCHAR(20)
        CHECK (risk_level IN ('emergency','high','medium','low')),
    risk_score               NUMERIC(4,2),
    red_flags                TEXT,
    staff_note               TEXT,
    prep_instructions        TEXT,

    -- Lifecycle flags — these make every workflow idempotent
    form_link_sent_at        TIMESTAMPTZ,
    form_submitted           BOOLEAN     NOT NULL DEFAULT FALSE,
    form_submitted_at        TIMESTAMPTZ,
    reminder_sent            TIMESTAMPTZ,
    opted_out                BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at               TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at               TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Guarantees the "already submitted?" branch can never double-insert.
CREATE UNIQUE INDEX uniq_intake_phone_date
    ON patient_intake (patient_phone, appointment_date);
-- Serves the daily 9AM "tomorrow's patients" reminder query.
CREATE INDEX idx_intake_appointment_date ON patient_intake (appointment_date);
CREATE INDEX idx_intake_submitted        ON patient_intake (form_submitted, form_submitted_at);


-- -------------------------------------------------------------
-- 3. appointments
--    Booking ledger written by the conversational booking agent.
-- -------------------------------------------------------------
CREATE TABLE appointments (
    id                UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id         UUID,
    patient_phone     VARCHAR(20) NOT NULL,
    patient_name      VARCHAR(255),
    doctor_name       VARCHAR(255),
    appointment_date  DATE NOT NULL,
    appointment_time  TIME NOT NULL,
    status            VARCHAR(20) NOT NULL DEFAULT 'scheduled'
        CHECK (status IN ('scheduled','completed','cancelled','no_show')),
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Prevents double-booking the same doctor in the same slot.
CREATE UNIQUE INDEX uniq_appt_slot
    ON appointments (clinic_id, doctor_name, appointment_date, appointment_time)
    WHERE status = 'scheduled';
CREATE INDEX idx_appt_phone_status ON appointments (patient_phone, status);


-- -------------------------------------------------------------
-- 4. conversations
--    Per-patient state machine cursor for the WhatsApp bot.
-- -------------------------------------------------------------
CREATE TABLE conversations (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_id      UUID        NOT NULL,
    patient_phone  VARCHAR(20) NOT NULL,
    current_step   VARCHAR(50) NOT NULL DEFAULT 'idle',
    context        JSONB       NOT NULL DEFAULT '{}'::jsonb,
    created_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at     TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    -- Required by the ON CONFLICT upsert in the router.
    CONSTRAINT uniq_conversation UNIQUE (clinic_id, patient_phone)
);


-- -------------------------------------------------------------
-- 5. conversation_memory
--    Rolling transcript. The AI handler loads the last 20 turns
--    as context on every inbound message.
-- -------------------------------------------------------------
CREATE TABLE conversation_memory (
    id             BIGSERIAL PRIMARY KEY,
    patient_phone  VARCHAR(20) NOT NULL,
    role           VARCHAR(20) NOT NULL
        CHECK (role IN ('user','assistant','system')),
    content        TEXT        NOT NULL,
    sentiment      VARCHAR(20),
    intent         VARCHAR(50),
    confidence     NUMERIC(3,2),
    session_id     VARCHAR(100),
    timestamp      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Composite DESC index: the memory window query is the hottest read.
CREATE INDEX idx_memory_phone_time
    ON conversation_memory (patient_phone, timestamp DESC);


-- -------------------------------------------------------------
-- 6. patient_followup
--    Post-visit follow-up cascade + sentiment tracking.
-- -------------------------------------------------------------
CREATE TABLE patient_followup (
    id                     UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    patient_phone          VARCHAR(20) NOT NULL,
    patient_name           VARCHAR(255),
    doctor_name            VARCHAR(255),
    visit_date             TIMESTAMPTZ,
    visit_type             VARCHAR(100),
    clinic_name            VARCHAR(255),
    google_maps_link       TEXT,
    manager_phone          VARCHAR(20),

    follow_up_sent_at      TIMESTAMPTZ,   -- stage 1: 1-3h post-visit
    follow_up_day5_sent    TIMESTAMPTZ,   -- stage 2: day 5-7 care check-in

    patient_replied        BOOLEAN     NOT NULL DEFAULT FALSE,
    last_reply             TEXT,
    last_intent            VARCHAR(50),
    sentiment              VARCHAR(20),
    sentiment_score        NUMERIC(3,2),

    review_link_sent       BOOLEAN     NOT NULL DEFAULT FALSE,
    escalated_to_manager   BOOLEAN     NOT NULL DEFAULT FALSE,
    opted_out              BOOLEAN     NOT NULL DEFAULT FALSE,

    created_at             TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at             TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_followup_phone      ON patient_followup (patient_phone);
CREATE INDEX idx_followup_visit_date ON patient_followup (visit_date);
CREATE INDEX idx_followup_day5       ON patient_followup (follow_up_day5_sent)
    WHERE follow_up_day5_sent IS NULL;


-- -------------------------------------------------------------
-- 7. clinic_operations_log
--    Business-level event stream (sentiment, escalations).
-- -------------------------------------------------------------
CREATE TABLE clinic_operations_log (
    id               BIGSERIAL PRIMARY KEY,
    patient_phone    VARCHAR(20),
    event_type       VARCHAR(50) NOT NULL,
    event_data       JSONB       NOT NULL DEFAULT '{}'::jsonb,
    sentiment_score  NUMERIC(3,2),
    created_at       TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ops_event_type ON clinic_operations_log (event_type, created_at DESC);
CREATE INDEX idx_ops_event_data ON clinic_operations_log USING GIN (event_data);


-- -------------------------------------------------------------
-- 8. automation_logs
--    Technical audit trail. Every router branch writes here on
--    both success and failure, which is what makes the system
--    debuggable in production.
-- -------------------------------------------------------------
CREATE TABLE automation_logs (
    id             BIGSERIAL PRIMARY KEY,
    timestamp      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    phone          VARCHAR(20),
    event_type     VARCHAR(50),
    workflow_used  VARCHAR(100),
    result         VARCHAR(100),
    error_message  TEXT
);

CREATE INDEX idx_logs_timestamp ON automation_logs (timestamp DESC);
CREATE INDEX idx_logs_workflow  ON automation_logs (workflow_used, result);


-- -------------------------------------------------------------
-- 9. v_clinic_routing
--    Maps an inbound WhatsApp instance to its clinic, so one
--    n8n deployment can serve multiple clinics.
-- -------------------------------------------------------------
CREATE TABLE clinics (
    clinic_id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    clinic_name         VARCHAR(255) NOT NULL,
    evolution_instance  VARCHAR(100) NOT NULL UNIQUE,
    manager_phone       VARCHAR(20),
    google_maps_link    TEXT,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE VIEW v_clinic_routing AS
SELECT clinic_id, clinic_name, evolution_instance, manager_phone, google_maps_link
FROM clinics
WHERE is_active = TRUE;


-- -------------------------------------------------------------
-- 10. book_appointment()
--     Booking is wrapped in a function so the slot-availability
--     check and the insert happen in one atomic transaction.
--     Without this, two patients messaging simultaneously could
--     both be told the same slot was free.
-- -------------------------------------------------------------
CREATE OR REPLACE FUNCTION book_appointment(
    p_clinic_id  UUID,
    p_phone      VARCHAR,
    p_datetime   TIMESTAMPTZ,
    p_name       VARCHAR,
    p_doctor     VARCHAR
)
RETURNS TABLE (appointment_id UUID, booked_date TEXT, booked_time TEXT, success BOOLEAN)
LANGUAGE plpgsql
AS $$
DECLARE
    v_date DATE := p_datetime::date;
    v_time TIME := p_datetime::time;
    v_id   UUID;
BEGIN
    -- Serialize concurrent bookings for the same doctor+slot.
    PERFORM pg_advisory_xact_lock(hashtext(p_doctor || v_date::text || v_time::text));

    IF EXISTS (
        SELECT 1 FROM appointments
        WHERE doctor_name = p_doctor
          AND appointment_date = v_date
          AND appointment_time = v_time
          AND status = 'scheduled'
    ) THEN
        RETURN QUERY SELECT NULL::UUID, v_date::text, v_time::text, FALSE;
        RETURN;
    END IF;

    INSERT INTO appointments (clinic_id, patient_phone, patient_name, doctor_name,
                              appointment_date, appointment_time, status)
    VALUES (p_clinic_id, p_phone, p_name, p_doctor, v_date, v_time, 'scheduled')
    RETURNING id INTO v_id;

    RETURN QUERY SELECT v_id, v_date::text, to_char(v_time, 'HH24:MI'), TRUE;
END;
$$;
