-- ICT371 Advanced Database - Ethel Kabutu 202404608
-- PostgreSQL. Each question lives in its own schema (q1 ... q10) so table names do not clash.
-- Scheduled jobs use pg_cron (run once as superuser: CREATE EXTENSION pg_cron;)
CREATE EXTENSION IF NOT EXISTS pg_cron;

---------------------------------------------------------------------
-- QUESTION 1: Pharmacy Stock and Daily Sales
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q1 CASCADE;
CREATE SCHEMA q1;
SET search_path TO q1;

-- (a) tables
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);
CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL
);
CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL
);

-- (b) function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END $$;

-- (c) procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC; v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: available %, requested %', v_stock, p_quantity;
  END IF;
  INSERT INTO sales(medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity WHERE medicine_id = p_medicine_id;
END $$;

-- (d) trigger
CREATE OR REPLACE FUNCTION trg_stock_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.stock_qty IS DISTINCT FROM OLD.stock_qty THEN
    INSERT INTO stock_audit(medicine_id, old_qty, new_qty)
    VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_medicines_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW EXECUTE FUNCTION trg_stock_audit();

-- (a) seed data (sales loaded through the procedure)
INSERT INTO medicines(medicine_name, unit_price, stock_qty) VALUES
 ('Paracetamol', 2.50, 100),
 ('Amoxicillin', 8.00, 30),
 ('Ibuprofen',   4.00, 12);
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1, 20, CURRENT_DATE - 1);
CALL pr_record_sale(2, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(2, 10, CURRENT_DATE - 1);
CALL pr_record_sale(3, 5,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 1,  CURRENT_DATE);

-- (e) view
CREATE OR REPLACE VIEW v_low_stock AS
SELECT medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines WHERE stock_qty < 10;
SELECT * FROM v_low_stock;

-- (f) index: equality on medicine_id first, then range on sold_on
CREATE INDEX idx_sales_medicine_sold_on ON sales(medicine_id, sold_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g) scheduled job
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales(sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity), 0), COALESCE(SUM(quantity * unit_price), 0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
    SET total_qty = EXCLUDED.total_qty, total_amount = EXCLUDED.total_amount;
END $$;
CALL pr_refresh_sales(CURRENT_DATE - 1);
SELECT cron.schedule('q1_refresh_sales', '15 0 * * *', $$CALL q1.pr_refresh_sales(CURRENT_DATE - 1)$$);

---------------------------------------------------------------------
-- QUESTION 2: University Fee Payments
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q2 CASCADE;
CREATE SCHEMA q2;
SET search_path TO q2;

-- (a)
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);
CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);
CREATE TABLE payment_audit (
  audit_id   SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(12,2) NOT NULL
);

-- (b)
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_fee NUMERIC; v_paid NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  SELECT COALESCE(SUM(amount), 0) INTO v_paid FROM payments WHERE student_id = p_student_id;
  RETURN v_fee - v_paid;
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Payment amount must be positive';
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
  PERFORM 1 FROM students WHERE student_id = p_student_id FOR UPDATE;  -- serialise payments per student
  v_balance := fn_fee_balance(p_student_id);                           -- raises if student unknown
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments(student_id, amount, paid_on) VALUES (p_student_id, p_amount, p_paid_on);
END $$;

-- (d) trigger (the procedure does NOT write the audit row)
CREATE OR REPLACE FUNCTION trg_payment_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO payment_audit(payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_payments_audit
AFTER INSERT ON payments
FOR EACH ROW EXECUTE FUNCTION trg_payment_audit();

-- (a) seed
INSERT INTO students(student_number, full_name, fee_due) VALUES
 ('202401', 'Chanda Phiri', 5000),
 ('202402', 'Mutale Banda', 2000),
 ('202403', 'Thandiwe Zulu', 4000);
CALL pr_receive_payment(1, 1000, CURRENT_DATE - 5);
CALL pr_receive_payment(1, 1500, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 500,  CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000, CURRENT_DATE - 4);
CALL pr_receive_payment(2, 500,  CURRENT_DATE - 2);
CALL pr_receive_payment(2, 500,  CURRENT_DATE - 1);   -- student 2 now fully settled; student 3 has no payments

-- (e)
CREATE OR REPLACE VIEW v_fee_balances AS
SELECT s.student_number, s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;
SELECT * FROM v_fee_balances;

-- (f) composite index: equality column first, range column second
CREATE INDEX idx_payments_student_paid_on ON payments(student_id, paid_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections(collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0) FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
    SET payment_count = EXCLUDED.payment_count, total_amount = EXCLUDED.total_amount;
END $$;
CALL pr_refresh_collections(CURRENT_DATE - 1);
SELECT cron.schedule('q2_refresh_collections', '0 1 * * *', $$CALL q2.pr_refresh_collections(CURRENT_DATE - 1)$$);

---------------------------------------------------------------------
-- QUESTION 3: Library Returns and Overdue Fines
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q3 CASCADE;
CREATE SCHEMA q3;
SET search_path TO q3;

-- (a)
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);
CREATE TABLE loans (
  loan_id       SERIAL PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT ck_due_after_borrow CHECK (due_on >= borrowed_on)
);
CREATE TABLE loan_audit (
  audit_id         SERIAL PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE NULL,
  new_returned_on  DATE NULL,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);
CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

-- (b)
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_due DATE; v_ret DATE; v_end DATE;
BEGIN
  SELECT due_on, returned_on INTO v_due, v_ret FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  v_end := LEAST(p_as_of, v_ret);          -- LEAST ignores NULL, so open loans use p_as_of
  RETURN 2 * GREATEST(v_end - v_due, 0);
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_loan loans%ROWTYPE;
BEGIN
  SELECT * INTO v_loan FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  IF v_loan.returned_on IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % is already returned', p_loan_id;
  END IF;
  IF p_returned_on IS NULL OR p_returned_on < v_loan.borrowed_on THEN
    RAISE EXCEPTION 'Return date cannot be before borrowed date';
  END IF;
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
  WHERE loan_id = p_loan_id;
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_loan_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO loan_audit(loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_loans_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit();

-- (a) seed
INSERT INTO books(title) VALUES ('Database Systems'), ('Operating Systems'), ('Computer Networks');
INSERT INTO loans(book_id, borrower_name, borrowed_on, due_on) VALUES
 (1, 'Mary',  CURRENT_DATE - 20, CURRENT_DATE - 6),    -- open, overdue
 (2, 'John',  CURRENT_DATE - 3,  CURRENT_DATE + 11),   -- open, on time
 (1, 'Anna',  CURRENT_DATE - 30, CURRENT_DATE - 16),   -- will be returned late
 (3, 'Peter', CURRENT_DATE - 10, CURRENT_DATE + 4),    -- open, on time
 (3, 'Grace', CURRENT_DATE - 25, CURRENT_DATE - 11),   -- returned on due date
 (2, 'Luke',  CURRENT_DATE - 15, CURRENT_DATE - 1);    -- open, overdue
CALL pr_return_loan(3, CURRENT_DATE - 14);   -- 2 days late -> K4
CALL pr_return_loan(5, CURRENT_DATE - 11);   -- on due date -> K0

-- (e)
CREATE OR REPLACE VIEW v_overdue_loans AS
SELECT b.title, l.borrower_name, l.due_on, fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_today
FROM loans l JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL AND l.due_on < CURRENT_DATE;
SELECT * FROM v_overdue_loans;

-- (f) partial index: only unreturned loans are indexed, so it stays small
CREATE INDEX idx_loans_book_unreturned ON loans(book_id) WHERE returned_on IS NULL;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM loans WHERE book_id = 2 AND returned_on IS NULL;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary(snapshot_date, overdue_count, total_fine)
  SELECT p_as_of, COUNT(*), COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
    SET overdue_count = EXCLUDED.overdue_count, total_fine = EXCLUDED.total_fine;
END $$;
CALL pr_refresh_overdue(CURRENT_DATE);
SELECT cron.schedule('q3_refresh_overdue', '10 0 * * *', $$CALL q3.pr_refresh_overdue(CURRENT_DATE)$$);

---------------------------------------------------------------------
-- QUESTION 4: Clinic Appointment Scheduling
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q4 CASCADE;
CREATE SCHEMA q4;
SET search_path TO q4;

-- (a)
CREATE TABLE patients (
  patient_id SERIAL PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);
CREATE TABLE doctors (
  doctor_id SERIAL PRIMARY KEY,
  full_name VARCHAR(100) NOT NULL
);
CREATE TABLE appointments (
  appointment_id  SERIAL PRIMARY KEY,
  patient_id      INT NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL
    CHECK (slot_time IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00')),
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED'
    CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED'))
);
CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL,
  attended_count  INT NOT NULL,
  cancelled_count INT NOT NULL
);

-- (b)
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_count INT;
BEGIN
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  SELECT COUNT(*) INTO v_count FROM appointments
  WHERE doctor_id = p_doctor_id AND appointment_day = p_day AND status <> 'CANCELLED';
  RETURN v_count;      -- COUNT returns 0 when there are no bookings
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM patients WHERE patient_id = p_patient_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown patient: %', p_patient_id; END IF;
  PERFORM 1 FROM doctors WHERE doctor_id = p_doctor_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id; END IF;
  IF p_day IS NULL OR p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Appointment date cannot be in the past';
  END IF;
  IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: %', p_slot;
  END IF;
  INSERT INTO appointments(patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_appointment_clash() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.status <> 'CANCELLED' THEN
    IF EXISTS (
      SELECT 1 FROM appointments a
      WHERE a.doctor_id = NEW.doctor_id
        AND a.appointment_day = NEW.appointment_day
        AND a.slot_time = NEW.slot_time
        AND a.status <> 'CANCELLED'
        AND a.appointment_id <> COALESCE(NEW.appointment_id, -1)   -- exclude the row being changed
    ) THEN
      RAISE EXCEPTION 'Slot % on % is already taken for doctor %',
                      NEW.slot_time, NEW.appointment_day, NEW.doctor_id;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_appointments_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_appointment_clash();

-- (a) seed
INSERT INTO patients(full_name) VALUES ('Alice Mumba'), ('Brian Tembo'), ('Clara Lungu');
INSERT INTO doctors(full_name)  VALUES ('Dr. Kunda'), ('Dr. Sata'), ('Dr. Mwale');
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 1, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 2, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(1, 3, CURRENT_DATE + 1, '11:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE + 1, '12:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 2, '09:00');
UPDATE appointments SET status = 'CANCELLED' WHERE appointment_id = 6;   -- cancelled slot frees up

-- (e)
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name, d.full_name AS doctor_name, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';
SELECT * FROM v_today_appointments;

-- (f) non-unique index: day (equality) and doctor (equality) used together in searches
CREATE INDEX idx_appointments_day_doctor ON appointments(appointment_day, doctor_id);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary(summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
    SET booked_count = EXCLUDED.booked_count,
        attended_count = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END $$;
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT cron.schedule('q4_refresh_clinic_summary', '0 1 * * *', $$CALL q4.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);

---------------------------------------------------------------------
-- QUESTION 5: Hostel Room Allocation
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q5 CASCADE;
CREATE SCHEMA q5;
SET search_path TO q5;

-- (a)
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE rooms (
  room_id     SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);
CREATE TABLE allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL CHECK (status IN ('ACTIVE', 'ENDED')),
  CONSTRAINT ck_status_release CHECK (
    (status = 'ACTIVE' AND released_on IS NULL) OR
    (status = 'ENDED'  AND released_on IS NOT NULL))
);
CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT NOT NULL,
  free_beds     INT NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- (b)
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_active INT;
BEGIN
  SELECT capacity INTO v_cap FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  SELECT COUNT(*) INTO v_active FROM allocations WHERE room_id = p_room_id AND status = 'ACTIVE';
  RETURN v_cap - v_active;
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown student: %', p_student_id; END IF;
  PERFORM 1 FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown room: %', p_room_id; END IF;
  IF p_allocated_on IS NULL THEN RAISE EXCEPTION 'Allocation date is required'; END IF;
  IF EXISTS (SELECT 1 FROM allocations WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % is full', p_room_id;
  END IF;
  INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_allocation_rules() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cap INT; v_count INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    SELECT capacity INTO v_cap FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF EXISTS (SELECT 1 FROM allocations a
               WHERE a.student_id = NEW.student_id AND a.status = 'ACTIVE'
                 AND a.allocation_id <> COALESCE(NEW.allocation_id, -1)) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM allocations a
    WHERE a.room_id = NEW.room_id AND a.status = 'ACTIVE'
      AND a.allocation_id <> COALESCE(NEW.allocation_id, -1);
    IF v_count >= v_cap THEN
      RAISE EXCEPTION 'Room % is at full capacity (%)', NEW.room_id, v_cap;
    END IF;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_allocations_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW EXECUTE FUNCTION trg_allocation_rules();

-- (a) seed: R101 full, R102 partly occupied, R103 empty
INSERT INTO students(student_number, full_name) VALUES
 ('S001', 'Esther Chola'), ('S002', 'Felix Njobvu'), ('S003', 'Gift Daka'),
 ('S004', 'Hope Mbewe'),   ('S005', 'Isaac Simwanza');
INSERT INTO rooms(room_number, capacity) VALUES ('R101', 2), ('R102', 3), ('R103', 2);
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(2, 1, CURRENT_DATE - 30);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 20);
INSERT INTO allocations(student_id, room_id, allocated_on, released_on, status)
VALUES (4, 3, CURRENT_DATE - 90, CURRENT_DATE - 40, 'ENDED');   -- history only

-- (e)
CREATE OR REPLACE VIEW v_room_occupancy AS
SELECT r.room_id, r.room_number, r.capacity,
       COUNT(a.allocation_id) AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;
SELECT * FROM v_room_occupancy;

-- (f) partial index: only ACTIVE rows are indexed
CREATE INDEX idx_alloc_active_room ON allocations(room_id) WHERE status = 'ACTIVE';
SET enable_seqscan = off;
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot(snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds FROM v_room_occupancy
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
    SET occupied_beds = EXCLUDED.occupied_beds, free_beds = EXCLUDED.free_beds;
END $$;
CALL pr_refresh_occupancy();
SELECT cron.schedule('q5_refresh_occupancy', '55 23 * * *', $$CALL q5.pr_refresh_occupancy()$$);

---------------------------------------------------------------------
-- QUESTION 6: Monthly Payroll Processing
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q6 CASCADE;
CREATE SCHEMA q6;
SET search_path TO q6;

-- (a)
CREATE TABLE employees (
  employee_id  SERIAL PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);
CREATE TABLE payroll (
  payroll_id  SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL CHECK (pay_month = date_trunc('month', pay_month)::date),
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT uq_payroll_emp_month UNIQUE (employee_id, pay_month)
);
CREATE TABLE salary_audit (
  audit_id    SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (b)
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_net NUMERIC;
BEGIN
  SELECT basic_salary + allowance - deduction INTO v_net
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  IF p_month IS NULL OR p_month <> date_trunc('month', p_month)::date THEN
    RAISE EXCEPTION 'p_month must be the first day of a month';
  END IF;
  FOR r IN SELECT employee_id, basic_salary, allowance FROM employees WHERE active LOOP
    INSERT INTO payroll(employee_id, pay_month, gross_pay, net_pay)
    VALUES (r.employee_id, p_month, r.basic_salary + r.allowance, fn_net_pay(r.employee_id))
    ON CONFLICT (employee_id, pay_month) DO NOTHING;   -- existing rows stay unchanged
  END LOOP;   -- any exception rolls back the whole call
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_salary_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO salary_audit(employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_employees_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit();

-- (a) seed
INSERT INTO employees(full_name, basic_salary, allowance, deduction, active) VALUES
 ('Joyce Kapata',  8000, 1500, 1200, TRUE),
 ('Martin Sakala', 6500, 1000,  900, TRUE),
 ('Ruth Mulenga',  7200,  800, 1000, TRUE),
 ('Peter Chisha',  5000,  500,  600, TRUE);
CALL pr_process_payroll(DATE '2026-09-01');
CALL pr_process_payroll(DATE '2026-10-01');
UPDATE employees SET active = FALSE WHERE employee_id = 4;          -- becomes inactive later
UPDATE employees SET basic_salary = 8500 WHERE employee_id = 1;     -- logged by trigger
CALL pr_process_payroll(DATE '2026-10-01');                         -- rerun: nothing changes

-- (e)
CREATE OR REPLACE VIEW v_payroll_report AS
SELECT e.full_name, p.pay_month, p.gross_pay, p.net_pay
FROM payroll p JOIN employees e ON e.employee_id = p.employee_id;   -- no active filter: keeps history
SELECT * FROM v_payroll_report ORDER BY pay_month, full_name;

-- (f) the unique index starts with employee_id so it cannot serve a pay_month-only filter
CREATE INDEX idx_payroll_pay_month ON payroll(pay_month);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM payroll WHERE pay_month = DATE '2026-10-01';
RESET enable_seqscan;

-- (g) 02:00 on day 1 of every month, for the previous month
SELECT cron.schedule('q6_process_payroll', '0 2 1 * *',
  $$CALL q6.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);
-- inspect job and run history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details ORDER BY start_time DESC;

---------------------------------------------------------------------
-- QUESTION 7: Water Meter Readings and Billing
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q7 CASCADE;
CREATE SCHEMA q7;
SET search_path TO q7;

-- (a)
CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);
CREATE TABLE readings (
  reading_id       SERIAL PRIMARY KEY,
  customer_id      INT NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL CHECK (reading_month = date_trunc('month', reading_month)::date),
  previous_reading NUMERIC(10,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(10,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT uq_reading_cust_month UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
  bill_id     SERIAL PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT ck_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);
CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(12,2) NOT NULL
);

-- (d) trigger first so every reading load is protected
CREATE OR REPLACE FUNCTION trg_reading_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'current_reading (%) is below previous_reading (%)',
                    NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_readings_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW EXECUTE FUNCTION trg_reading_check();

-- (b)
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
BEGIN
  IF p_units IS NULL OR p_units < 0 THEN
    RAISE EXCEPTION 'Invalid consumption: %', p_units;
  END IF;
  IF p_units <= 10 THEN
    RETURN ROUND(p_units * 5, 2);
  END IF;
  RETURN ROUND(10 * 5 + (p_units - 10) * 8, 2);
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_prev NUMERIC; v_curr NUMERIC;
BEGIN
  SELECT previous_reading, current_reading INTO v_prev, v_curr
  FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'Due date is required';
  END IF;
  INSERT INTO bills(reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, fn_water_charge(v_curr - v_prev), 0, p_due_on);
END $$;

-- (a) seed: units 0, 10, 15, 5, 10, 25
INSERT INTO customers(full_name) VALUES ('Nkandu Lubinda'), ('Bwalya Kasonde'), ('Mercy Tonga');
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
 (1, DATE '2026-09-01', 100, 100),   -- 0 units
 (1, DATE '2026-10-01', 100, 110),   -- exactly 10
 (2, DATE '2026-09-01', 50,  65),    -- 15
 (2, DATE '2026-10-01', 65,  70),    -- 5
 (3, DATE '2026-09-01', 200, 210),   -- 10
 (3, DATE '2026-10-01', 210, 235);   -- 25
CALL pr_generate_bill(1, CURRENT_DATE - 30);
CALL pr_generate_bill(2, CURRENT_DATE - 10);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 5);
CALL pr_generate_bill(6, CURRENT_DATE + 15);
UPDATE bills SET amount_paid = charge WHERE bill_id = 5;   -- one fully paid
UPDATE bills SET amount_paid = 20 WHERE bill_id = 3;       -- one part paid

-- (e)
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;
SELECT * FROM v_overdue_bills;

-- (f) partial index: only unpaid bills, ordered by due date
CREATE INDEX idx_bills_unpaid_due ON bills(due_on) WHERE amount_paid < charge;
SET enable_seqscan = off;
EXPLAIN SELECT * FROM bills WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot(snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0) FROM bills WHERE amount_paid < charge
  ON CONFLICT (snapshot_date) DO UPDATE SET total_due = EXCLUDED.total_due;
END $$;
CALL pr_refresh_receivables();
SELECT cron.schedule('q7_refresh_receivables', '30 0 * * *', $$CALL q7.pr_refresh_receivables()$$);

---------------------------------------------------------------------
-- QUESTION 8: Transport Fleet Maintenance
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8;

-- (a)
CREATE TABLE vehicles (
  vehicle_id            SERIAL PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      NUMERIC(10,1) NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer NUMERIC(10,1) NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT ck_service_le_current CHECK (last_service_odometer <= current_odometer)
);
CREATE TABLE trips (
  trip_id        SERIAL PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer NUMERIC(10,1) NOT NULL CHECK (start_odometer >= 0),
  end_odometer   NUMERIC(10,1) NOT NULL CHECK (end_odometer >= 0)
);
CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service NUMERIC(10,1) NOT NULL,
  flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b)
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
DECLARE v_cur NUMERIC; v_last NUMERIC;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_cur, v_last
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  RETURN (v_cur - v_last) >= 5000;
END $$;

-- (c) does NOT touch the vehicle odometer
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start NUMERIC, p_end NUMERIC)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date and odometer values are required';
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;
  INSERT INTO trips(vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_trip_odometer() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_cur NUMERIC;
BEGIN
  SELECT current_odometer INTO v_cur FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end (%) must exceed start (%)', NEW.end_odometer, NEW.start_odometer;
  END IF;
  IF NEW.start_odometer <> v_cur THEN
    RAISE EXCEPTION 'Start odometer % does not match current odometer %', NEW.start_odometer, v_cur;
  END IF;
  UPDATE vehicles SET current_odometer = NEW.end_odometer WHERE vehicle_id = NEW.vehicle_id;
  RETURN NEW;
END $$;
CREATE TRIGGER trg_trips_odometer
BEFORE INSERT ON trips
FOR EACH ROW EXECUTE FUNCTION trg_trip_odometer();

-- (a) seed: vehicles first, then trips through the procedure (trigger already installed)
INSERT INTO vehicles(registration, current_odometer, last_service_odometer) VALUES
 ('BAF 1001', 20000, 14000),   -- 6000 km since service (due)
 ('BAF 2002', 12000, 10000),   -- 2000 km (not due)
 ('BAF 3003',  8000,  3000);   -- 5000 km (exactly due)
CALL pr_record_trip(1, CURRENT_DATE - 6, 20000, 20100);
CALL pr_record_trip(1, CURRENT_DATE - 3, 20100, 20300);
CALL pr_record_trip(2, CURRENT_DATE - 5, 12000, 12150);
CALL pr_record_trip(2, CURRENT_DATE - 2, 12150, 12400);
CALL pr_record_trip(3, CURRENT_DATE - 4, 8000,  8200);
CALL pr_record_trip(3, CURRENT_DATE - 1, 8200,  8300);

-- (e)
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;
SELECT * FROM v_service_due;

-- (f) equality on vehicle_id, then range on trip_on
CREATE INDEX idx_trips_vehicle_trip_on ON trips(vehicle_id, trip_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO service_alerts(vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE SET km_since_service = EXCLUDED.km_since_service;

  DELETE FROM service_alerts sa
  USING vehicles v
  WHERE v.vehicle_id = sa.vehicle_id
    AND v.current_odometer - v.last_service_odometer < 5000;   -- serviced, no longer due
END $$;
CALL pr_refresh_service_alerts();
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1', $$CALL q8.pr_refresh_service_alerts()$$);

---------------------------------------------------------------------
-- QUESTION 9: Farmer Cooperative Maize Deliveries
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q9 CASCADE;
CREATE SCHEMA q9;
SET search_path TO q9;

-- (a)
CREATE TABLE farmers (
  farmer_id     SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);
CREATE TABLE deliveries (
  delivery_id  SERIAL PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A', 'B', 'C')),
  weight_kg    NUMERIC(10,2) NOT NULL,
  unit_rate    NUMERIC(8,2) NOT NULL,
  total_value  NUMERIC(12,2) NOT NULL,
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);
CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(12,2) NOT NULL,
  total_value   NUMERIC(12,2) NOT NULL
);

-- (b)
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade CHAR)
RETURNS NUMERIC LANGUAGE plpgsql AS $$
DECLARE v_rate NUMERIC;
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade is required';
  END IF;
  v_rate := CASE p_grade WHEN 'A' THEN 5 WHEN 'B' THEN 4 WHEN 'C' THEN 3 END;
  IF v_rate IS NULL THEN
    RAISE EXCEPTION 'Unsupported grade: %', p_grade;
  END IF;
  RETURN v_rate;
END $$;

-- (d) trigger (sets rate and value for procedure AND direct SQL)
CREATE OR REPLACE FUNCTION trg_delivery_price() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END $$;
CREATE TRIGGER trg_deliveries_price
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW EXECUTE FUNCTION trg_delivery_price();

-- (c)
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade CHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM 1 FROM farmers WHERE farmer_id = p_farmer_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;
  IF p_grade IS NULL OR p_grade NOT IN ('A', 'B', 'C') THEN
    RAISE EXCEPTION 'Invalid grade: %', p_grade;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive';
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;
  INSERT INTO deliveries(farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);   -- trigger supplies unit_rate, total_value
END $$;

-- (a) seed (loaded after the trigger; unit_rate/total_value are overwritten by the trigger)
INSERT INTO farmers(farmer_number, full_name) VALUES
 ('F001', 'Chipo Mwansa'), ('F002', 'Kelvin Ngoma'), ('F003', 'Linda Bwembya');
INSERT INTO deliveries(farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on, is_paid) VALUES
 (1, 'A', 100, 0, 0, CURRENT_DATE - 3, TRUE),
 (1, 'B', 250, 0, 0, CURRENT_DATE - 2, FALSE),
 (2, 'C', 400, 0, 0, CURRENT_DATE - 2, FALSE),
 (2, 'A',  80, 0, 0, CURRENT_DATE - 1, TRUE),
 (3, 'B', 150, 0, 0, CURRENT_DATE - 1, TRUE),
 (3, 'C',  60, 0, 0, CURRENT_DATE - 1, TRUE);
CALL pr_receive_delivery(1, 'A', 120, CURRENT_DATE - 1);   -- procedure example (unpaid)

-- (e)
CREATE OR REPLACE VIEW v_farmer_amount_due AS
SELECT f.farmer_number, f.full_name,
       COALESCE(SUM(d.total_value) FILTER (WHERE d.is_paid = FALSE), 0) AS amount_due
FROM farmers f LEFT JOIN deliveries d ON d.farmer_id = f.farmer_id
GROUP BY f.farmer_id, f.farmer_number, f.full_name;
SELECT * FROM v_farmer_amount_due;

-- (f)
CREATE INDEX idx_deliveries_farmer_date ON deliveries(farmer_id, delivered_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 7 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases(purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
    SET total_weight = EXCLUDED.total_weight, total_value = EXCLUDED.total_value;
END $$;
CALL pr_refresh_purchases(CURRENT_DATE - 1);
SELECT cron.schedule('q9_refresh_purchases', '30 1 * * *', $$CALL q9.pr_refresh_purchases(CURRENT_DATE - 1)$$);

---------------------------------------------------------------------
-- QUESTION 10: Scholarship Application Assessment
---------------------------------------------------------------------
DROP SCHEMA IF EXISTS q10 CASCADE;
CREATE SCHEMA q10;
SET search_path TO q10;

-- (a)
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);
CREATE TABLE applications (
  application_id     SERIAL PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(12,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2) NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING'
    CHECK (status IN ('PENDING', 'APPROVED', 'REJECTED'))
);
CREATE TABLE decision_audit (
  audit_id       SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

-- (b)
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN LANGUAGE plpgsql AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_age <= 0 THEN RAISE EXCEPTION 'Age must be positive'; END IF;
  IF p_income < 0 THEN RAISE EXCEPTION 'Income cannot be negative'; END IF;
  IF p_mark < 0 OR p_mark > 100 THEN RAISE EXCEPTION 'Mark must be between 0 and 100'; END IF;
  RETURN p_age BETWEEN 18 AND 25 AND p_income <= 3000 AND p_mark >= 70;
END $$;

-- (c)
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE v_app applications%ROWTYPE;
BEGIN
  SELECT * INTO v_app FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application: %', p_application_id;
  END IF;
  IF v_app.status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % is already assessed (%)', p_application_id, v_app.status;
  END IF;
  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_app.age_at_application,
                                                 v_app.monthly_income,
                                                 v_app.average_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END $$;

-- (d)
CREATE OR REPLACE FUNCTION trg_decision_audit() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO decision_audit(application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END $$;
CREATE TRIGGER trg_applications_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit();

-- (a) seed: six PENDING applications
INSERT INTO students(student_number, full_name) VALUES
 ('SC001', 'Namukolo Hamoonga'), ('SC002', 'Oliver Mutemba'), ('SC003', 'Patricia Nyirenda');
INSERT INTO applications(student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
 (1, 22, 1500, 85.00, CURRENT_DATE - 10, 'PENDING'),   -- qualifies
 (1, 18, 3000, 70.00, CURRENT_DATE - 9,  'PENDING'),   -- lower boundary, qualifies
 (2, 25, 3000, 70.00, CURRENT_DATE - 8,  'PENDING'),   -- upper boundary, qualifies
 (2, 26, 1000, 90.00, CURRENT_DATE - 7,  'PENDING'),   -- too old
 (3, 21, 3001, 80.00, CURRENT_DATE - 6,  'PENDING'),   -- income too high
 (3, 20, 2000, 69.99, CURRENT_DATE - 5,  'PENDING');   -- mark too low

-- (e)
CREATE OR REPLACE VIEW v_approved_applicants AS
SELECT s.student_number, s.full_name, a.average_mark, a.status
FROM applications a JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) equality column (status) first, range column (submitted_on) second
CREATE INDEX idx_applications_status_submitted ON applications(status, submitted_on);
SET enable_seqscan = off;
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- (g)
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE r RECORD;
BEGIN
  FOR r IN SELECT application_id FROM applications WHERE status = 'PENDING' ORDER BY application_id LOOP
    CALL pr_assess_application(r.application_id);
  END LOOP;
END $$;
CALL pr_assess_pending();
CALL pr_assess_pending();      -- rerun: nothing PENDING, no new audit rows
SELECT * FROM v_approved_applicants;
SELECT * FROM decision_audit;
SELECT cron.schedule('q10_assess_pending', '0 8 * * 1', $$CALL q10.pr_assess_pending()$$);
