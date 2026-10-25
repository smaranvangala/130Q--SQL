-- DATA ENGINEERING SQL PRACTICE DATABASE
-- PostgreSQL 15+  |  deterministic synthetic e-commerce + pipeline data
-- Creates: 10k customers, 100k orders, 250k line items, 112k payments,
--          150k bank transactions, 500k events, and supporting tables.
-- IMPORTANT: Running this file REPLACES all objects within schema de_practice.
-- It does NOT modify the public schema or any other schema.
-- Run with: psql -X -v ON_ERROR_STOP=1 -d your_database -f data_engineering_sql_practice.sql

SET client_min_messages = warning;
SET TIME ZONE 'UTC';
SET statement_timeout = 0;

BEGIN;
DROP SCHEMA IF EXISTS de_practice CASCADE;
CREATE SCHEMA de_practice;
SET search_path TO de_practice, public;

-- 1. Core OLTP tables ----------------------------------------------------------
CREATE TABLE customers (
    customer_id INTEGER PRIMARY KEY,
    customer_name TEXT NOT NULL,
    email TEXT,
    city TEXT,
    signup_date DATE NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE products (
    product_id INTEGER PRIMARY KEY,
    product_name TEXT NOT NULL,
    category TEXT NOT NULL,
    list_price NUMERIC(12,2) NOT NULL CHECK (list_price >= 0),
    tags TEXT[] NOT NULL,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE orders (
    order_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    order_ts TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL CHECK (status IN ('completed','cancelled','pending')),
    total_amount NUMERIC(14,2) NOT NULL DEFAULT 0,
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE order_items (
    order_item_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES orders(order_id),
    product_id INTEGER NOT NULL REFERENCES products(product_id),
    quantity INTEGER NOT NULL CHECK (quantity > 0),
    unit_price NUMERIC(12,2) NOT NULL CHECK (unit_price >= 0)
);

CREATE TABLE payments (
    payment_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id INTEGER NOT NULL REFERENCES orders(order_id),
    payment_ts TIMESTAMPTZ NOT NULL,
    amount NUMERIC(14,2) NOT NULL CHECK (amount >= 0),
    payment_status TEXT NOT NULL CHECK (payment_status IN ('successful','failed','pending'))
);

CREATE TABLE transactions (
    transaction_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    transaction_ts TIMESTAMPTZ NOT NULL,
    transaction_type TEXT NOT NULL CHECK (transaction_type IN ('Deposit','Withdrawal')),
    amount NUMERIC(12,2) NOT NULL CHECK (amount > 0),
    updated_at TIMESTAMPTZ NOT NULL
);

CREATE TABLE departments (
    department_id INTEGER PRIMARY KEY,
    department_name TEXT NOT NULL UNIQUE
);

CREATE TABLE employees (
    employee_id INTEGER PRIMARY KEY,
    employee_name TEXT NOT NULL,
    manager_id INTEGER REFERENCES employees(employee_id),
    department_id INTEGER NOT NULL REFERENCES departments(department_id),
    salary NUMERIC(12,2) NOT NULL CHECK (salary > 0),
    hired_at DATE NOT NULL
);

CREATE TABLE events (
    event_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    user_id INTEGER NOT NULL REFERENCES customers(customer_id),
    event_ts TIMESTAMPTZ NOT NULL,
    event_type TEXT NOT NULL,
    session_id TEXT,
    properties JSONB NOT NULL
);

-- 2. Customer and product data ------------------------------------------------
INSERT INTO customers(customer_id, customer_name, email, city, signup_date, updated_at)
SELECT
    n,
    'Customer ' || LPAD(n::text, 5, '0'),
    CASE
      WHEN n % 67 = 0 THEN NULL
      WHEN n % 79 = 0 THEN ''
      WHEN n % 97 = 0 THEN '   '
      WHEN n % 101 = 0 THEN ' Shared' || (n % 20)::text || '@Example.COM '
      ELSE 'customer' || n::text || '@example.com'
    END,
    CASE
      WHEN n % 83 = 0 THEN NULL
      WHEN n % 89 = 0 THEN ''
      ELSE (ARRAY['Seattle','Chicago','Austin','New York','San Francisco',
                  'Boston','Dallas','Denver','Portland','Atlanta'])[1 + (n % 10)]
    END,
    DATE '2025-01-01' + ((n * 37) % 660),
    (DATE '2025-01-01' + ((n * 37) % 660))::timestamptz + INTERVAL '12 hours'
FROM generate_series(1,10000) AS gs(n);

INSERT INTO products(product_id, product_name, category, list_price, tags, updated_at)
SELECT
    n,
    'Product ' || LPAD(n::text, 4, '0'),
    (ARRAY['Electronics','Home','Books','Fashion','Sports',
              'Beauty','Toys','Automotive','Garden','Office'])[1 + ((n-1) % 10)],
    ROUND((20 + ((n*71) % 9000))::numeric / 3, 2),
    ARRAY[
        CASE WHEN (n-1) % 10 = 0 THEN 'electronics' ELSE 'general' END,
        CASE WHEN n % 3 = 0 THEN 'featured' ELSE 'standard' END
    ]::text[],
    TIMESTAMPTZ '2025-01-01 00:00:00+00' + ((n * 11) % 500) * INTERVAL '1 day'
FROM generate_series(1,1000) AS gs(n);

-- 3. Orders, line items, and payments -----------------------------------------
-- Customer IDs 9801-10000 deliberately have no orders for anti-join exercises.
-- Timestamps always fall on/before 2026-10-24 UTC and after customer signup.
INSERT INTO orders(order_id, customer_id, order_ts, status, updated_at)
SELECT n, c.customer_id,
       c.signup_date::timestamptz
         + ((n * 19) % GREATEST(1, DATE '2026-10-24' - c.signup_date + 1)) * INTERVAL '1 day'
         + ((n * 13) % 24) * INTERVAL '1 hour'
         + ((n * 7) % 60) * INTERVAL '1 minute',
       CASE WHEN n % 11 = 0 THEN 'cancelled'
            WHEN n % 7 = 0 THEN 'pending'
            ELSE 'completed' END,
       LEAST(
         c.signup_date::timestamptz
           + ((n * 19) % GREATEST(1, DATE '2026-10-24' - c.signup_date + 1)) * INTERVAL '1 day'
           + ((n * 13) % 24) * INTERVAL '1 hour'
           + ((n * 7) % 60) * INTERVAL '1 minute'
           + ((n % 8) * INTERVAL '1 day'),
         TIMESTAMPTZ '2026-10-24 23:59:59+00'
       )
FROM generate_series(1,100000) AS gs(n)
JOIN customers AS c ON c.customer_id = 1 + ((n * 37) % 9800);

-- 2 items per order plus one extra item on the first 50,000 orders = 250,000.
INSERT INTO order_items(order_id, product_id, quantity, unit_price)
SELECT mapped.order_id,
       p.product_id,
       1 + ((mapped.n * 7) % 4),
       p.list_price
FROM (
   SELECT n,
          CASE WHEN n <= 200000 THEN 1 + ((n - 1) / 2)
               ELSE n - 200000 END AS order_id,
          1 + ((n * 53) % 1000) AS product_id
   FROM generate_series(1,250000) AS gs(n)
) AS mapped
JOIN products AS p ON p.product_id = mapped.product_id;

-- Maintain the documented invariant: orders.total_amount = sum(order item totals).
UPDATE orders AS o
SET total_amount = totals.line_total
FROM (
    SELECT order_id, SUM(quantity * unit_price)::numeric(14,2) AS line_total
    FROM order_items GROUP BY order_id
) AS totals
WHERE totals.order_id = o.order_id;

-- 100,000 first attempts + 12,000 second attempts; intentional failed payments.
-- A fraction of completed orders are unpaid, and some have split payments.
INSERT INTO payments(order_id, payment_ts, amount, payment_status)
SELECT o.order_id,
       o.order_ts + pay.attempt * INTERVAL '1 hour',
       CASE
          WHEN pay.attempt = 2 AND o.order_id % 9 <> 0 THEN 0
          WHEN pay.attempt = 2 THEN o.total_amount - ROUND(o.total_amount * 0.55, 2)
          WHEN o.order_id % 9 = 0 THEN ROUND(o.total_amount * 0.55, 2)
          ELSE o.total_amount
       END,
       CASE
          WHEN o.status = 'completed' AND o.order_id % 17 <> 0
               AND (pay.attempt = 1 OR o.order_id % 9 = 0) THEN 'successful'
          WHEN o.status = 'pending' AND pay.attempt = 1 THEN 'pending'
          ELSE 'failed'
       END
FROM orders AS o
CROSS JOIN LATERAL generate_series(1, CASE WHEN o.order_id <= 12000 THEN 2 ELSE 1 END) AS pay(attempt);

-- 4. Customer financial transactions ------------------------------------------
INSERT INTO transactions(transaction_id, customer_id, transaction_ts,
                         transaction_type, amount, updated_at)
SELECT n,
       1 + ((n * 29) % 10000),
       TIMESTAMPTZ '2025-01-01 00:00:00+00'
         + ((n * 17) % 660) * INTERVAL '1 day'
         + ((n * 11) % 24) * INTERVAL '1 hour',
       CASE WHEN n % 3 = 0 THEN 'Withdrawal' ELSE 'Deposit' END,
       ROUND((10 + (n * 41) % 15000)::numeric / 7, 2),
       TIMESTAMPTZ '2025-01-01 00:00:00+00'
         + ((n * 17) % 660) * INTERVAL '1 day'
         + ((n * 11) % 24) * INTERVAL '1 hour'
         + INTERVAL '1 hour'
FROM generate_series(1,150000) AS gs(n);

-- 5. Department and reporting hierarchy ---------------------------------------
INSERT INTO departments(department_id, department_name)
SELECT n, (ARRAY['Engineering','Marketing','Sales','Finance','Product',
                      'Support','Operations','HR','Legal','Analytics',
                      'Security','Research'])[n]
FROM generate_series(1,12) AS gs(n);

INSERT INTO employees(employee_id, employee_name, manager_id,
                      department_id, salary, hired_at)
SELECT n, 'Employee ' || LPAD(n::text, 3, '0'),
       CASE WHEN n <= 12 THEN NULL ELSE ((n-1) / 12) END,
       1 + ((n-1) % 12),
       (45000 + ((n * 1733) % 125000))::numeric(12,2),
       DATE '2021-01-01' + ((n * 23) % 1700)
FROM generate_series(1,300) AS gs(n);

-- 6. Clickstream: exactly 50 events per customer = 500,000 ---------------------
-- Predictable page_view -> add_to_cart -> purchase patterns, plus malformed JSON.
INSERT INTO events(user_id, event_ts, event_type, session_id, properties)
SELECT c.customer_id,
       c.signup_date::timestamptz
         + LEAST(((seq.n-1) / 10) * 28 + (c.customer_id % 7),
                 DATE '2026-10-24' - c.signup_date) * INTERVAL '1 day'
         + ((seq.n-1) % 10) * INTERVAL '35 minutes',
       x.event_type,
       'sess-' || c.customer_id || '-' || ((seq.n-1) / 10),
       (
         jsonb_build_object(
           'device', CASE WHEN c.customer_id % 3 = 0 THEN 'mobile'
                          WHEN c.customer_id % 3 = 1 THEN 'desktop'
                          ELSE 'tablet' END,
           'campaign', CASE WHEN c.customer_id % 4 = 0 THEN 'fall_sale'
                            ELSE 'organic' END,
           'price', CASE WHEN seq.n = 13 AND c.customer_id % 29 = 0
                         THEN to_jsonb('not_a_number'::text)
                         WHEN seq.n = 17 AND c.customer_id % 31 = 0
                         THEN to_jsonb(-10::integer)
                         ELSE to_jsonb((10 + (c.customer_id % 1000))::integer) END,
           'items', CASE
                WHEN x.event_type <> 'purchase' THEN '[]'::jsonb
                WHEN seq.n = 23 AND c.customer_id % 23 = 0
                   THEN jsonb_build_array(jsonb_build_object(
                       'product_id', c.customer_id % 1000 + 1,
                       'quantity', 'bad', 'unit_price', 20))
                ELSE jsonb_build_array(jsonb_build_object(
                       'product_id', c.customer_id % 1000 + 1,
                       'quantity', 1 + (seq.n % 3),
                       'unit_price', 10 + (c.customer_id % 500)))
                END
         )
         - CASE WHEN seq.n = 22 THEN 'price' ELSE '__no_key__' END
         - CASE WHEN seq.n = 49 THEN 'device' ELSE '__no_key__' END
       )
FROM customers AS c
CROSS JOIN generate_series(1,50) AS seq(n)
CROSS JOIN LATERAL (
    SELECT CASE WHEN seq.n % 10 IN (1,4,8) THEN 'page_view'
                WHEN seq.n % 10 IN (2,5,9) THEN 'add_to_cart'
                WHEN seq.n % 10 IN (3,6,0) THEN 'purchase'
                ELSE 'login' END AS event_type
) AS x;

-- 7. Raw staging and warehouse tables -----------------------------------------
-- Staging permits duplicates, missing IDs, bad foreign keys, negative prices,
-- source deletes, and out-of-order version arrival on purpose.
CREATE TABLE stage_orders (
    stage_row_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id INTEGER,
    customer_id INTEGER,
    order_ts TIMESTAMPTZ,
    status TEXT,
    total_amount NUMERIC(14,2),
    updated_at TIMESTAMPTZ NOT NULL,
    ingested_at TIMESTAMPTZ NOT NULL,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE warehouse_orders (
    order_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL,
    order_ts TIMESTAMPTZ NOT NULL,
    status TEXT NOT NULL,
    total_amount NUMERIC(14,2) NOT NULL,
    last_source_updated_at TIMESTAMPTZ NOT NULL,
    is_deleted BOOLEAN NOT NULL DEFAULT FALSE
);

INSERT INTO stage_orders(order_id, customer_id, order_ts, status, total_amount,
                         updated_at, ingested_at, is_deleted)
SELECT order_id, customer_id, order_ts, status, total_amount,
       updated_at, updated_at + INTERVAL '2 hours', FALSE
FROM orders WHERE order_id <= 20000;

-- 5,000 newer versions, some updated totals and soft-delete events.
INSERT INTO stage_orders(order_id, customer_id, order_ts, status, total_amount,
                         updated_at, ingested_at, is_deleted)
SELECT order_id, customer_id, order_ts, status,
       CASE WHEN order_id % 20 = 0 THEN total_amount + 25 ELSE total_amount END,
       updated_at + INTERVAL '1 day',
       updated_at + INTERVAL '1 day 2 hours',
       (order_id % 101 = 0)
FROM orders WHERE order_id <= 20000 AND order_id % 4 = 0;

-- 50 intentional data-quality violations, identifiable by stage_row_id > 25000.
INSERT INTO stage_orders(order_id, customer_id, order_ts, status, total_amount,
                         updated_at, ingested_at, is_deleted)
SELECT CASE WHEN n % 5 = 0 THEN NULL ELSE 20000 + n END,
       CASE WHEN n % 5 = 1 THEN 999999 ELSE 1 END,
       CASE WHEN n % 5 = 2 THEN TIMESTAMPTZ '2026-04-10 00:00:00+00'
            ELSE TIMESTAMPTZ '2026-04-01 00:00:00+00' END,
       'completed',
       CASE WHEN n % 5 = 3 THEN -250::numeric ELSE 100::numeric END,
       CASE WHEN n % 5 = 2 THEN TIMESTAMPTZ '2026-04-01 00:00:00+00'
            ELSE TIMESTAMPTZ '2026-04-12 00:00:00+00' END,
       TIMESTAMPTZ '2026-04-14 00:00:00+00' + n * INTERVAL '1 minute',
       FALSE
FROM generate_series(1,50) AS gs(n);

INSERT INTO warehouse_orders(order_id, customer_id, order_ts, status,
                             total_amount, last_source_updated_at, is_deleted)
SELECT order_id, customer_id, order_ts, status, total_amount, updated_at, FALSE
FROM orders WHERE order_id <= 15000;

-- 8. Dimension history for SCD Type 2 -----------------------------------------
CREATE TABLE dim_customer (
    customer_sk BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    email TEXT,
    city TEXT,
    effective_from TIMESTAMPTZ NOT NULL,
    effective_to TIMESTAMPTZ,
    is_current BOOLEAN NOT NULL,
    UNIQUE(customer_id, effective_from),
    CHECK(effective_to IS NULL OR effective_to > effective_from)
);

-- Earlier historical version for selected customers.
INSERT INTO dim_customer(customer_id, email, city, effective_from, effective_to, is_current)
SELECT customer_id, email, 'Former City', signup_date::timestamptz,
       signup_date::timestamptz + INTERVAL '60 days', FALSE
FROM customers
WHERE customer_id <= 500 AND signup_date < DATE '2026-08-01';

-- Current version for everyone, effective after historical version where present.
INSERT INTO dim_customer(customer_id, email, city, effective_from, effective_to, is_current)
SELECT customer_id, email, city,
       signup_date::timestamptz
          + CASE WHEN customer_id <= 500 AND signup_date < DATE '2026-08-01'
                 THEN INTERVAL '60 days' ELSE INTERVAL '0 days' END,
       NULL, TRUE
FROM customers;

CREATE UNIQUE INDEX idx_dim_customer_one_current
    ON dim_customer(customer_id) WHERE is_current;

-- 9. Supporting tables for transaction and ETL-control exercises --------------
CREATE TABLE salary_audit (
    audit_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    employee_id INTEGER NOT NULL REFERENCES employees(employee_id),
    old_salary NUMERIC(12,2) NOT NULL,
    new_salary NUMERIC(12,2) NOT NULL,
    changed_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE bank_accounts (
    account_id INTEGER PRIMARY KEY,
    customer_id INTEGER NOT NULL REFERENCES customers(customer_id),
    balance NUMERIC(14,2) NOT NULL CHECK(balance >= 0)
);

CREATE TABLE transfer_requests (
    transfer_id TEXT PRIMARY KEY,
    from_account_id INTEGER NOT NULL REFERENCES bank_accounts(account_id),
    to_account_id INTEGER NOT NULL REFERENCES bank_accounts(account_id),
    transfer_amount NUMERIC(14,2) NOT NULL CHECK(transfer_amount > 0),
    transfer_status TEXT NOT NULL CHECK(transfer_status IN ('pending','completed','rejected')),
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    CHECK(from_account_id <> to_account_id)
);

CREATE TABLE etl_watermarks (
    pipeline_name TEXT PRIMARY KEY,
    last_successful_updated_at TIMESTAMPTZ NOT NULL,
    last_successful_row_id BIGINT NOT NULL DEFAULT 0,
    last_run_at TIMESTAMPTZ
);

INSERT INTO bank_accounts(account_id, customer_id, balance)
SELECT n, n, (2000 + (n * 37) % 50000)::numeric(14,2)
FROM generate_series(1,200) AS gs(n);

INSERT INTO etl_watermarks(pipeline_name, last_successful_updated_at)
VALUES ('orders_incremental', TIMESTAMPTZ '2025-01-01 00:00:00+00');

-- Selected supporting indexes. Other indexes are deliberately left for Stage 13.
CREATE INDEX idx_order_items_order_id ON order_items(order_id);
CREATE INDEX idx_payments_order_id ON payments(order_id);
CREATE INDEX idx_events_user_ts ON events(user_id, event_ts, event_id);
CREATE INDEX idx_stage_orders_key ON stage_orders(order_id, updated_at DESC);
CREATE INDEX idx_transactions_customer_ts ON transactions(customer_id, transaction_ts);

COMMIT;

SET search_path TO de_practice, public;
ANALYZE;

-- 10. Import verification (prints table names and row counts) -----------------
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM customers
UNION ALL SELECT 'products', COUNT(*) FROM products
UNION ALL SELECT 'orders', COUNT(*) FROM orders
UNION ALL SELECT 'order_items', COUNT(*) FROM order_items
UNION ALL SELECT 'payments', COUNT(*) FROM payments
UNION ALL SELECT 'transactions', COUNT(*) FROM transactions
UNION ALL SELECT 'departments', COUNT(*) FROM departments
UNION ALL SELECT 'employees', COUNT(*) FROM employees
UNION ALL SELECT 'events', COUNT(*) FROM events
UNION ALL SELECT 'stage_orders', COUNT(*) FROM stage_orders
UNION ALL SELECT 'warehouse_orders', COUNT(*) FROM warehouse_orders
UNION ALL SELECT 'dim_customer', COUNT(*) FROM dim_customer
ORDER BY table_name;

SELECT
  (SELECT COUNT(*) FROM customers WHERE customer_id NOT IN
     (SELECT DISTINCT customer_id FROM orders)) AS customers_without_orders,
  (SELECT COUNT(*) FROM (
    SELECT order_id FROM stage_orders WHERE order_id IS NOT NULL
    GROUP BY order_id HAVING COUNT(*) > 1
  ) d) AS duplicate_staging_order_ids,
  (SELECT COUNT(*) FROM stage_orders WHERE order_id IS NULL) AS null_staging_order_ids,
  (SELECT COUNT(*) FROM stage_orders WHERE total_amount < 0) AS negative_staging_amounts;

-- In a new connection, first run: SET search_path TO de_practice, public;
-- To remove the training database: DROP SCHEMA de_practice CASCADE;
