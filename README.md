# 130Q--SQL
# Synthetic Data Set Created by ChatGPT
Data Engineering SQL Practice Database
A deterministic synthetic e-commerce and ETL training database for the 130-question PostgreSQL learning roadmap. No real customer data is included.
Requirements
- PostgreSQL 15 or newer (the practice syllabus later uses MERGE)
- A local PostgreSQL database, accessible through psql or pgAdmin
- Sufficient free storage for roughly one million rows across the primary tables (actual disk usage varies depending on PostgreSQL settings)
Import using psql (recommended)
1. Create a separate database (optional but recommended):
   createdb de_training
2. Import the data:
   psql -X -v ON_ERROR_STOP=1 -d de_training -f data_engineering_sql_practice.sql
3. Run this once at the beginning of each new SQL session:
   SET search_path TO de_practice, public;
   SET TIME ZONE 'UTC';
4. Confirm the data loaded:
   SELECT COUNT(*) FROM customers;    -- 10,000
   SELECT COUNT(*) FROM orders;       -- 100,000
   SELECT COUNT(*) FROM order_items;  -- 250,000
   SELECT COUNT(*) FROM payments;     -- 112,000
   SELECT COUNT(*) FROM events;       -- 500,000
   SELECT COUNT(*) FROM stage_orders; -- 25,050
Import using pgAdmin
1. Create a database named de_training (or use another dedicated training database).
2. Open Query Tool for that database.
3. Open data_engineering_sql_practice.sql, then execute it using F5.
4. Inspect the row-count results at the bottom of the script.
5. Whenever you start a new Query Tool session, run the two SET commands above.
Included data
Table	Approximate rows	Why it's included
customers	10,000	Filtering, NULLs, cohorts, missing emails and cities
products	1,000	Product/category analysis and array tags
orders	100,000	Sales, joins, time-series, customer behavior
order_items	250,000	Line-item aggregates, multi-join accuracy
payments	112,000	Payment failures, multi-payment joins
transactions	150,000	Deposits, withdrawals, running balance
departments	12	Hierarchy and salary ranking
employees	300	Self-joins, recursive CTEs, window functions
events	500,000	Funnels, user sessions, JSON, arrays
stage_orders	25,050	Duplicates, bad values, incremental ETL
warehouse_orders	15,000	UPSERT, change processing, re-runs
dim_customer	10,000+	SCD Type 2 and historical as-of joins
bank_accounts	200	Transaction safety and locking
transfer_requests	0	Transfer idempotency practice
salary_audit	0	Audited updates
etl_watermarks	1	Incremental ETL control


Conventions and important edge cases
- UTC: Timestamps are TIMESTAMPTZ. Set your PostgreSQL session timezone to UTC.
- Completed sales: orders.status = 'completed'.
- Financial transactions: transactions.amount is always positive; Deposit and Withdrawal indicate direction.
- Successful payment: payments.payment_status = 'successful'.
- orders.total_amount matches the sum of its order-item extended prices in the core tables.
- customers with IDs 9801–10000 never place orders.
- Duplicate email variants, NULL/empty/whitespace emails, and NULL/empty cities are intentional.
- stage_orders has multiple versions of the same order, 50 injected problematic records, soft deletes, foreign-key violations, and negative amounts by design.
- stage_orders.updated_at and ingested_at are not NULL; later ingestion does not always imply a newer source version.
- events.properties is JSONB. Some records have missing fields, malformed price, negative price, and malformed nested items values.
- Historical customer versions in dim_customer use [effective_from, effective_to) validity ranges.
- The database is synthetic and deterministic, optimized for teaching concepts rather than representing real-world behavioral distributions.
- 
Rerunning the script deletes and recreates only the de_practice schema, including your previous practice changes there. Save your work before rerunning it.
