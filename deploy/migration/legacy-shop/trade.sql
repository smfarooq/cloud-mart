-- Phase 15: the legacy shop is still trading. cron runs this every minute on the simulated on-premises server
-- (/etc/cron.d/legacy-shop), so the database keeps changing until the cutover makes it read-only. After that, each
-- run fails, and the failures are the shop's downtime: journalctl -t legacy-shop
WITH p AS (
    SELECT sku, unit_price FROM shop.products WHERE NOT discontinued ORDER BY random() LIMIT 1
), o AS (
    INSERT INTO shop.orders (customer_id, order_date, status, total)
    SELECT 1 + floor(random() * 2000)::int, localtimestamp, 'N', unit_price FROM p
    RETURNING order_id
)
INSERT INTO shop.order_items (order_id, line_no, sku, qty, unit_price)
SELECT o.order_id, 1, p.sku, 1, p.unit_price FROM o, p;
