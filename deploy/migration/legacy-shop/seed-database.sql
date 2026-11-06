-- Phase 15: the legacy shop's database, on the simulated on-premises server. CloudMart is the rebuild of this shop;
-- this is what the old one kept in PostgreSQL. cloud-init runs it once at first boot, as the local "postgres" user:
--   sudo -u postgres psql -v ON_ERROR_STOP=1 -f /opt/legacy-shop/seed-database.sql
-- It changes nothing when the database already exists, so running it again is harmless.
--
-- The schema is deliberately "legacy": one-letter status codes, timestamps without a time zone, prices copied onto
-- each line, and a product CloudMart doesn't sell. Those are the things an assessment finds and a migration has to
-- decide about. The data is synthetic: no real people.

SELECT 'CREATE DATABASE legacyshop' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'legacyshop') \gexec

\connect legacyshop

CREATE SCHEMA IF NOT EXISTS shop;

CREATE TABLE IF NOT EXISTS shop.customers (
    customer_id  serial PRIMARY KEY,
    email        varchar(200) NOT NULL UNIQUE,
    full_name    varchar(200) NOT NULL,
    created_on   timestamp NOT NULL          -- server local time, no zone: which time zone was the datacentre in?
);

CREATE TABLE IF NOT EXISTS shop.products (
    sku          varchar(64) PRIMARY KEY,    -- the same ids as CloudMart's catalog, so photos and order lines match up
    name         varchar(200) NOT NULL,
    unit_price   numeric(10,2) NOT NULL,
    discontinued boolean NOT NULL DEFAULT false
);

CREATE TABLE IF NOT EXISTS shop.orders (
    order_id     serial PRIMARY KEY,
    customer_id  integer NOT NULL REFERENCES shop.customers,
    order_date   timestamp NOT NULL,
    status       char(1) NOT NULL CHECK (status IN ('N', 'P', 'S', 'X')),  -- new, paid, shipped, cancelled
    total        numeric(12,2) NOT NULL
);

CREATE TABLE IF NOT EXISTS shop.order_items (
    order_id     integer NOT NULL REFERENCES shop.orders ON DELETE CASCADE,
    line_no      smallint NOT NULL,
    sku          varchar(64) NOT NULL REFERENCES shop.products,
    qty          integer NOT NULL CHECK (qty > 0),
    unit_price   numeric(10,2) NOT NULL,
    PRIMARY KEY (order_id, line_no)
);

CREATE INDEX IF NOT EXISTS ix_orders_customer ON shop.orders (customer_id);
CREATE INDEX IF NOT EXISTS ix_orders_date ON shop.orders (order_date);

-- Seed once. Everything below runs in one transaction, so a failed boot leaves no half-filled shop.
BEGIN;

CREATE TEMP TABLE seed_needed ON COMMIT DROP AS SELECT NOT EXISTS (SELECT FROM shop.products) AS yes;

INSERT INTO shop.products (sku, name, unit_price, discontinued)
SELECT * FROM (VALUES
    ('contoso-ultrabook-14',    'Contoso Ultrabook 14',          1399.00, false),
    ('contoso-workstation-16',  'Contoso Workstation 16',        4799.00, false),
    ('fabrikam-anc-headphones', 'Fabrikam ANC Headphones',        229.00, false),
    ('fabrikam-studio-mic',     'Fabrikam Studio Mic',            119.00, false),
    ('northwind-mech-keyboard', 'Northwind Mechanical Keyboard',  109.00, false),
    ('northwind-4k-monitor',    'Northwind 27" 4K Monitor',       499.00, false),
    ('tailspin-smart-speaker',  'Tailspin Smart Speaker',          79.00, false),
    ('woodgrove-desk-lamp',     'Woodgrove Desk Lamp',             49.00, false),
    ('legacy-gift-card',        'Gift card',                       50.00, true)
) AS p(sku, name, unit_price, discontinued)
WHERE (SELECT yes FROM seed_needed);

-- random() is repeatable after setseed(), so every learner's legacy shop holds the same data.
SELECT setseed(0.15);

INSERT INTO shop.customers (email, full_name, created_on)
SELECT format('customer%s@example.com', g), format('Customer %s', g),
       timestamp '2018-01-01' + random() * interval '2500 days'
FROM generate_series(1, 2000) AS g
WHERE (SELECT yes FROM seed_needed);

-- Seven years of trading: 20,000 orders, mostly shipped.
INSERT INTO shop.orders (customer_id, order_date, status, total)
SELECT 1 + floor(random() * 2000)::int,
       timestamp '2019-01-01' + random() * (timestamp '2025-12-31' - timestamp '2019-01-01'),
       (ARRAY['S', 'S', 'S', 'S', 'S', 'S', 'P', 'X', 'N'])[1 + floor(random() * 9)::int],
       0
FROM generate_series(1, 20000)
WHERE (SELECT yes FROM seed_needed);

-- One to three lines per order, spread over the current catalog.
CREATE TEMP TABLE catalog ON COMMIT DROP AS
SELECT row_number() OVER (ORDER BY sku) - 1 AS n, sku, unit_price FROM shop.products WHERE NOT discontinued;

INSERT INTO shop.order_items (order_id, line_no, sku, qty, unit_price)
SELECT o.order_id, l.line_no, c.sku, 1 + (o.order_id + l.line_no) % 3, c.unit_price
FROM shop.orders AS o
CROSS JOIN LATERAL generate_series(1, 1 + o.order_id % 3) AS l(line_no)
JOIN catalog AS c ON c.n = (o.order_id * 7 + l.line_no * 3) % (SELECT count(*) FROM catalog)
WHERE (SELECT yes FROM seed_needed);

-- Every 50th order also bought a gift card: order history that points at a product the new shop doesn't have.
INSERT INTO shop.order_items (order_id, line_no, sku, qty, unit_price)
SELECT order_id, 9, 'legacy-gift-card', 1, 50.00
FROM shop.orders
WHERE order_id % 50 = 0 AND (SELECT yes FROM seed_needed);

UPDATE shop.orders AS o
SET total = s.total
FROM (SELECT order_id, sum(qty * unit_price) AS total FROM shop.order_items GROUP BY order_id) AS s
WHERE s.order_id = o.order_id AND (SELECT yes FROM seed_needed);

COMMIT;

ANALYZE;

SELECT (SELECT count(*) FROM shop.customers) AS customers,
       (SELECT count(*) FROM shop.orders) AS orders,
       (SELECT count(*) FROM shop.order_items) AS order_items,
       pg_size_pretty(pg_database_size(current_database())) AS size;
