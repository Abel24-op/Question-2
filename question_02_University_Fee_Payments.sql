-- (a) Tables and seed data
CREATE TABLE students (
    student_id     SERIAL PRIMARY KEY,
    student_number TEXT NOT NULL UNIQUE,
    full_name      TEXT NOT NULL,
    fee_due        NUMERIC(12, 2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
    payment_id SERIAL PRIMARY KEY,
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL CHECK (amount > 0),
    paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
    audit_id   SERIAL PRIMARY KEY,
    payment_id INTEGER NOT NULL REFERENCES payments(payment_id),
    student_id INTEGER NOT NULL REFERENCES students(student_id),
    amount     NUMERIC(12, 2) NOT NULL,
    logged_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE daily_collections (
    collection_date DATE PRIMARY KEY,
    payment_count   INTEGER NOT NULL DEFAULT 0,
    total_amount    NUMERIC(12, 2) NOT NULL DEFAULT 0.00
);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INTEGER)
RETURNS NUMERIC(12, 2)
LANGUAGE plpgsql
AS $$
DECLARE
    v_fee_due NUMERIC(12, 2);
    v_paid    NUMERIC(12, 2);
BEGIN
    SELECT fee_due INTO v_fee_due
    FROM students
    WHERE student_id = p_student_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    SELECT COALESCE(SUM(amount), 0.00) INTO v_paid
    FROM payments
    WHERE student_id = p_student_id;

    RETURN ROUND(v_fee_due - v_paid, 2);
END;
$$;

-- (d) Trigger (writes audit row automatically; procedure does not)
CREATE OR REPLACE FUNCTION tf_payments_audit()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
    VALUES (NEW.payment_id, NEW.student_id, NEW.amount, NOW());
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION tf_payments_audit();

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_receive_payment(
    p_student_id INTEGER,
    p_amount     NUMERIC(12, 2),
    p_paid_on    DATE
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_balance NUMERIC(12, 2);
BEGIN
    IF p_amount IS NULL OR p_amount <= 0 THEN
        RAISE EXCEPTION 'Payment amount must be positive, got %', p_amount;
    END IF;

    PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Unknown student_id %', p_student_id;
    END IF;

    v_balance := fn_fee_balance(p_student_id);

    IF p_amount > v_balance THEN
        RAISE EXCEPTION 'Payment % exceeds outstanding balance % for student %',
            p_amount, v_balance, p_student_id;
    END IF;

    INSERT INTO payments (student_id, amount, paid_on)
    VALUES (p_student_id, p_amount, p_paid_on);
END;
$$;

-- Seed 3 students (Student 3 has no payments) and 6 payments
INSERT INTO students (student_number, full_name, fee_due) VALUES
    ('STU2026001', 'Mwamba Banda',  3000.00),
    ('STU2026002', 'Chanda Phiri',  2000.00),
    ('STU2026003', 'Mutale Tembo',  1500.00);

CALL pr_receive_payment(1, 1000.00, DATE '2026-11-20');
CALL pr_receive_payment(1, 1500.00, DATE '2026-11-22');
CALL pr_receive_payment(1, 500.00,  DATE '2026-11-24'); -- Student 1 settled (0 balance)
CALL pr_receive_payment(2, 500.00,  DATE '2026-11-23');
CALL pr_receive_payment(2, 400.00,  DATE '2026-11-24');
CALL pr_receive_payment(2, 300.00,  DATE '2026-11-24'); -- Student 2 owes 800.00

-- (e) View
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT
    s.student_number,
    s.full_name,
    (s.fee_due - COALESCE(SUM(p.amount), 0.00)) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING (s.fee_due - COALESCE(SUM(p.amount), 0.00)) > 0;

-- (f) Index and EXPLAIN
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- Justification: Leading with student_id isolates a student's payments, and paid_on
-- enables an ordered index range scan across dates without table sorting.
EXPLAIN (ANALYZE, BUFFERS)
SELECT payment_id, amount, paid_on
FROM payments
WHERE student_id = 2
  AND paid_on BETWEEN DATE '2026-11-20' AND DATE '2026-11-25';

-- (g) Procedure and scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql
AS $$
DECLARE
    v_cnt INTEGER;
    v_sum NUMERIC(12, 2);
BEGIN
    SELECT COUNT(*), COALESCE(SUM(amount), 0.00)
    INTO v_cnt, v_sum
    FROM payments
    WHERE paid_on = p_day;

    INSERT INTO daily_collections (collection_date, payment_count, total_amount)
    VALUES (p_day, v_cnt, v_sum)
    ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count,
        total_amount  = EXCLUDED.total_amount;
END;
$$;

-- pg_cron daily at 01:00 for the previous day
SELECT cron.schedule(
    'q2_refresh_daily_collections',
    '0 1 * * *',
    $$CALL pr_refresh_collections((CURRENT_DATE - INTERVAL '1 day')::DATE);$$
);