-- =====================================================================
-- OLIST E-COMMERCE DATA CLEANING & PROFITABILITY ANALYSIS
-- =====================================================================
-- Business question:
--   Where is Olist's logistics/freight cost eroding profit margin,
--   broken down by product category, customer state, and fulfillment
--   type (local vs cross-state)?
--
-- Approach:
--   1. Audit and clean raw tables (duplicates, nulls) via reproducible
--      SQL views — never destructive TRUNCATE — so the pipeline can be
--      re-run end to end from the raw CSV load.
--   2. Flag statistical outliers (IQR method) in delivery time,
--      payments, and product dimensions.
--   3. Quantify freight-to-price ratio and margin health by category,
--      state, and fulfillment type.
--
-- Key finding (Executive Verdict):
--   Profitability is a structural, not incidental, problem: logistics
--   cost frequently outpaces the base product price on specific
--   category/state combinations, eroding margin regardless of order
--   volume. Leakage happens specifically when freight value exceeds
--   product price. Recommended fix: decentralize fulfillment
--   (hub-and-spoke / dark stores) and enforce a minimum basket size
--   for high-freight-ratio categories.
-- =====================================================================

CREATE DATABASE IF NOT EXISTS olist;
USE olist;

-- ---------------------------------------------------------------------
-- 0. ROW COUNT OVERVIEW
-- ---------------------------------------------------------------------
SELECT 'customers' AS table_name, COUNT(*) AS row_count FROM olist_customers_dataset
UNION ALL
SELECT 'geolocation', COUNT(*) FROM olist_geolocation_dataset
UNION ALL
SELECT 'orders', COUNT(*) FROM olist_orders_dataset
UNION ALL
SELECT 'order_items', COUNT(*) FROM olist_order_items_dataset
UNION ALL
SELECT 'order_payments', COUNT(*) FROM olist_order_payments_dataset
UNION ALL
SELECT 'order_reviews', COUNT(*) FROM olist_order_reviews_dataset
UNION ALL
SELECT 'products', COUNT(*) FROM olist_products_dataset
UNION ALL
SELECT 'sellers', COUNT(*) FROM olist_sellers_dataset;


-- =====================================================================
-- 1. ORDERS — DUPLICATE AUDIT & CLEAN VIEW
-- =====================================================================
-- Audit: find exact duplicate rows (the raw CSV was loaded more than
-- once, so duplicates match on every column, not just order_id).
SELECT order_id, customer_id, order_status, order_purchase_timestamp,
       COUNT(*) AS exact_copy_count
FROM olist_orders_dataset
GROUP BY order_id, customer_id, order_status, order_purchase_timestamp
HAVING COUNT(*) > 1
LIMIT 5;

-- Clean view: deduplicate in-SQL instead of TRUNCATE + manual reload.
-- This keeps the pipeline reproducible — anyone can re-run this script
-- against the raw load and get the same clean result.
CREATE OR REPLACE VIEW v_orders_clean AS
SELECT
    order_id, customer_id, order_status, order_purchase_timestamp,
    order_approved_at, order_delivered_carrier_date,
    order_delivered_customer_date, order_estimated_delivery_date
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY order_id, customer_id, order_status,
                            order_purchase_timestamp, order_approved_at,
                            order_delivered_carrier_date,
                            order_delivered_customer_date,
                            order_estimated_delivery_date
           ) AS rn
    FROM olist_orders_dataset
) t
WHERE rn = 1;

-- Audit check on the clean view (must return 0 rows).
SELECT order_id, customer_id, order_status, order_purchase_timestamp,
       COUNT(*)
FROM v_orders_clean
GROUP BY order_id, customer_id, order_status, order_purchase_timestamp
HAVING COUNT(*) > 1;

-- Null check.
SELECT
    COUNT(*) AS total_orders,
    SUM(order_id IS NULL) AS null_order_id,
    SUM(customer_id IS NULL) AS null_customer_id,
    SUM(order_status IS NULL) AS null_order_status,
    SUM(order_purchase_timestamp IS NULL) AS null_purchase_time,
    SUM(order_approved_at IS NULL) AS null_approved_at,
    SUM(order_delivered_carrier_date IS NULL) AS null_carrier_date,
    SUM(order_delivered_customer_date IS NULL) AS null_customer_delivery_date,
    SUM(order_estimated_delivery_date IS NULL) AS null_estimated_date
FROM v_orders_clean;


-- ---------------------------------------------------------------------
-- Delivery time outlier detection (IQR method)
-- ---------------------------------------------------------------------
WITH OrderDelays AS (
    SELECT
        order_id,
        customer_id,
        order_status,
        DATEDIFF(
            STR_TO_DATE(order_delivered_customer_date, '%Y-%m-%d %H:%i:%s'),
            STR_TO_DATE(order_purchase_timestamp, '%Y-%m-%d %H:%i:%s')
        ) AS delivery_days,
        DATEDIFF(
            STR_TO_DATE(order_delivered_customer_date, '%Y-%m-%d %H:%i:%s'),
            STR_TO_DATE(order_estimated_delivery_date, '%Y-%m-%d %H:%i:%s')
        ) AS delay_vs_estimate_days
    FROM v_orders_clean
    WHERE order_status = 'delivered'
      AND order_delivered_customer_date IS NOT NULL
      AND order_delivered_customer_date != ''
      AND order_purchase_timestamp IS NOT NULL
      AND order_purchase_timestamp != ''
),
RankedDelays AS (
    SELECT *,
           ROW_NUMBER() OVER (ORDER BY delivery_days) AS r_delivery,
           ROW_NUMBER() OVER (ORDER BY delay_vs_estimate_days) AS r_delay,
           COUNT(*) OVER () AS total_rows
    FROM OrderDelays
),
DelayBounds AS (
    SELECT
        ROUND(
            MAX(CASE WHEN r_delivery = FLOOR(total_rows * 0.75) THEN delivery_days END) +
            1.5 * (MAX(CASE WHEN r_delivery = FLOOR(total_rows * 0.75) THEN delivery_days END) -
                   MAX(CASE WHEN r_delivery = FLOOR(total_rows * 0.25) THEN delivery_days END)), 2
        ) AS delivery_days_upper_bound,
        ROUND(
            MAX(CASE WHEN r_delay = FLOOR(total_rows * 0.75) THEN delay_vs_estimate_days END) +
            1.5 * (MAX(CASE WHEN r_delay = FLOOR(total_rows * 0.75) THEN delay_vs_estimate_days END) -
                   MAX(CASE WHEN r_delay = FLOOR(total_rows * 0.25) THEN delay_vs_estimate_days END)), 2
        ) AS delay_vs_estimate_upper_bound
    FROM RankedDelays
)
SELECT
    rd.order_id, rd.customer_id, rd.order_status,
    rd.delivery_days, db.delivery_days_upper_bound,
    CASE WHEN rd.delivery_days > db.delivery_days_upper_bound THEN 1 ELSE 0 END AS is_delivery_time_outlier,
    rd.delay_vs_estimate_days, db.delay_vs_estimate_upper_bound,
    CASE WHEN rd.delay_vs_estimate_days > db.delay_vs_estimate_upper_bound THEN 1 ELSE 0 END AS is_delay_vs_estimate_outlier
FROM RankedDelays rd
CROSS JOIN DelayBounds db;


-- =====================================================================
-- 2. CUSTOMERS — DUPLICATE AUDIT & CLEAN VIEW
-- =====================================================================
SELECT
    (SELECT COUNT(*) FROM olist_customers_dataset) AS total_rows,
    (SELECT COUNT(DISTINCT customer_id) FROM olist_customers_dataset) AS unique_rows,
    (SELECT COUNT(*) FROM olist_customers_dataset) /
    (SELECT COUNT(DISTINCT customer_id) FROM olist_customers_dataset) AS duplication_ratio;

SELECT customer_zip_code_prefix, customer_id, COUNT(*) AS exact_copy_count
FROM olist_customers_dataset
GROUP BY customer_zip_code_prefix, customer_id
HAVING COUNT(*) > 1
LIMIT 5;

CREATE OR REPLACE VIEW v_customers_clean AS
SELECT customer_id, customer_unique_id, customer_zip_code_prefix,
       customer_city, customer_state
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY customer_id) AS rn
    FROM olist_customers_dataset
) t
WHERE rn = 1;

-- Null check.
SELECT
    COUNT(*) AS total_records,
    SUM(customer_id IS NULL) AS null_customer_id,
    SUM(customer_unique_id IS NULL) AS null_customer_unique_id,
    SUM(customer_zip_code_prefix IS NULL) AS null_zip_code,
    SUM(customer_city IS NULL) AS null_city,
    SUM(customer_state IS NULL) AS null_state
FROM v_customers_clean;


-- =====================================================================
-- 3. PRODUCTS — DUPLICATE AUDIT, NULL HANDLING & CLEAN VIEW
-- =====================================================================
SELECT product_id, COUNT(*)
FROM olist_products_dataset
GROUP BY product_id
HAVING COUNT(*) > 1;

-- Clean view: dedup by product_id AND fill missing dimensions with 0 /
-- 'Uncategorized' instead of truncating the table.
CREATE OR REPLACE VIEW v_products_clean AS
SELECT
    product_id,
    COALESCE(product_category_name, 'Uncategorized') AS product_category_name,
    COALESCE(product_name_lenght, 0) AS product_name_length,
    COALESCE(product_description_lenght, 0) AS product_description_length,
    COALESCE(product_photos_qty, 0) AS product_photos_qty,
    COALESCE(product_weight_g, 0) AS product_weight_g,
    COALESCE(product_length_cm, 0) AS product_length_cm,
    COALESCE(product_height_cm, 0) AS product_height_cm,
    COALESCE(product_width_cm, 0) AS product_width_cm
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY product_id) AS rn
    FROM olist_products_dataset
) t
WHERE rn = 1;

-- Null check on the raw table (pre-cleaning visibility).
SELECT
    COUNT(*) AS total_products,
    SUM(product_id IS NULL) AS null_product_id,
    SUM(product_category_name IS NULL) AS null_category_name,
    SUM(product_name_lenght IS NULL) AS null_name_length,
    SUM(product_description_lenght IS NULL) AS null_desc_length,
    SUM(product_photos_qty IS NULL) AS null_photos_qty
FROM olist_products_dataset;


-- ---------------------------------------------------------------------
-- Product dimension outlier detection (IQR method)
-- ---------------------------------------------------------------------
WITH RankedProducts AS (
    SELECT
        product_id, product_category_name,
        product_weight_g, product_length_cm, product_height_cm, product_width_cm,
        ROW_NUMBER() OVER (ORDER BY product_weight_g) AS r_w,
        ROW_NUMBER() OVER (ORDER BY product_length_cm) AS r_l,
        ROW_NUMBER() OVER (ORDER BY product_height_cm) AS r_h,
        ROW_NUMBER() OVER (ORDER BY product_width_cm) AS r_wd,
        COUNT(*) OVER () AS total_rows
    FROM v_products_clean
),
ProductBounds AS (
    SELECT
        ROUND(MAX(CASE WHEN r_w = ROUND(total_rows * 0.75) THEN product_weight_g END) +
              1.5 * (MAX(CASE WHEN r_w = ROUND(total_rows * 0.75) THEN product_weight_g END) -
                     MAX(CASE WHEN r_w = ROUND(total_rows * 0.25) THEN product_weight_g END)), 2) AS weight_upper_bound,
        ROUND(MAX(CASE WHEN r_l = ROUND(total_rows * 0.75) THEN product_length_cm END) +
              1.5 * (MAX(CASE WHEN r_l = ROUND(total_rows * 0.75) THEN product_length_cm END) -
                     MAX(CASE WHEN r_l = ROUND(total_rows * 0.25) THEN product_length_cm END)), 2) AS length_upper_bound,
        ROUND(MAX(CASE WHEN r_h = ROUND(total_rows * 0.75) THEN product_height_cm END) +
              1.5 * (MAX(CASE WHEN r_h = ROUND(total_rows * 0.75) THEN product_height_cm END) -
                     MAX(CASE WHEN r_h = ROUND(total_rows * 0.25) THEN product_height_cm END)), 2) AS height_upper_bound,
        ROUND(MAX(CASE WHEN r_wd = ROUND(total_rows * 0.75) THEN product_width_cm END) +
              1.5 * (MAX(CASE WHEN r_wd = ROUND(total_rows * 0.75) THEN product_width_cm END) -
                     MAX(CASE WHEN r_wd = ROUND(total_rows * 0.25) THEN product_width_cm END)), 2) AS width_upper_bound
    FROM RankedProducts
)
SELECT
    p_data.product_id, p_data.product_category_name,
    p_data.product_weight_g, p_bounds.weight_upper_bound,
    p_data.product_length_cm, p_bounds.length_upper_bound,
    p_data.product_height_cm, p_bounds.height_upper_bound,
    p_data.product_width_cm, p_bounds.width_upper_bound,
    CASE WHEN p_data.product_weight_g > p_bounds.weight_upper_bound THEN 1 ELSE 0 END AS is_weight_outlier,
    CASE WHEN p_data.product_length_cm > p_bounds.length_upper_bound THEN 1 ELSE 0 END AS is_length_outlier,
    CASE WHEN p_data.product_height_cm > p_bounds.height_upper_bound THEN 1 ELSE 0 END AS is_height_outlier,
    CASE WHEN p_data.product_width_cm > p_bounds.width_upper_bound THEN 1 ELSE 0 END AS is_width_outlier
FROM RankedProducts AS p_data
CROSS JOIN ProductBounds AS p_bounds;


-- =====================================================================
-- 4. SELLERS — DUPLICATE AUDIT & CLEAN VIEW
-- =====================================================================
SELECT seller_id, COUNT(*)
FROM olist_sellers_dataset
GROUP BY seller_id
HAVING COUNT(*) > 1;

CREATE OR REPLACE VIEW v_sellers_clean AS
SELECT seller_id, seller_zip_code_prefix, seller_city, seller_state
FROM (
    SELECT *,
           ROW_NUMBER() OVER (PARTITION BY seller_id) AS rn
    FROM olist_sellers_dataset
) t
WHERE rn = 1;

-- Null check.
SELECT
    COUNT(*) AS total_sellers,
    SUM(seller_id IS NULL) AS null_seller_id,
    SUM(seller_zip_code_prefix IS NULL) AS null_zip_code,
    SUM(seller_city IS NULL) AS null_city,
    SUM(seller_state IS NULL) AS null_state
FROM v_sellers_clean;


-- =====================================================================
-- 5. ORDER PAYMENTS — DEDUP & OUTLIER DETECTION
-- =====================================================================
-- Backup before touching anything (kept from original — good practice).
CREATE TABLE IF NOT EXISTS payments_backup AS
SELECT * FROM olist_order_payments_dataset;

CREATE OR REPLACE VIEW v_olist_payments_clean AS
SELECT order_id, payment_sequential, payment_type, payment_installments, payment_value
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY order_id, payment_sequential, payment_type,
                            payment_installments, payment_value
               ORDER BY order_id ASC
           ) AS rn
    FROM olist_order_payments_dataset
) t
WHERE rn = 1;

-- Audit check (must return 0 rows).
SELECT order_id, payment_sequential, COUNT(*)
FROM v_olist_payments_clean
GROUP BY order_id, payment_sequential
HAVING COUNT(*) > 1;

-- Null check.
SELECT
    COUNT(*) AS total_payments,
    SUM(order_id IS NULL) AS null_order_id,
    SUM(payment_sequential IS NULL) AS null_payment_seq,
    SUM(payment_type IS NULL) AS null_payment_type,
    SUM(payment_installments IS NULL) AS null_payment_installments,
    SUM(payment_value IS NULL) AS null_payment_value
FROM v_olist_payments_clean;

-- Outlier detection by payment type (IQR method).
WITH RankedPayments AS (
    SELECT
        order_id, payment_type, payment_sequential, payment_installments, payment_value,
        ROW_NUMBER() OVER (PARTITION BY payment_type ORDER BY payment_sequential) AS r_seq,
        ROW_NUMBER() OVER (PARTITION BY payment_type ORDER BY payment_installments) AS r_inst,
        ROW_NUMBER() OVER (PARTITION BY payment_type ORDER BY payment_value) AS r_val,
        COUNT(*) OVER (PARTITION BY payment_type) AS total_rows
    FROM v_olist_payments_clean
    WHERE payment_sequential IS NOT NULL
      AND payment_installments IS NOT NULL
      AND payment_value IS NOT NULL
),
PaymentBounds AS (
    SELECT
        payment_type,
        ROUND(
            MAX(CASE WHEN r_seq = FLOOR(total_rows * 0.75) THEN payment_sequential END) +
            1.5 * (MAX(CASE WHEN r_seq = FLOOR(total_rows * 0.75) THEN payment_sequential END) -
                   MAX(CASE WHEN r_seq = FLOOR(total_rows * 0.25) THEN payment_sequential END)), 2
        ) AS seq_upper_bound,
        ROUND(
            MAX(CASE WHEN r_inst = FLOOR(total_rows * 0.75) THEN payment_installments END) +
            1.5 * (MAX(CASE WHEN r_inst = FLOOR(total_rows * 0.75) THEN payment_installments END) -
                   MAX(CASE WHEN r_inst = FLOOR(total_rows * 0.25) THEN payment_installments END)), 2
        ) AS inst_upper_bound,
        ROUND(
            MAX(CASE WHEN r_val = FLOOR(total_rows * 0.75) THEN payment_value END) +
            1.5 * (MAX(CASE WHEN r_val = FLOOR(total_rows * 0.75) THEN payment_value END) -
                   MAX(CASE WHEN r_val = FLOOR(total_rows * 0.25) THEN payment_value END)), 2
        ) AS val_upper_bound
    FROM RankedPayments
    GROUP BY payment_type
),
FlaggedOutliers AS (
    SELECT
        p_data.order_id, p_data.payment_type,
        p_data.payment_sequential, p_bounds.seq_upper_bound,
        CASE WHEN p_data.payment_sequential > p_bounds.seq_upper_bound THEN 1 ELSE 0 END AS is_seq_outlier,
        p_data.payment_installments, p_bounds.inst_upper_bound,
        CASE WHEN p_data.payment_installments > p_bounds.inst_upper_bound THEN 1 ELSE 0 END AS is_inst_outlier,
        p_data.payment_value, p_bounds.val_upper_bound,
        CASE WHEN p_data.payment_value > p_bounds.val_upper_bound THEN 1 ELSE 0 END AS is_val_outlier
    FROM RankedPayments AS p_data
    JOIN PaymentBounds AS p_bounds ON p_data.payment_type = p_bounds.payment_type
)
-- Final output: outliers removed.
SELECT order_id, payment_type, payment_sequential, payment_installments, payment_value
FROM FlaggedOutliers
WHERE is_val_outlier = 0
  AND is_inst_outlier = 0
  AND is_seq_outlier = 0;


-- =====================================================================
-- 6. ORDER REVIEWS — DUPLICATE CHECK
-- =====================================================================
SELECT order_id, review_id, COUNT(*)
FROM olist_order_reviews_dataset
GROUP BY order_id, review_id
HAVING COUNT(*) > 1;

SELECT
    COUNT(*) AS total_reviews,
    SUM(review_id IS NULL) AS null_review_id,
    SUM(order_id IS NULL) AS null_order_id,
    SUM(review_score IS NULL) AS null_review_score,
    SUM(review_comment_title IS NULL) AS null_comment_title,
    SUM(review_comment_message IS NULL) AS null_comment_message,
    SUM(review_creation_date IS NULL) AS null_creation_date,
    SUM(review_answer_timestamp IS NULL) AS null_answer_timestamp
FROM olist_order_reviews_dataset;


-- =====================================================================
-- 7. ORDER ITEMS — DEDUP & CLEAN VIEW
-- =====================================================================
-- Backup before touching anything.
CREATE TABLE IF NOT EXISTS items_backup AS
SELECT * FROM olist_order_items_dataset;

CREATE OR REPLACE VIEW v_order_items_clean AS
SELECT order_id, order_item_id, product_id, seller_id, shipping_limit_date, price, freight_value
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY order_id, order_item_id, product_id, seller_id,
                            shipping_limit_date, price, freight_value
           ) AS rn
    FROM olist_order_items_dataset
) t
WHERE rn = 1;

-- Audit check (must return 0 rows).
SELECT order_id, product_id, order_item_id, COUNT(*)
FROM v_order_items_clean
GROUP BY order_id, product_id, order_item_id
HAVING COUNT(*) > 1;

-- Null check.
SELECT
    COUNT(*) AS total_items,
    SUM(order_id IS NULL) AS null_order_id,
    SUM(order_item_id IS NULL) AS null_order_item_id,
    SUM(product_id IS NULL) AS null_product_id,
    SUM(seller_id IS NULL) AS null_seller_id,
    SUM(shipping_limit_date IS NULL) AS null_shipping_limit_date,
    SUM(price IS NULL) AS null_price,
    SUM(freight_value IS NULL) AS null_freight_value
FROM v_order_items_clean;


-- =====================================================================
-- 8. GEOLOCATION — DEDUP & CLEAN VIEW
-- =====================================================================
CREATE TABLE IF NOT EXISTS geolocation_backup AS
SELECT * FROM olist_geolocation_dataset;

CREATE OR REPLACE VIEW v_geolocation_clean AS
SELECT geolocation_zip_code_prefix, geolocation_lat, geolocation_lng,
       geolocation_city, geolocation_state
FROM (
    SELECT *,
           ROW_NUMBER() OVER (
               PARTITION BY geolocation_zip_code_prefix
               ORDER BY geolocation_lat
           ) AS rn
    FROM olist_geolocation_dataset
) t
WHERE rn = 1;

-- Audit check (must return 0 rows).
SELECT geolocation_zip_code_prefix, COUNT(*)
FROM v_geolocation_clean
GROUP BY geolocation_zip_code_prefix
HAVING COUNT(*) > 1;

-- Null check.
SELECT
    COUNT(*) AS total_records,
    SUM(geolocation_zip_code_prefix IS NULL) AS null_zip_prefix,
    SUM(geolocation_lat IS NULL) AS null_lat,
    SUM(geolocation_lng IS NULL) AS null_lng,
    SUM(geolocation_city IS NULL) AS null_city,
    SUM(geolocation_state IS NULL) AS null_state
FROM v_geolocation_clean;


-- =====================================================================
-- 9. SELLER PERFORMANCE — VOLUME OUTLIER DETECTION (IQR METHOD)
-- =====================================================================
WITH SellerPerformance AS (
    SELECT seller_id, COUNT(order_id) AS total_orders
    FROM v_order_items_clean
    GROUP BY seller_id
),
RankedSellers AS (
    SELECT seller_id, total_orders,
           ROW_NUMBER() OVER (ORDER BY total_orders) AS rn,
           COUNT(*) OVER () AS total_rows
    FROM SellerPerformance
),
Quartiles AS (
    SELECT
        MAX(CASE WHEN rn = FLOOR(total_rows * 0.25) THEN total_orders END) AS q1,
        MAX(CASE WHEN rn = FLOOR(total_rows * 0.75) THEN total_orders END) AS q3
    FROM RankedSellers
),
Bounds AS (
    SELECT q1, q3, q3 + 1.5 * (q3 - q1) AS upper_bound
    FROM Quartiles
),
ScoredSellers AS (
    SELECT sp.seller_id, sp.total_orders, b.upper_bound,
           CASE WHEN sp.total_orders > b.upper_bound THEN 1 ELSE 0 END AS is_volume_outlier
    FROM SellerPerformance sp
    CROSS JOIN Bounds b
)
-- Select only non-outlier sellers (high-volume outliers removed).
SELECT seller_id, total_orders, upper_bound
FROM ScoredSellers
WHERE is_volume_outlier = 0
ORDER BY total_orders DESC;


-- =====================================================================
-- 10. PAYMENT VALUE OUTLIER DETECTION (IQR METHOD)
-- =====================================================================
WITH PaymentMetrics AS (
    SELECT order_id, payment_value
    FROM v_olist_payments_clean
),
RankedPayments AS (
    SELECT order_id, payment_value,
           ROW_NUMBER() OVER (ORDER BY payment_value) AS rn,
           COUNT(*) OVER () AS total_rows
    FROM PaymentMetrics
),
Quartiles AS (
    SELECT
        MAX(CASE WHEN rn = FLOOR(total_rows * 0.25) THEN payment_value END) AS q1,
        MAX(CASE WHEN rn = FLOOR(total_rows * 0.75) THEN payment_value END) AS q3
    FROM RankedPayments
),
Bounds AS (
    SELECT q1, q3, q3 + 1.5 * (q3 - q1) AS upper_bound
    FROM Quartiles
),
ScoredPayments AS (
    SELECT pm.order_id, pm.payment_value, b.upper_bound,
           CASE WHEN pm.payment_value > b.upper_bound THEN 1 ELSE 0 END AS is_payment_outlier
    FROM PaymentMetrics pm
    CROSS JOIN Bounds b
)
-- Select only non-outlier payments (extreme high-value payments removed).
SELECT order_id, payment_value, upper_bound
FROM ScoredPayments
WHERE is_payment_outlier = 0
ORDER BY payment_value DESC;


-- =====================================================================
-- 11. PROFIT MARGIN ANALYSIS BY STATE & FULFILLMENT TYPE
-- =====================================================================
WITH OrderFinancials AS (
    SELECT
        o.order_id,
        c.customer_state,
        s.seller_state,
        oi.freight_value,
        op.payment_value,
        CASE
            WHEN c.customer_state = s.seller_state THEN 'Local (Same State)'
            ELSE 'Cross-State (Long Distance)'
        END AS fulfillment_type
    FROM v_orders_clean o
    JOIN v_order_items_clean oi ON o.order_id = oi.order_id
    JOIN v_sellers_clean s ON oi.seller_id = s.seller_id
    JOIN v_customers_clean c ON o.customer_id = c.customer_id
    JOIN v_olist_payments_clean op ON o.order_id = op.order_id
)
SELECT
    customer_state,
    fulfillment_type,
    COUNT(order_id) AS total_orders,
    ROUND(AVG(payment_value), 2) AS avg_payment_value,
    ROUND(AVG(freight_value), 2) AS avg_freight_value,
    ROUND(AVG(freight_value / NULLIF(payment_value, 0)) * 100, 2) AS avg_freight_percentage_of_payment,
    CASE
        WHEN AVG(freight_value / NULLIF(payment_value, 0)) > 0.30 THEN 'High Margin Erosion (Loss State)'
        WHEN AVG(freight_value / NULLIF(payment_value, 0)) BETWEEN 0.15 AND 0.30 THEN 'Break-Even / Moderate Margin'
        ELSE 'Healthy Profit Margin'
    END AS business_health_state
FROM OrderFinancials
GROUP BY customer_state, fulfillment_type
ORDER BY
    CASE
        WHEN AVG(freight_value / NULLIF(payment_value, 0)) <= 0.15 THEN 1
        WHEN AVG(freight_value / NULLIF(payment_value, 0)) BETWEEN 0.15 AND 0.30 THEN 2
        ELSE 3
    END ASC,
    avg_freight_percentage_of_payment DESC;


-- =====================================================================
-- 12. FREIGHT-TO-PRICE RATIO BY PRODUCT CATEGORY
-- =====================================================================
-- Top 10 categories where freight eats the most into the product price.
SELECT
    p.product_category_name,
    COUNT(oi.order_id) AS total_orders,
    ROUND(AVG(oi.price), 2) AS avg_product_price,
    ROUND(AVG(oi.freight_value), 2) AS avg_freight_value,
    ROUND(AVG(oi.freight_value / NULLIF(oi.price, 0)) * 100, 2) AS freight_to_product_ratio
FROM v_order_items_clean oi
JOIN v_products_clean p ON oi.product_id = p.product_id
GROUP BY p.product_category_name
HAVING avg_product_price > 0
ORDER BY freight_to_product_ratio DESC
LIMIT 10;

-- Top 25 high-volume categories (>= 500 orders) ranked by freight impact.
SELECT
    p.product_category_name AS category_name,
    COUNT(DISTINCT oi.order_id) AS total_orders,
    ROUND(AVG(oi.price), 2) AS avg_product_price,
    ROUND(AVG(oi.freight_value), 2) AS avg_freight_value,
    ROUND(AVG(oi.freight_value / NULLIF(oi.price, 0)) * 100, 2) AS avg_freight_to_product_ratio
FROM v_order_items_clean oi
JOIN v_products_clean p ON oi.product_id = p.product_id
GROUP BY p.product_category_name
HAVING total_orders >= 500
ORDER BY total_orders DESC, avg_freight_to_product_ratio DESC
LIMIT 25;

-- Geographic state-wise freight cost & revenue breakdown.
SELECT
    c.customer_state,
    COUNT(DISTINCT o.order_id) AS total_orders,
    ROUND(SUM(oi.price), 2) AS total_product_revenue,
    ROUND(SUM(oi.freight_value), 2) AS total_freight_cost,
    ROUND(AVG(oi.freight_value / NULLIF(oi.price, 0)) * 100, 2) AS avg_freight_ratio
FROM v_order_items_clean oi
JOIN v_orders_clean o ON oi.order_id = o.order_id
JOIN v_customers_clean c ON o.customer_id = c.customer_id
GROUP BY c.customer_state
ORDER BY avg_freight_ratio DESC;

-- Product category-wise loss analysis (categories with > 100 orders).
SELECT
    p.product_category_name,
    COUNT(DISTINCT oi.order_id) AS total_orders,
    ROUND(SUM(oi.price), 2) AS total_revenue,
    ROUND(SUM(oi.freight_value), 2) AS total_freight,
    ROUND(AVG(oi.freight_value / NULLIF(oi.price, 0)) * 100, 2) AS avg_freight_ratio
FROM v_order_items_clean oi
JOIN v_products_clean p ON oi.product_id = p.product_id
GROUP BY p.product_category_name
HAVING total_orders > 100
ORDER BY avg_freight_ratio DESC
LIMIT 15;

-- Loss vs profit transaction summary (freight > price = loss on that item).
SELECT
    CASE WHEN oi.freight_value > oi.price THEN 'Loss' ELSE 'Profit' END AS transaction_status,
    ROUND(MIN(oi.price), 2) AS min_product_price,
    ROUND(MAX(oi.price), 2) AS max_product_price,
    ROUND(AVG(oi.price), 2) AS avg_product_price,
    ROUND(MIN(oi.freight_value), 2) AS min_freight,
    ROUND(MAX(oi.freight_value), 2) AS max_freight,
    ROUND(AVG(oi.freight_value), 2) AS avg_freight,
    COUNT(*) AS total_items
FROM v_order_items_clean oi
GROUP BY transaction_status;


-- =====================================================================
-- EXECUTIVE VERDICT: SHIFTING OLIST FROM VOLUME GROWTH TO MARGIN DEFENSE
-- =====================================================================
-- Core diagnosis: structural unit-economics failure. Logistics costs
-- frequently outpace base product pricing, eroding commissions on
-- specific categories/states.
-- The absolute rule: profitability is governed by the freight-to-price
-- ratio. Leakage happens exclusively when shipping cost exceeds
-- product price.
-- Strategic prescription: decentralize fulfillment via hub-and-spoke /
-- dark stores, and implement strict minimum basket-size thresholds for
-- high-freight-ratio categories.
-- =====================================================================
